import AIClipboardCore
import AppKit
import LocalAuthentication
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(model: model)
                .frame(width: Mono.sidebarWidth)
            MonoDivider().frame(width: 1)
            Group {
                if model.selectedSection == .ai {
                    AIWorkspaceView(model: model)
                        .frame(minWidth: 720, maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    ClipboardLibrary(model: model)
                        .frame(minWidth: 360, idealWidth: Mono.libraryWidth, maxWidth: 500)
                    MonoDivider().frame(width: 1)
                    DetailPane(item: selectedItem, model: model)
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .background(Mono.canvas)
        .motionAnimate(value: model.selectedSection, animation: AppMotion.expressive)
        .environment(\.locale, Locale(identifier: model.languageCode))
        .preferredColorScheme(model.preferredColorScheme)
        .alert("error.title", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("action.ok") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var selectedItem: ClipboardItem? {
        visibleResults.first { $0.id == model.selectedItemID }?.item
    }

    private var visibleResults: [SearchResult] {
        if model.selectedSection == .favorites {
            return model.searchResults.filter(\.item.isFavorite)
        }
        return model.searchResults
    }
}

private struct LibrarySidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 30)

            MonoSectionLabel(title: "sidebar.library")
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(spacing: 3) {
                ForEach(LibrarySection.allCases.filter { $0 != .trash }) { section in
                    SidebarButton(
                        section: section,
                        selected: model.selectedSection == section,
                        count: count(for: section)
                    ) {
                        model.selectSection(section)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(spacing: 3) {
                AccountSidebarButton(store: model.accountStore) {
                    model.showAccount()
                }

                Button {
                    model.setPause(model.isPaused ? nil : 15 * 60)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 16)
                        Text(model.isPaused ? "menu.resume" : "menu.pause")
                        Spacer()
                        if model.isPaused {
                            Circle().fill(Mono.text).frame(width: 6, height: 6)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Mono.secondaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MotionPlainButtonStyle())
                .motionAnimate(value: model.isPaused, animation: AppMotion.selection)

                Button {
                    model.showSettings()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "slider.horizontal.3").frame(width: 16)
                        Text("menu.settings")
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Mono.secondaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MotionPlainButtonStyle())
            }
            .padding(10)
        }
        .background(Mono.panelRaised)
    }

    private func count(for section: LibrarySection) -> Int? {
        guard section != .ai else { return nil }
        return model.items.filter { model.matches($0, section: section) }.count
    }
}

private struct AccountSidebarButton: View {
    @ObservedObject var store: AccountStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(store.session == nil ? Mono.fill : Mono.inverse)
                        .frame(width: 20, height: 20)
                    if let session = store.session {
                        Text(String(session.displayName.prefix(1)).uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Mono.inverseText)
                    } else {
                        Image(systemName: "person")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                Text(LocalizedStringKey(
                    store.session == nil ? "account.sidebar.signin" : "account.sidebar.profile"
                ))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Mono.tertiaryText)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Mono.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionPlainButtonStyle())
        .motionAnimate(value: store.session?.id, animation: AppMotion.selection)
    }
}

private struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Mono.inverse)
                    .frame(width: 30, height: 30)
                VStack(spacing: 3) {
                    Capsule().fill(Mono.inverseText).frame(width: 13, height: 2)
                    Capsule().fill(Mono.inverseText.opacity(0.65)).frame(width: 9, height: 2)
                    Capsule().fill(Mono.inverseText.opacity(0.35)).frame(width: 5, height: 2)
                }
            }
            Text("AI CLIPBOARD")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Mono.text)
        }
        .motionAppear(distance: 6)
    }
}

private struct SidebarButton: View {
    let section: LibrarySection
    let selected: Bool
    let count: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(LocalizedStringKey(section.localizationKey))
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                Spacer()
                if let count, count > 0 {
                    Text(String(count))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(selected ? Mono.inverseText.opacity(0.65) : Mono.tertiaryText)
                }
            }
            .foregroundStyle(selected ? Mono.inverseText : Mono.secondaryText)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(selected ? Mono.inverse : (hovering ? Mono.fill : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionPlainButtonStyle())
        .onHover { value in
            withAnimation(AppMotion.selection) { hovering = value }
        }
        .motionAnimate(value: selected, animation: AppMotion.selection)
    }
}

private struct ClipboardLibrary: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizedStringKey(model.selectedSection.localizationKey))
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Mono.text)
                    Spacer()
                    Text("\(results.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Mono.tertiaryText)
                }
                MonoSearchField(text: $model.query)
                    .onChange(of: model.query) { _ in model.scheduleSearch() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 16)

            if results.isEmpty {
                MinimalEmptyState(
                    title: model.query.isEmpty ? "empty.title" : "empty.search.title",
                    detail: model.query.isEmpty ? "empty.description" : "empty.search.description",
                    symbol: model.query.isEmpty ? "square.on.square" : "line.3.horizontal.decrease"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(results) { result in
                            ClipboardCard(
                                result: result,
                                selected: model.selectedItemID == result.id,
                                languageCode: model.languageCode
                            ) {
                                model.selectedItemID = result.id
                            }
                            .motionAppear(distance: 7)
                            .contextMenu {
                                Button("action.copy") { model.pasteController.copy(result.item, plainText: false) }
                                Button("action.copyPlain") { model.pasteController.copy(result.item, plainText: true) }
                                Divider()
                                Button(result.item.isPinned ? "action.unpin" : "action.pin") { model.togglePin(result.item) }
                                Button(result.item.isFavorite ? "action.unfavorite" : "action.favorite") { model.toggleFavorite(result.item) }
                                if result.item.sourceApplication != nil {
                                    Button("action.excludeApp") { model.excludeCurrentSource(result.item) }
                                }
                                Divider()
                                Button("action.delete", role: .destructive) { model.delete(result.item) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 18)
                }
            }
        }
        .background(Mono.canvas)
        .motionAnimate(value: results.map(\.id), animation: AppMotion.standard)
        .motionAnimate(value: model.selectedSection, animation: AppMotion.expressive)
    }

    private var results: [SearchResult] {
        model.selectedSection == .favorites
            ? model.searchResults.filter(\.item.isFavorite)
            : model.searchResults
    }
}

struct MonoSearchField: View {
    @Binding var text: String
    var large = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: large ? 16 : 13, weight: .medium))
                .foregroundStyle(Mono.tertiaryText)
            TextField(large ? "quickSearch.placeholder" : "search.placeholder", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: large ? 18 : 13, weight: .regular))
                .foregroundStyle(Mono.text)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Mono.tertiaryText)
                        .frame(width: 22, height: 22)
                        .background(Mono.fill)
                        .clipShape(Circle())
                }
                .buttonStyle(MotionPlainButtonStyle())
                .accessibilityLabel(Text("search.clear"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, large ? 18 : 12)
        .frame(height: large ? 58 : 40)
        .background(Mono.panel)
        .clipShape(RoundedRectangle(cornerRadius: large ? 13 : 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: large ? 13 : 10, style: .continuous)
                .stroke(focused ? Mono.text.opacity(0.48) : Mono.line, lineWidth: 1)
        }
        .scaleEffect(focused ? 1.006 : 1)
        .shadow(color: Color.black.opacity(focused ? 0.08 : 0), radius: 12, y: 5)
        .motionAnimate(value: focused, animation: AppMotion.selection)
        .motionAnimate(value: text.isEmpty, animation: AppMotion.quick)
        .onAppear {
            if large { DispatchQueue.main.async { focused = true } }
        }
    }
}

private struct ClipboardCard: View {
    let result: SearchResult
    let selected: Bool
    let languageCode: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Mono.inverseText.opacity(0.13) : Mono.fill)
                    Image(systemName: result.item.monoSymbol)
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(result.item.localizedTitle(languageCode: languageCode))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if result.item.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                        if result.item.isSensitive { Image(systemName: "lock.fill").font(.system(size: 8)) }
                        Spacer()
                        Text(AppLocalization.relativeDate(
                            result.item.createdAt,
                            languageCode: languageCode
                        ))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .opacity(0.58)
                    }
                    Text(preview)
                        .font(.system(size: 11, weight: .regular))
                        .lineSpacing(2)
                        .lineLimit(2)
                        .opacity(0.66)
                    HStack(spacing: 7) {
                        Text(result.item.localizedTypeName(
                            languageCode: languageCode
                        ).uppercased())
                        if let app = result.item.sourceApplication?.applicationName {
                            Circle().frame(width: 2, height: 2)
                            Text(app.uppercased())
                        }
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.7)
                    .opacity(0.48)
                }
            }
            .foregroundStyle(selected ? Mono.inverseText : Mono.text)
            .padding(13)
            .background(selected ? Mono.inverse : (hovering ? Mono.panel : Mono.panelRaised))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if !selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Mono.subtleLine, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(selected ? 1 : (hovering ? 1.008 : 0.995))
            .offset(y: hovering && !selected ? -1 : 0)
        }
        .buttonStyle(MotionPlainButtonStyle())
        .onHover { value in
            withAnimation(AppMotion.selection) { hovering = value }
        }
        .motionAnimate(value: selected, animation: AppMotion.selection)
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        if result.item.isSensitive {
            return AppLocalization.string("protected.preview", languageCode: languageCode)
        }
        return result.matchedFragment
            ?? result.item.normalizedText
            ?? result.item.fileReferences.map(\.displayName).joined(separator: ", ")
    }
}

private struct DetailPane: View {
    let item: ClipboardItem?
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let item {
                ItemDetailView(item: item, model: model)
                    .id(item.id)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                MinimalEmptyState(
                    title: "detail.empty",
                    detail: "detail.empty.description",
                    symbol: "arrow.left"
                )
            }
        }
        .background(Mono.panel)
        .motionAnimate(value: item?.id, animation: AppMotion.expressive)
    }
}

struct ItemDetailView: View {
    let item: ClipboardItem
    @ObservedObject var model: AppModel
    @State private var showProtected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MonoBadge(text: item.localizedTypeName(languageCode: model.languageCode))
                if item.isSensitive {
                    MonoBadge(
                        text: AppLocalization.string(
                            "protected.badge",
                            languageCode: model.languageCode
                        ),
                        inverted: true
                    )
                }
                Spacer()
                Button { model.toggleFavorite(item) } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                }.buttonStyle(MonoIconButtonStyle())
                Button { model.togglePin(item) } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                }.buttonStyle(MonoIconButtonStyle())
                Menu {
                    Button("action.copy") { model.pasteController.copy(item, plainText: false) }
                    Button("action.copyPlain") { model.pasteController.copy(item, plainText: true) }
                    Divider()
                    Button("action.delete", role: .destructive) { model.delete(item) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
            }
            .padding(.horizontal, 24)
            .frame(height: 66)

            MonoDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.localizedTitle(languageCode: model.languageCode))
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Mono.text)
                            .textSelection(.enabled)
                        HStack(spacing: 7) {
                            if let app = item.sourceApplication?.applicationName {
                                Text(app)
                                Circle().frame(width: 2, height: 2)
                            }
                            Text(AppLocalization.date(
                                item.createdAt,
                                style: .long,
                                languageCode: model.languageCode
                            ))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Mono.tertiaryText)
                    }

                    detailContent

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                model.pasteController.copy(item, plainText: false)
                            } label: {
                                Label("action.copy", systemImage: "square.on.square")
                            }
                            .buttonStyle(MonoPrimaryButtonStyle())

                            Button {
                                model.pasteController.copy(item, plainText: true)
                            } label: {
                                Text("action.copyPlain")
                            }
                            .buttonStyle(MonoSecondaryButtonStyle())
                        }
                        Button {
                            if item.isSensitive {
                                authenticateAndRemoveProtection()
                            } else {
                                model.setProtected(item, value: true)
                            }
                        } label: {
                            Label {
                                Text(LocalizedStringKey(
                                    item.isSensitive ? "action.removeProtection" : "action.protect"
                                ))
                            } icon: {
                                Image(systemName: item.isSensitive ? "lock.open" : "lock")
                            }
                        }
                        .buttonStyle(MonoSecondaryButtonStyle())
                    }

                    MonoCard {
                        VStack(spacing: 13) {
                            MetadataRow(label: "detail.source", value: item.sourceApplication?.applicationName ?? "—")
                            MonoDivider()
                            MetadataRow(
                                label: "detail.created",
                                value: AppLocalization.date(
                                    item.createdAt,
                                    style: .abbreviated,
                                    languageCode: model.languageCode
                                )
                            )
                            MonoDivider()
                            MetadataRow(label: "detail.uses", value: String(item.usageCount))
                            MonoDivider()
                            MetadataRow(
                                label: "detail.status",
                                value: item.localizedStatus(
                                    languageCode: model.languageCode
                                ).uppercased()
                            )
                        }
                    }
                }
                .padding(24)
                .motionAppear(distance: 8)
            }
        }
        .motionAnimate(value: showProtected, animation: AppMotion.expressive)
        .motionAnimate(value: item.isFavorite, animation: AppMotion.selection)
        .motionAnimate(value: item.isPinned, animation: AppMotion.selection)
    }

    @ViewBuilder
    private var detailContent: some View {
        if item.isSensitive && !showProtected {
            MonoCard {
                VStack(spacing: 14) {
                    Image(systemName: "lock")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Mono.text)
                    if item.contentType == .url,
                       let value = item.sourceURL ?? item.normalizedText,
                       let host = URL(string: value)?.host {
                        Text(host)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Mono.text)
                            .textSelection(.enabled)
                    }
                    Text("protected.hidden")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("protected.reveal") { authenticate() }
                        .buttonStyle(MonoPrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        } else if let imageData = item.imageData, let image = NSImage(data: imageData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let imagePath = item.imagePath, let image = NSImage(contentsOfFile: imagePath) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 380)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Mono.corner, style: .continuous))
        } else {
            MonoCard {
                Text(item.rawText ?? item.fileReferences.map(\.path).joined(separator: "\n"))
                    .font(item.contentType == .code || item.contentType == .terminalCommand
                        ? .system(size: 12, design: .monospaced)
                        : .system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Mono.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func authenticate() {
        LAContext().evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: AppLocalization.string(
                "protected.authReason",
                languageCode: model.languageCode
            )
        ) { success, _ in
            if success {
                Task { @MainActor in
                    withAnimation(AppMotion.expressive) { showProtected = true }
                }
            }
        }
    }

    private func authenticateAndRemoveProtection() {
        LAContext().evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: AppLocalization.string(
                "protected.removeAuthReason",
                languageCode: model.languageCode
            )
        ) { success, _ in
            if success {
                Task { @MainActor in
                    showProtected = true
                    model.setProtected(item, value: false)
                }
            }
        }
    }
}

private struct MetadataRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Mono.tertiaryText)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Mono.text)
                .textSelection(.enabled)
        }
    }
}

struct MinimalEmptyState: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle().fill(Mono.fill).frame(width: 54, height: 54)
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Mono.secondaryText)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Mono.text)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Mono.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .motionAppear(distance: 8)
    }
}

struct QuickSearchView: View {
    @ObservedObject var model: AppModel
    @State private var answer: String?
    @State private var isThinking = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    BrandLockup()
                    Spacer()
                    Text("⌘ ⇧ V")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Mono.tertiaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6).stroke(Mono.line)
                        }
                }
                MonoSearchField(text: $model.query, large: true)
                    .onSubmit { submitAI() }
            }
            .padding(20)

            MonoDivider()

            if isThinking {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .motionPulse()
                    Text("ai.chat.thinking")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Mono.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if let answer, model.searchResults.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Mono.secondaryText)
                    Text(answer)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(Mono.text)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if model.searchResults.isEmpty {
                MinimalEmptyState(
                    title: "ai.quick.title",
                    detail: "ai.quick.description",
                    symbol: "sparkles"
                )
            } else {
                VStack(spacing: 0) {
                    if let answer {
                        Text(answer)
                            .font(.system(size: 11))
                            .lineSpacing(3)
                            .foregroundStyle(Mono.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Mono.panel)
                        MonoDivider()
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(model.searchResults) { result in
                                    QuickResultRow(
                                        result: result,
                                        selected: model.selectedItemID == result.id,
                                        languageCode: model.languageCode
                                    ) {
                                        model.selectedItemID = result.id
                                    } doubleAction: {
                                        model.paste(result.item)
                                    }
                                    .id(result.id)
                                }
                            }
                            .padding(10)
                        }
                        .onChange(of: model.selectedItemID) { id in
                            if let id {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }

            MonoDivider()

            HStack(spacing: 18) {
                ShortcutHint(keys: "↑ ↓", text: "quickSearch.navigate")
                ShortcutHint(keys: "↩", text: "ai.quick.search")
                ShortcutHint(keys: "2×", text: "quickSearch.paste")
                Spacer()
                ShortcutHint(keys: "ESC", text: "quickSearch.close")
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
        }
        .background(Mono.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Mono.line, lineWidth: 1)
        }
        .onAppear {
            answer = nil
            isThinking = false
        }
        .onMoveCommand { direction in
            if direction == .down { model.selectNext(1) }
            if direction == .up { model.selectNext(-1) }
        }
        .onExitCommand { model.closeQuickSearch() }
        .onDeleteCommand {
            if let item = model.selectedSearchItem { model.delete(item) }
        }
        .environment(\.locale, Locale(identifier: model.languageCode))
        .preferredColorScheme(model.preferredColorScheme)
        .motionAnimate(value: isThinking, animation: AppMotion.expressive)
        .motionAnimate(value: model.searchResults.map(\.id), animation: AppMotion.standard)
    }

    private func submitAI() {
        let prompt = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }
        isThinking = true
        answer = nil
        model.searchResults = []
        model.selectedItemID = nil
        Task {
            do {
                let response = try await model.askAI(prompt)
                answer = response.text
                model.searchResults = response.results.filter { !$0.item.isSensitive }
                model.selectedItemID = model.searchResults.first?.id
            } catch {
                answer = error.localizedDescription
            }
            isThinking = false
        }
    }
}

private struct QuickResultRow: View {
    let result: SearchResult
    let selected: Bool
    let languageCode: String
    let action: () -> Void
    let doubleAction: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: result.item.monoSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(selected ? Mono.inverseText.opacity(0.13) : Mono.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.item.localizedTitle(languageCode: languageCode))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(result.item.isSensitive
                         ? AppLocalization.string(
                            "protected.preview",
                            languageCode: languageCode
                         )
                         : result.item.normalizedText ?? result.item.fileReferences.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .opacity(0.62)
                }
                Spacer()
                if result.keywordScore > 0 || result.semanticScore > 0 {
                    Text(result.explanation == "Meaning match" ? "match.semantic" : "match.exact")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.5)
                        .opacity(0.5)
                }
            }
            .foregroundStyle(selected ? Mono.inverseText : Mono.text)
            .padding(.horizontal, 11)
            .frame(height: 58)
            .background(selected ? Mono.inverse : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionPlainButtonStyle())
        .motionAnimate(value: selected, animation: AppMotion.selection)
        .simultaneousGesture(TapGesture(count: 2).onEnded(doubleAction))
    }
}

private struct ShortcutHint: View {
    let keys: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Mono.text)
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Mono.tertiaryText)
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("menu.open") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("menu.quickSearch") { model.showQuickSearch() }
        Button("menu.account") { model.showAccount() }
        Divider()
        Button(model.isPaused ? "menu.resume" : "menu.pause") {
            model.setPause(model.isPaused ? nil : 15 * 60)
        }
        Menu("menu.pauseFor") {
            Button("pause.5min") { model.setPause(5 * 60) }
            Button("pause.15min") { model.setPause(15 * 60) }
            Button("pause.1hour") { model.setPause(60 * 60) }
            Button("pause.indefinitely") { model.setPause(.infinity) }
        }
        Divider()
        if let latest = model.items.first(where: { !$0.isSensitive }) {
            Menu("menu.latest") {
                Button(latest.localizedTitle(languageCode: model.languageCode)) {
                    model.pasteController.copy(latest, plainText: false)
                }
                Button("menu.deleteLatest") { model.delete(latest) }
            }
        }
        Button("menu.settings") {
            model.showSettings()
        }
        Divider()
        Button("menu.quit") { NSApp.terminate(nil) }
    }
}

extension ClipboardItem {
    var monoSymbol: String {
        switch contentType {
        case .url: "link"
        case .code, .json, .xml: "chevron.left.forwardslash.chevron.right"
        case .terminalCommand: "terminal"
        case .image: "photo"
        case .file, .fileList: "doc"
        case .emailAddress: "envelope"
        case .phoneNumber: "phone"
        case .color: "circle.lefthalf.filled"
        default: "text.alignleft"
        }
    }
}
