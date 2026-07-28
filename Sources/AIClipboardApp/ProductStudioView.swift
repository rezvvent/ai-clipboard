import AIClipboardCore
import AppKit
import SwiftUI

struct ProductStudioView: View {
    @ObservedObject var model: AppModel
    let section: LibrarySection
    @State private var input = ""
    @State private var secondaryInput = ""
    @State private var output = ""
    @State private var destination: PasteDestination = .json
    @State private var workspaceName = ""
    @State private var workspaces: [KnowledgeWorkspace] = []
    @State private var selectedRecipeID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(section.localizationKey))
                        .font(.system(size: 25, weight: .semibold))
                    Text(LocalizedStringKey("\(section.localizationKey).description"))
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.tertiaryText)
                }
                Spacer()
                MonoBadge(text: moduleBadge, inverted: true)
            }
            .padding(24)
            MonoDivider()

            ScrollView {
                Group {
                    switch section {
                    case .workspaces: workspaceContent
                    case .automation: automationContent
                    case .dataLab: dataLabContent
                    default: EmptyView()
                    }
                }
                .padding(24)
                .motionAppear(distance: 8)
            }
        }
        .background(Mono.canvas)
        .onAppear {
            loadLatestInput()
            Task {
                if let serverWorkspaces = try? await model.syncCoordinator.loadWorkspaces() {
                    workspaces = serverWorkspaces
                }
            }
        }
        .motionAnimate(value: section, animation: AppMotion.expressive)
        .motionAnimate(value: output, animation: AppMotion.standard)
    }

    private var moduleBadge: String {
        switch section {
        case .workspaces: "KNOWLEDGE"
        case .automation: "AUTOMATION"
        case .dataLab: "DATA LAB"
        default: "MODULE"
        }
    }

    private var workspaceContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudioIntro(
                symbol: "square.grid.2x2",
                title: "studio.workspace.title",
                detail: "studio.workspace.detail"
            )
            MonoCard {
                HStack {
                    TextField("studio.workspace.name", text: $workspaceName)
                        .textFieldStyle(.plain)
                    Button("studio.workspace.create") {
                        let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        let workspace = KnowledgeWorkspace(name: name)
                        workspaces.insert(workspace, at: 0)
                        workspaceName = ""
                        Task {
                            do {
                                try await model.syncCoordinator.saveWorkspace(workspace)
                            } catch {
                                model.errorMessage = AppLocalization.string(
                                    "studio.workspace.serverRequired",
                                    languageCode: model.languageCode
                                )
                            }
                        }
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())
                }
            }
            if workspaces.isEmpty {
                StudioEmpty(text: "studio.workspace.empty")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 12) {
                    ForEach(workspaces) { workspace in
                        MonoCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(workspace.name).font(.system(size: 14, weight: .semibold))
                                Text("\(workspace.itemIDs.count) items")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Mono.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            SettingsLikeCard(title: "studio.metrics") {
                Text("studio.metrics.detail")
                Text("Revenue = paid orders − refunds")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Mono.secondaryText)
            }
        }
    }

    private var automationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudioIntro(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "studio.automation.title",
                detail: "studio.automation.detail"
            )
            inputEditor(title: "studio.input", text: $input)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 235))], spacing: 10) {
                ForEach(RecipeLibrary.builtIn) { recipe in
                    Button {
                        selectedRecipeID = recipe.id
                        run(recipe)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(recipe.name).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Image(systemName: selectedRecipeID == recipe.id ? "checkmark.circle.fill" : "play.circle")
                            }
                            Text(recipe.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(Mono.tertiaryText)
                                .multilineTextAlignment(.leading)
                            Text(recipe.actions.joined(separator: " → "))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Mono.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(StudioCardButtonStyle())
                }
            }
            outputEditor
        }
    }

    private var dataLabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            StudioIntro(
                symbol: "chart.xyaxis.line",
                title: "studio.data.title",
                detail: "studio.data.detail"
            )
            inputEditor(title: "studio.input", text: $input)
            HStack(spacing: 8) {
                Menu {
                    ForEach(PasteDestination.allCases, id: \.self) { value in
                        Button(value.rawValue) { destination = value }
                    }
                } label: {
                    Text(destination.rawValue)
                }
                .buttonStyle(MonoSecondaryButtonStyle())
                Button("studio.convert") {
                    output = ContextAwarePasteEngine().adapt(input, destination: destination)
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                Button("studio.sql.analyze") { analyzeSQL() }
                    .buttonStyle(MonoSecondaryButtonStyle())
                Button("studio.schema") {
                    output = SchemaIntelligence().jsonSchema(from: input) ?? ""
                }
                .buttonStyle(MonoSecondaryButtonStyle())
            }
            if let profile = TabularProfiler().profile(input) {
                profileCard(profile)
            }
            inputEditor(title: "studio.compare.second", text: $secondaryInput)
            Button("studio.compare") { compareTables() }
                .buttonStyle(MonoSecondaryButtonStyle())
            outputEditor
        }
    }

    private func inputEditor(title: LocalizedStringKey, text: Binding<String>) -> some View {
        MonoCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11, weight: .semibold))
                TextEditor(text: text)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
            }
        }
    }

    @ViewBuilder private var outputEditor: some View {
        if !output.isEmpty {
            MonoCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("studio.output").font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button("action.copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output, forType: .string)
                        }
                        .buttonStyle(MonoSecondaryButtonStyle())
                    }
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func profileCard(_ profile: TabularProfile) -> some View {
        MonoCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("intelligence.dataProfile", systemImage: "tablecells")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(profile.rowCount) rows · \(profile.columnCount) columns · \(profile.duplicateRowCount) duplicates")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Mono.secondaryText)
                ForEach(profile.columns, id: \.name) { column in
                    HStack {
                        Text(column.name)
                        Spacer()
                        Text(column.type.rawValue)
                        Text("missing \(column.missingCount)")
                        if let numeric = column.numeric {
                            Text("μ \(numeric.mean.formatted(.number.precision(.fractionLength(0...2))))")
                            if numeric.outlierCount > 0 {
                                Text("outliers \(numeric.outlierCount)")
                            }
                        }
                        if column.isPotentialPII { Image(systemName: "lock.trianglebadge.exclamationmark") }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Mono.secondaryText)
                }
            }
        }
    }

    private func loadLatestInput() {
        if input.isEmpty {
            input = model.items.first(where: { !$0.isSensitive })?.rawText ?? ""
        }
    }

    private func run(_ recipe: AutomationRecipe) {
        switch recipe.trigger {
        case "sql": analyzeSQL()
        case "json": output = SchemaIntelligence().jsonSchema(from: input) ?? ""
        default:
            let pipeline = ClipboardPipeline(
                name: recipe.name,
                steps: [
                    .init(name: "Empty rows", operation: .dropEmptyRows),
                    .init(name: "Duplicates", operation: .removeDuplicates(columns: []))
                ]
            )
            output = PipelineEngine().run(pipeline, input: input)?.output
                ?? QuickTextTransformer().apply(.clean, to: input)
        }
    }

    private func analyzeSQL() {
        let result = SQLCopilot().analyze(input)
        let findings = result.findings.map { "[\($0.severity.rawValue.uppercased())] \($0.title): \($0.detail)" }
        output = ([result.formattedSQL] + findings).joined(separator: "\n\n")
    }

    private func compareTables() {
        guard let first = CSVTable(text: input), let second = CSVTable(text: secondaryInput) else {
            output = AppLocalization.string("studio.compare.invalid", languageCode: model.languageCode)
            return
        }
        let difference = DatasetComparator().compare(first, second)
        output = """
        +\(difference.addedRows) rows
        -\(difference.removedRows) rows
        \(difference.changedCells) changed cells
        Added columns: \(difference.addedColumns.joined(separator: ", "))
        Removed columns: \(difference.removedColumns.joined(separator: ", "))
        """
    }
}

private struct StudioIntro: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).frame(width: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(Mono.tertiaryText)
            }
        }
    }
}

private struct StudioEmpty: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Mono.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(28)
    }
}

private struct SettingsLikeCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View {
        MonoCard {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 12, weight: .semibold))
                content.font(.system(size: 10)).foregroundStyle(Mono.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StudioCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(14)
            .background(Mono.panelRaised.opacity(configuration.isPressed ? 0.65 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Mono.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Mono.corner).stroke(Mono.line, lineWidth: 1))
    }
}
