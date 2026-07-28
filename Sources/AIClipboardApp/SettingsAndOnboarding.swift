import AIClipboardCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var accountStore: AccountStore
    @ObservedObject private var sync: SecureSyncCoordinator
    @State private var section: SettingsSection = .general
    @State private var excludedApps: [String] = []
    @State private var excludedDomains: [String] = []
    @State private var newExcludedDomain = ""
    @State private var confirmDeleteAll = false

    init(model: AppModel) {
        self.model = model
        _accountStore = ObservedObject(wrappedValue: model.accountStore)
        _sync = ObservedObject(wrappedValue: model.syncCoordinator)
        let requestedSection = ProcessInfo.processInfo.environment["AI_CLIPBOARD_SETTINGS_SECTION"]
            .flatMap(SettingsSection.init(rawValue:))
        _section = State(initialValue: requestedSection ?? .general)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                BrandLockupForSettings()
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .padding(.bottom, 28)

                VStack(spacing: 4) {
                    ForEach(visibleSections) { item in
                        Button {
                            section = item
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.symbol).frame(width: 16)
                                Text(LocalizedStringKey(item.key))
                                Spacer()
                            }
                            .font(.system(size: 12, weight: section == item ? .semibold : .medium))
                            .foregroundStyle(section == item ? Mono.inverseText : Mono.secondaryText)
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .background(section == item ? Mono.inverse : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                Spacer()
            }
            .frame(width: 176)
            .background(Mono.panelRaised)

            MonoDivider().frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(section.key))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Mono.text)
                    Text(LocalizedStringKey(section.descriptionKey))
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.tertiaryText)
                }
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 20)

                ScrollView {
                    Group {
                        switch section {
                        case .general: generalContent
                        case .account: AccountSettingsPane(store: accountStore)
                        case .subscription:
                            SubscriptionSettingsPane(
                                manager: model.subscriptionManager,
                                languageCode: model.languageCode
                            )
                        case .sync: SyncSettingsPane(model: model, store: accountStore)
                        case .ai: aiContent
                        case .privacy: privacyContent
                        case .data: dataContent
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                }
            }
            .background(Mono.canvas)
        }
        .task { await load() }
        .onReceive(accountStore.$session) { session in
            if session == nil && section == .subscription {
                section = .account
            }
        }
        .environment(\.locale, Locale(identifier: model.languageCode))
        .preferredColorScheme(model.preferredColorScheme)
        .confirmationDialog("settings.deleteConfirm", isPresented: $confirmDeleteAll) {
            Button("settings.deleteAll", role: .destructive) { model.deleteAllHistory() }
            Button("action.cancel", role: .cancel) {}
        }
    }

    private var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter {
            ![SettingsSection.subscription, .sync].contains($0) || accountStore.session != nil
        }
    }

    private var generalContent: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "settings.behavior") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.hotkey")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Mono.text)
                        Text("hotkey.description")
                            .font(.system(size: 10))
                            .foregroundStyle(Mono.tertiaryText)
                    }
                    Spacer()
                    HotKeyRecorderField(
                        display: model.hotKeyDisplay,
                        onRecord: model.updateHotKey
                    )
                    .frame(width: 116, height: 34)
                    Button("hotkey.reset") { model.resetHotKey() }
                        .buttonStyle(MonoSecondaryButtonStyle())
                }
            }

            SettingsCard(title: "settings.startup") {
                LaunchAtLoginSettingsRow(controller: model.launchAtLoginController)
            }

            SettingsCard(title: "settings.appearance") {
                SettingsChoiceRow(
                    title: "settings.theme",
                    options: [
                        ("system", "settings.theme.system"),
                        ("light", "settings.theme.light"),
                        ("dark", "settings.theme.dark")
                    ],
                    selected: model.appearanceMode,
                    action: model.setAppearanceMode
                )
                MonoDivider()
                SettingsChoiceRow(
                    title: "settings.language",
                    options: [("ru", "settings.language.ru"), ("en", "settings.language.en")],
                    selected: model.languageCode,
                    action: model.setLanguageCode
                )
            }

        }
    }

    private var privacyContent: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "settings.capture") {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey(
                                model.isPaused ? "capture.status.paused" : "capture.status.active"
                            ))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Mono.text)
                            Text(LocalizedStringKey(
                                model.isPaused
                                    ? "capture.status.paused.description"
                                    : "capture.status.active.description"
                            ))
                            .font(.system(size: 10))
                            .foregroundStyle(Mono.tertiaryText)
                        }
                        Spacer()
                        MonoBadge(
                            text: AppLocalization.string(
                                model.isPaused
                                    ? "capture.badge.paused"
                                    : "capture.badge.active",
                                languageCode: model.languageCode
                            ),
                            inverted: !model.isPaused
                        )
                    }
                    MonoDivider()
                    if model.isPaused {
                        Button("capture.resume") { model.setPause(nil) }
                            .buttonStyle(MonoPrimaryButtonStyle())
                    } else {
                        Text("capture.pausePrompt")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Mono.secondaryText)
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 8
                        ) {
                            PauseButton(title: "pause.5min") { model.setPause(5 * 60) }
                            PauseButton(title: "pause.15min") { model.setPause(15 * 60) }
                            PauseButton(title: "pause.1hour") { model.setPause(60 * 60) }
                            PauseButton(title: "pause.indefinitely") { model.setPause(.infinity) }
                        }
                    }
                }
            }

            SettingsCard(title: "settings.excludedApps") {
                HStack {
                    Text("settings.excludedApps.description")
                        .font(.system(size: 10))
                        .foregroundStyle(Mono.tertiaryText)
                    Spacer()
                    Button("settings.excludedApps.add") { chooseExcludedApplication() }
                        .buttonStyle(MonoSecondaryButtonStyle())
                }
                MonoDivider()
                if excludedApps.isEmpty {
                    Text("settings.noExcludedApps")
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(excludedApps.enumerated()), id: \.element) { index, bundle in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7).fill(Mono.fill)
                                    Text(String(bundle.split(separator: ".").last?.prefix(1) ?? "?"))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Mono.secondaryText)
                                }
                                .frame(width: 30, height: 30)
                                Text(bundle)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Mono.text)
                                Spacer()
                                Button {
                                    Task {
                                        try? await model.privacy.include(bundleIdentifier: bundle)
                                        await load()
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(MonoIconButtonStyle(size: 28))
                            }
                            .frame(height: 45)
                            if index < excludedApps.count - 1 { MonoDivider() }
                        }
                    }
                }
            }

            SettingsCard(title: "settings.excludedSites") {
                Text("settings.excludedSites.description")
                    .font(.system(size: 10))
                    .lineSpacing(3)
                    .foregroundStyle(Mono.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    TextField("settings.excludedSites.placeholder", text: $newExcludedDomain)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(Mono.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).stroke(Mono.line)
                        }
                        .onSubmit { addExcludedDomain() }
                    Button("settings.excludedSites.add") { addExcludedDomain() }
                        .buttonStyle(MonoPrimaryButtonStyle())
                }
                if !excludedDomains.isEmpty {
                    MonoDivider()
                    VStack(spacing: 0) {
                        ForEach(Array(excludedDomains.enumerated()), id: \.element) { index, domain in
                            HStack {
                                Image(systemName: "globe")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Mono.tertiaryText)
                                Text(domain)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Mono.text)
                                Spacer()
                                Button {
                                    Task {
                                        try? await model.privacy.include(domain: domain)
                                        await load()
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(MonoIconButtonStyle(size: 28))
                            }
                            .frame(height: 40)
                            if index < excludedDomains.count - 1 { MonoDivider() }
                        }
                    }
                }
            }

        }
    }

    private var aiContent: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "ai.engine") {
                SettingsValueRow(title: "ai.provider", value: sync.aiDisplayName)
                MonoDivider()
                SettingsValueRow(
                    title: "ai.serverStatus",
                        value: sync.aiAvailable
                        ? AppLocalization.string(
                            "ai.status.ready",
                            languageCode: model.languageCode
                        )
                        : AppLocalization.string(
                            "ai.status.unavailable",
                            languageCode: model.languageCode
                        )
                )
                MonoDivider()
                SettingsValueRow(
                    title: "ai.network",
                    value: AppLocalization.string(
                        "ai.network.server",
                        languageCode: model.languageCode
                    )
                )
            }

            SettingsCard(title: "ai.semanticSearch") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ai.semantic.description")
                        .font(.system(size: 11))
                        .lineSpacing(3)
                        .foregroundStyle(Mono.secondaryText)
                    Text(LocalizedStringKey("ai.status.\(sync.aiStatusDetail)"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Mono.text)
                    Text("ai.setup.instructions")
                        .font(.system(size: 10))
                        .lineSpacing(3)
                        .foregroundStyle(Mono.tertiaryText)
                    HStack {
                        Button("ai.checkStatus") {
                            Task { await sync.refreshAIStatus() }
                        }
                        .buttonStyle(MonoPrimaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(title: "ai.privacy") {
                Text("ai.privacy.description")
                    .font(.system(size: 10))
                    .lineSpacing(3)
                    .foregroundStyle(Mono.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dataContent: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "settings.storage") {
                SettingsActionRow(
                    title: "settings.exportJSON",
                    detail: "settings.export.detail",
                    symbol: "arrow.up.doc"
                ) {
                    model.exportJSON()
                }
            }

            SettingsCard(title: "settings.dangerZone") {
                SettingsActionRow(
                    title: "settings.deleteAll",
                    detail: "settings.deleteExplanation",
                    symbol: "trash"
                ) {
                    confirmDeleteAll = true
                }
            }
        }
    }

    private func load() async {
        let settings = await model.privacy.current()
        excludedApps = settings.excludedBundleIdentifiers.sorted()
        excludedDomains = (settings.excludedDomains ?? []).sorted()
    }

    private func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string(
            "settings.excludedApps.pickerTitle",
            languageCode: model.languageCode
        )
        panel.prompt = AppLocalization.string(
            "settings.excludedApps.choose",
            languageCode: model.languageCode
        )
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return }
        Task {
            try? await model.privacy.exclude(bundleIdentifier: bundleIdentifier)
            await load()
        }
    }

    private func addExcludedDomain() {
        let value = newExcludedDomain
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            try? await model.privacy.exclude(domain: value)
            newExcludedDomain = ""
            await load()
        }
    }
}

struct AccountWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: AccountStore

    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.accountStore)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.black)
                        }
                    Text("AI CLIPBOARD")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.3)
                }
                Spacer()
                Text("account.window.eyebrow")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.white.opacity(0.48))
                Text("account.window.headline")
                    .font(.system(size: 28, weight: .semibold))
                    .lineSpacing(2)
                    .padding(.top, 10)
                Text("account.window.detail")
                    .font(.system(size: 11))
                    .lineSpacing(4)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .padding(.top, 12)
                Spacer()
            }
            .foregroundStyle(Color.white)
            .padding(30)
            .frame(width: 255)
            .background(Color.black)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(store.session == nil ? "account.window.title" : "account.current"))
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Mono.text)
                    Text(LocalizedStringKey(
                        store.session == nil
                            ? "account.window.subtitle"
                            : "account.window.signedin"
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.tertiaryText)
                }
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 22)

                ScrollView {
                    AccountSettingsPane(store: store)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                }
            }
            .background(Mono.canvas)
        }
        .environment(\.locale, Locale(identifier: model.languageCode))
        .preferredColorScheme(model.preferredColorScheme)
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var controller: LaunchAtLoginController
    @State private var showEnableDialog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("startup.launchAtLogin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Mono.text)
                    Text("startup.description")
                        .font(.system(size: 10))
                        .foregroundStyle(Mono.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                MonoToggle(isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in
                        if enabled {
                            showEnableDialog = true
                        } else {
                            controller.setEnabled(false)
                        }
                    }
                ))
                .disabled(!controller.isAvailable)
            }

            if controller.requiresApproval {
                HStack {
                    Text("startup.approval")
                        .font(.system(size: 10))
                        .foregroundStyle(Mono.secondaryText)
                    Spacer()
                    Button("startup.openSettings") { controller.openSystemSettings() }
                        .buttonStyle(MonoSecondaryButtonStyle())
                }
            } else if !controller.isAvailable {
                Text("startup.unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(Mono.tertiaryText)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Mono.secondaryText)
            }
        }
        .onAppear { controller.refresh() }
        .alert("startup.dialog.title", isPresented: $showEnableDialog) {
            Button("startup.dialog.enable") { controller.setEnabled(true) }
            Button("startup.openSettings") { controller.openSystemSettings() }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("startup.dialog.message")
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, account, subscription, sync, ai, privacy, data
    var id: Self { self }
    var key: String { "settings.\(rawValue)" }
    var descriptionKey: String { "settings.\(rawValue).description" }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .account: "person.crop.circle"
        case .subscription: "creditcard"
        case .sync: "arrow.triangle.2.circlepath"
        case .ai: "sparkles"
        case .privacy: "hand.raised"
        case .data: "externaldrive"
        }
    }
}

private struct SyncSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: AccountStore
    @ObservedObject private var sync: SecureSyncCoordinator

    init(model: AppModel, store: AccountStore) {
        self.model = model
        self.store = store
        _sync = ObservedObject(wrappedValue: model.syncCoordinator)
    }

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "sync.captureStatus") {
                SettingsValueRow(
                    title: "sync.capture",
                    value: sync.isConfigured
                        ? AppLocalization.string(
                            "sync.capture.server",
                            languageCode: model.languageCode
                        )
                        : AppLocalization.string(
                            "sync.capture.ram",
                            languageCode: model.languageCode
                        )
                )
                MonoDivider()
                Text(LocalizedStringKey(
                    sync.isConfigured
                        ? "sync.capture.server.description"
                        : "sync.capture.ram.description"
                ))
                    .font(.system(size: 10))
                    .lineSpacing(3)
                    .foregroundStyle(Mono.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(title: "sync.security") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("sync.e2ee", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Mono.text)
                    Text("sync.e2ee.description")
                        .font(.system(size: 10))
                        .lineSpacing(3)
                        .foregroundStyle(Mono.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if sync.isConfigured {
                SettingsCard(title: "sync.status") {
                    SettingsValueRow(title: "sync.server", value: sync.endpoint)
                    MonoDivider()
                    SettingsValueRow(
                        title: "sync.lastSync",
                        value: sync.lastSyncAt.map {
                            AppLocalization.date(
                                $0,
                                style: .abbreviated,
                                languageCode: model.languageCode
                            )
                        } ?? AppLocalization.string(
                            "sync.never",
                            languageCode: model.languageCode
                        )
                    )
                    MonoDivider()
                    HStack {
                        if let error = sync.errorMessage {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(Mono.secondaryText)
                        }
                        Spacer()
                        Button(sync.isSyncing ? "sync.syncing" : "sync.now") {
                            Task {
                                await model.syncServerHistory()
                                await model.refresh()
                            }
                        }
                        .buttonStyle(MonoPrimaryButtonStyle())
                        .disabled(sync.isSyncing)
                    }
                }
            } else if let session = store.session {
                SettingsCard(title: "sync.connect") {
                    Text("sync.accountReconnect")
                        .font(.system(size: 10))
                        .lineSpacing(3)
                        .foregroundStyle(Mono.tertiaryText)

                    if let error = sync.errorMessage {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(Mono.secondaryText)
                    }

                    SettingsValueRow(title: "account.email", value: session.email)
                }
            }
        }
    }
}

private struct BrandLockupForSettings: View {
    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Mono.inverse)
                .frame(width: 27, height: 27)
                .overlay {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Mono.inverseText)
                }
            Text("settings.brand")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Mono.text)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            MonoSectionLabel(title: title)
            MonoCard {
                VStack(spacing: 13) {
                    content
                }
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var value: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Mono.text)
                Text(detail).font(.system(size: 10)).foregroundStyle(Mono.tertiaryText)
            }
            Spacer()
            MonoToggle(isOn: $value)
        }
    }
}

private struct SettingsValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Mono.text)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Mono.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Mono.fill)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct SettingsActionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 34, height: 34)
                .background(Mono.fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Mono.text)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Mono.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Button("settings.action") { action() }
                .buttonStyle(MonoSecondaryButtonStyle())
        }
    }
}

private struct PauseButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
            .buttonStyle(MonoSecondaryButtonStyle())
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var page = 0

    private let pages: [OnboardingPage] = [
        .init(index: "01", symbol: "rectangle.on.rectangle", title: "onboarding.welcome.title", detail: "onboarding.welcome.description"),
        .init(index: "02", symbol: "lock", title: "onboarding.privacy.title", detail: "onboarding.privacy.description"),
        .init(index: "03", symbol: "command", title: "onboarding.shortcut.title", detail: "onboarding.shortcut.description"),
        .init(index: "04", symbol: "command", title: "onboarding.demo.title", detail: "onboarding.demo.description"),
        .init(index: "05", symbol: "cpu", title: "onboarding.ai.title", detail: "onboarding.ai.description")
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.black)
                        }
                    Text("AI CLIPBOARD")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                }
                .foregroundStyle(.white)
                Spacer()
                Text(pages[page].index)
                    .font(.system(size: 64, weight: .ultraLight, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.18))
                HStack(spacing: 5) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(Color.white.opacity(index == page ? 1 : 0.2))
                            .frame(width: index == page ? 24 : 6, height: 3)
                    }
                }
            }
            .padding(28)
            .frame(width: 210)
            .background(Color.black)

            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Mono.fill)
                        .frame(width: 66, height: 66)
                    Image(systemName: pages[page].symbol)
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(Mono.text)
                }
                .padding(.bottom, 25)

                Text(LocalizedStringKey(pages[page].title))
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(Mono.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 13)

                Text(LocalizedStringKey(pages[page].detail))
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(Mono.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 410, alignment: .leading)

                Spacer()

                HStack {
                    if page > 0 {
                        Button("onboarding.back") { withAnimation(.easeOut(duration: 0.18)) { page -= 1 } }
                            .buttonStyle(MonoSecondaryButtonStyle())
                    }
                    Spacer()
                    Button(page == pages.count - 1 ? "onboarding.finish" : "onboarding.next") {
                        if page == pages.count - 1 {
                            model.completeOnboarding()
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) { page += 1 }
                        }
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())
                }
            }
            .padding(36)
            .background(Mono.canvas)
        }
        .frame(width: 720, height: 500)
        .interactiveDismissDisabled()
        .environment(\.locale, Locale(identifier: model.languageCode))
        .preferredColorScheme(model.preferredColorScheme)
    }
}

struct AutorunPromptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var launchController: LaunchAtLoginController

    init(model: AppModel) {
        self.model = model
        _launchController = ObservedObject(
            wrappedValue: model.launchAtLoginController
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "power")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white)
                Spacer()
                Text("autorun.modal.eyebrow")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Color.white.opacity(0.48))
                Text("autorun.modal.side")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 9)
            }
            .padding(28)
            .frame(width: 205)
            .background(Color.black)

            VStack(alignment: .leading, spacing: 0) {
                Text("autorun.modal.title")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Mono.text)
                Text("autorun.modal.description")
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(Mono.secondaryText)
                    .padding(.top, 10)

                VStack(spacing: 10) {
                    AutorunInstruction(number: "1", text: "autorun.modal.step1")
                    AutorunInstruction(number: "2", text: "autorun.modal.step2")
                    AutorunInstruction(number: "3", text: "autorun.modal.step3")
                }
                .padding(.top, 24)

                if let error = launchController.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Mono.text)
                    .padding(.top, 14)
                }

                Spacer()

                HStack {
                    Button("autorun.modal.later") {
                        model.finishAutorunPrompt(enable: false)
                    }
                    .buttonStyle(MonoSecondaryButtonStyle())

                    Button("startup.openSettings") {
                        model.finishAutorunPrompt(enable: false, openSettings: true)
                    }
                    .buttonStyle(MonoSecondaryButtonStyle())

                    Spacer()

                    Button("startup.dialog.enable") {
                        model.finishAutorunPrompt(enable: true)
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())
                }
            }
            .padding(32)
            .background(Mono.canvas)
        }
        .frame(width: 690, height: 430)
        .interactiveDismissDisabled()
        .environment(\.locale, Locale(identifier: model.languageCode))
        .preferredColorScheme(model.preferredColorScheme)
    }
}

private struct AutorunInstruction: View {
    let number: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Mono.inverseText)
                .frame(width: 25, height: 25)
                .background(Mono.inverse)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 11))
                .lineSpacing(3)
                .foregroundStyle(Mono.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

private struct OnboardingPage {
    let index: String
    let symbol: String
    let title: String
    let detail: String
}

private struct SettingsChoiceRow: View {
    let title: LocalizedStringKey
    let options: [(value: String, key: String)]
    let selected: String
    let action: (String) -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Mono.text)
            Spacer()
            HStack(spacing: 3) {
                ForEach(options, id: \.value) { option in
                    Button {
                        action(option.value)
                    } label: {
                        Text(LocalizedStringKey(option.key))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selected == option.value ? Mono.inverseText : Mono.secondaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(selected == option.value ? Mono.inverse : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Mono.fill)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct AccountSettingsPane: View {
    @ObservedObject var store: AccountStore
    @State private var mode = "signin"
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""

    var body: some View {
        VStack(spacing: 12) {
            if let session = store.session {
                SettingsCard(title: "account.current") {
                    HStack(spacing: 13) {
                        ZStack {
                            Circle().fill(Mono.inverse).frame(width: 44, height: 44)
                            Text(String(session.displayName.prefix(1)).uppercased())
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Mono.inverseText)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Mono.text)
                            Text(session.email)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Mono.tertiaryText)
                            MonoBadge(text: session.provider.rawValue)
                        }
                        Spacer()
                        Button("account.signout") { store.signOut() }
                            .buttonStyle(MonoSecondaryButtonStyle())
                    }
                }
            } else {
                SettingsCard(title: "account.access") {
                    VStack(spacing: 12) {
                        SettingsChoiceRow(
                            title: "account.mode",
                            options: [
                                ("signin", "account.signin"),
                                ("register", "account.register")
                            ],
                            selected: mode
                        ) { mode = $0 }
                        if mode == "register" {
                            MonoAccountField(title: "account.name", text: $displayName)
                        }
                        MonoAccountField(title: "account.email", text: $email)
                        MonoAccountField(title: "account.password", text: $password, secure: true)
                        if let error = store.errorMessage {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(Mono.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            Button(mode == "register" ? "account.register" : "account.signin") {
                                if mode == "register" {
                                    store.register(email: email, password: password, displayName: displayName)
                                } else {
                                    store.signIn(email: email, password: password)
                                }
                            }
                            .buttonStyle(MonoPrimaryButtonStyle())
                            .disabled(store.isWorking)
                            Spacer()
                        }
                    }
                }

                SettingsCard(title: "account.google") {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("account.google.description")
                            .font(.system(size: 10))
                            .lineSpacing(3)
                            .foregroundStyle(Mono.tertiaryText)
                        Button {
                            store.signInWithGoogle()
                        } label: {
                            HStack(spacing: 9) {
                                Text("G").font(.system(size: 13, weight: .bold))
                                Text("account.google.button")
                            }
                        }
                        .buttonStyle(MonoSecondaryButtonStyle())
                        .disabled(store.isWorking)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct MonoAccountField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Mono.tertiaryText)
            Group {
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Mono.text)
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(Mono.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).stroke(Mono.line)
            }
        }
    }
}

private struct SubscriptionSettingsPane: View {
    @ObservedObject var manager: SubscriptionManager
    let languageCode: String

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "subscription.status") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.isSubscribed ? "subscription.pro" : "subscription.free")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Mono.text)
                        Text(manager.isSubscribed ? "subscription.pro.description" : "subscription.free.description")
                            .font(.system(size: 10))
                            .foregroundStyle(Mono.tertiaryText)
                    }
                    Spacer()
                    MonoBadge(
                        text: AppLocalization.string(
                            manager.isSubscribed
                                ? "subscription.active"
                                : "subscription.inactive",
                            languageCode: languageCode
                        ),
                        inverted: manager.isSubscribed
                    )
                }
            }

            SettingsCard(title: "subscription.plans") {
                if manager.products.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("subscription.notConfigured")
                            .font(.system(size: 10))
                            .lineSpacing(3)
                            .foregroundStyle(Mono.tertiaryText)
                        Button("subscription.reload") { Task { await manager.reload() } }
                            .buttonStyle(MonoSecondaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 10) {
                        ForEach(manager.products, id: \.id) { product in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(product.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(product.description)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Mono.tertiaryText)
                                }
                                Spacer()
                                Button(product.displayPrice) { manager.purchase(product) }
                                    .buttonStyle(MonoPrimaryButtonStyle())
                            }
                        }
                    }
                }
            }

            Button("subscription.restore") { manager.restore() }
                .buttonStyle(MonoSecondaryButtonStyle())
                .disabled(manager.isWorking)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
