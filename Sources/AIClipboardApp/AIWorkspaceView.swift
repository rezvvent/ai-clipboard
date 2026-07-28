import AIClipboardCore
import SwiftUI

struct AIWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sync: SecureSyncCoordinator
    @State private var mode: Mode = .chat
    @State private var prompt = ""
    @State private var isThinking = false
    @State private var sort: SmartSort = .relevance
    @State private var messages: [AIChatMessage]
    @FocusState private var promptFocused: Bool

    init(model: AppModel) {
        self.model = model
        _sync = ObservedObject(wrappedValue: model.syncCoordinator)
        _messages = State(initialValue: [
            AIChatMessage(
                role: .assistant,
                text: AppLocalization.string(
                    "ai.chat.welcome",
                    languageCode: model.languageCode
                ),
                results: []
            )
        ])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            MonoDivider()
            Group {
                switch mode {
                case .chat: chat
                case .analytics: analytics
                }
            }
        }
        .background(Mono.canvas)
        .onAppear { promptFocused = true }
        .onChange(of: model.languageCode) { languageCode in
            guard !messages.isEmpty, messages[0].role == .assistant else { return }
            messages[0] = AIChatMessage(
                role: .assistant,
                text: AppLocalization.string(
                    "ai.chat.welcome",
                    languageCode: languageCode
                ),
                results: []
            )
        }
        .task { await sync.refreshAIStatus() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Mono.inverse)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Mono.inverseText)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("ai.workspace.title")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Mono.text)
                Text("ai.workspace.subtitle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Mono.tertiaryText)
            }
            Spacer()
            HStack(spacing: 3) {
                modeButton(.chat, title: "ai.mode.chat", symbol: "bubble.left.and.bubble.right")
                modeButton(.analytics, title: "ai.mode.analytics", symbol: "chart.bar.xaxis")
            }
            .padding(3)
            .background(Mono.fill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            MonoBadge(text: sync.aiDisplayName)
        }
        .padding(.horizontal, 24)
        .frame(height: 78)
        .background(Mono.panelRaised)
    }

    private func modeButton(_ value: Mode, title: LocalizedStringKey, symbol: String) -> some View {
        Button {
            mode = value
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(mode == value ? Mono.inverseText : Mono.secondaryText)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(mode == value ? Mono.inverse : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(messages) { message in
                            AIMessageView(
                                message: message,
                                sort: sort,
                                languageCode: model.languageCode,
                                open: open,
                                copy: { model.pasteController.copy($0, plainText: false) }
                            )
                            .id(message.id)
                        }
                        if isThinking {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("ai.chat.thinking")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Mono.tertiaryText)
                            }
                        }
                    }
                    .padding(24)
                }
                .onChange(of: messages.count) { _ in
                    if let id = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            if !sync.aiAvailable {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Mono.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ai.status.unavailable")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Mono.text)
                        Text(LocalizedStringKey("ai.status.\(sync.aiStatusDetail)"))
                            .font(.system(size: 9))
                            .foregroundStyle(Mono.tertiaryText)
                    }
                    Spacer()
                    Button("ai.checkStatus") {
                        Task { await sync.refreshAIStatus() }
                    }
                    .buttonStyle(MonoSecondaryButtonStyle())
                    Button("settings.ai") { model.showSettings() }
                        .buttonStyle(MonoPrimaryButtonStyle())
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 54)
                .background(Mono.panel)
            }

            MonoDivider()

            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    Menu {
                        ForEach(SmartSort.allCases) { option in
                            Button(LocalizedStringKey(option.key)) { sort = option }
                        }
                    } label: {
                        Label(LocalizedStringKey(sort.key), systemImage: "arrow.up.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("ai.chat.placeholder", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .focused($promptFocused)
                        .onSubmit { submit() }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .background(Mono.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).stroke(Mono.line)
                        }
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Mono.inverseText)
                            .frame(width: 42, height: 42)
                            .background(Mono.inverse)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
                }
            }
            .padding(18)
            .background(Mono.panelRaised)
        }
    }

    private var analytics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    MetricCard(
                        value: "\(visibleItems.count)",
                        title: "ai.analytics.total",
                        symbol: "square.stack.3d.up"
                    )
                    MetricCard(
                        value: "\(model.indexedItemCount)",
                        title: "ai.analytics.indexed",
                        symbol: "brain.head.profile"
                    )
                    MetricCard(
                        value: "\(recentWeekCount)",
                        title: "ai.analytics.week",
                        symbol: "calendar"
                    )
                    MetricCard(
                        value: "\(visibleItems.reduce(0) { $0 + $1.usageCount })",
                        title: "ai.analytics.reuses",
                        symbol: "arrow.triangle.2.circlepath"
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    AnalyticsListCard(
                        title: "ai.analytics.categories",
                        rows: categoryRows,
                        empty: "ai.analytics.empty"
                    )
                    AnalyticsListCard(
                        title: "ai.analytics.sources",
                        rows: sourceRows,
                        empty: "ai.analytics.empty"
                    )
                }

                MonoCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ai.analytics.smart.title")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Mono.text)
                                Text("ai.analytics.smart.description")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Mono.tertiaryText)
                            }
                            Spacer()
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(Mono.secondaryText)
                        }
                        MonoDivider()
                        HStack(spacing: 10) {
                            SmartCollection(
                                title: "ai.analytics.frequent",
                                count: frequentItems.count,
                                symbol: "arrow.up.right"
                            )
                            SmartCollection(
                                title: "ai.analytics.links",
                                count: visibleItems.filter { $0.contentType == .url }.count,
                                symbol: "link"
                            )
                            SmartCollection(
                                title: "ai.analytics.knowledge",
                                count: knowledgeItems.count,
                                symbol: "chevron.left.forwardslash.chevron.right"
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var recentWeekCount: Int {
        let boundary = Date().addingTimeInterval(-7 * 86_400)
        return visibleItems.filter { $0.createdAt >= boundary }.count
    }

    private var categoryRows: [(String, Int)] {
        Dictionary(grouping: visibleItems, by: \.contentType)
            .map { (localizedType($0.key), $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
            .map { $0 }
    }

    private var sourceRows: [(String, Int)] {
        Dictionary(grouping: visibleItems) {
            $0.sourceApplication?.applicationName ?? AppLocalization.string(
                "ai.analytics.unknownSource",
                languageCode: model.languageCode
            )
        }
        .map { ($0.key, $0.value.count) }
        .sorted { $0.1 > $1.1 }
        .prefix(6)
        .map { $0 }
    }

    private var frequentItems: [ClipboardItem] {
        visibleItems.filter { $0.usageCount > 1 }
    }

    private var knowledgeItems: [ClipboardItem] {
        visibleItems.filter {
            [.code, .terminalCommand, .json, .xml, .markdown].contains($0.contentType)
        }
    }

    private var visibleItems: [ClipboardItem] {
        model.items.filter { !$0.isSensitive }
    }

    private func localizedType(_ type: ClipboardContentType) -> String {
        AppLocalization.string(
            "type.\(type.rawValue)",
            languageCode: model.languageCode
        )
    }

    private func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        prompt = ""
        messages.append(AIChatMessage(role: .user, text: text, results: []))
        isThinking = true
        Task {
            do {
                let answer = try await model.askAI(text)
                messages.append(AIChatMessage(
                    role: .assistant,
                    text: answer.text,
                    results: Array(answer.results.prefix(8))
                ))
            } catch {
                messages.append(AIChatMessage(
                    role: .assistant,
                    text: error.localizedDescription,
                    results: []
                ))
            }
            isThinking = false
            promptFocused = true
        }
    }

    private func open(_ item: ClipboardItem) {
        model.query = ""
        model.selectedItemID = item.id
        model.selectedSection = .all
        Task { await model.refresh() }
    }
}

private enum Mode {
    case chat, analytics
}

private enum SmartSort: String, CaseIterable, Identifiable {
    case relevance, recent, used
    var id: Self { self }
    var key: String { "ai.sort.\(rawValue)" }
}

private struct AIChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
    let results: [SearchResult]
}

private struct AIMessageView: View {
    let message: AIChatMessage
    let sort: SmartSort
    let languageCode: String
    let open: (ClipboardItem) -> Void
    let copy: (ClipboardItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Mono.inverseText)
                    .frame(width: 28, height: 28)
                    .background(Mono.inverse)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Spacer(minLength: 90)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
                Text(message.text)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(message.role == .user ? Mono.inverseText : Mono.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(message.role == .user ? Mono.inverse : Mono.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if !message.results.isEmpty {
                    VStack(spacing: 7) {
                        ForEach(sortedResults.prefix(8)) { result in
                            AIResultRow(
                                result: result,
                                languageCode: languageCode,
                                open: open,
                                copy: copy
                            )
                        }
                    }
                    .frame(maxWidth: 620)
                }
            }

            if message.role == .assistant { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity)
    }

    private var sortedResults: [SearchResult] {
        switch sort {
        case .relevance:
            message.results.sorted { $0.finalScore > $1.finalScore }
        case .recent:
            message.results.sorted { $0.item.createdAt > $1.item.createdAt }
        case .used:
            message.results.sorted { $0.item.usageCount > $1.item.usageCount }
        }
    }
}

private struct AIResultRow: View {
    let result: SearchResult
    let languageCode: String
    let open: (ClipboardItem) -> Void
    let copy: (ClipboardItem) -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: result.item.monoSymbol)
                .font(.system(size: 12))
                .frame(width: 32, height: 32)
                .background(Mono.fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(result.item.localizedTitle(languageCode: languageCode))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Mono.text)
                    .lineLimit(1)
                Text(result.matchedFragment ?? result.item.normalizedText ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(Mono.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            Text(AppLocalization.string(
                result.semanticScore > result.keywordScore ? "tag.ai" : "tag.text",
                languageCode: languageCode
            ))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Mono.tertiaryText)
            Button { copy(result.item) } label: {
                Image(systemName: "square.on.square")
            }
            .buttonStyle(MonoIconButtonStyle(size: 30))
            Button { open(result.item) } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(MonoIconButtonStyle(size: 30))
        }
        .padding(10)
        .background(Mono.panel)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).stroke(Mono.subtleLine)
        }
    }
}

private struct MetricCard: View {
    let value: String
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        MonoCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.tertiaryText)
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(Mono.text)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Mono.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalyticsListCard: View {
    let title: LocalizedStringKey
    let rows: [(String, Int)]
    let empty: LocalizedStringKey

    var body: some View {
        MonoCard {
            VStack(alignment: .leading, spacing: 12) {
                MonoSectionLabel(title: title)
                if rows.isEmpty {
                    Text(empty)
                        .font(.system(size: 10))
                        .foregroundStyle(Mono.tertiaryText)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack {
                            Text(row.0)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Mono.text)
                            Spacer()
                            Text("\(row.1)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Mono.tertiaryText)
                        }
                        if index < rows.count - 1 { MonoDivider() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SmartCollection: View {
    let title: LocalizedStringKey
    let count: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 32, height: 32)
                .background(Mono.fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Mono.text)
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Mono.tertiaryText)
            }
            Spacer()
        }
        .padding(11)
        .background(Mono.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
