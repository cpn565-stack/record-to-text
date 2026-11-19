import RecordToTextCore
import SwiftUI

struct GlossaryManagerView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var selection: GlossarySelection?
    @State private var searchQuery = ""
    @State private var draftName = ""
    @State private var draftTerms = ""
    @State private var savedBaselineName = ""
    @State private var savedBaselineTerms = ""
    @State private var glossaryPendingDeletion: GlossaryPreset?
    @State private var inlineErrorMessage: String?
    @State private var showSavedToast = false
    @State private var savedToastTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "詞庫管理",
                subtitle: "共用詞彙會套用到所有工作；專案詞庫只套用目前選取的項目。"
            ) {
                Button("完成") {
                    if saveDraft() {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.xl)

            Divider()

            HSplitView {
                sidebar
                    .frame(minWidth: 220, idealWidth: 245, maxWidth: 290)

                editor
                    .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 540)
        .interactiveDismissDisabled()
        .onAppear {
            if let selectedID = viewModel.settings.lastSelectedGlossaryID,
               viewModel.glossaryCollection.glossaries.contains(where: { $0.id == selectedID })
            {
                selection = .glossary(selectedID)
            } else {
                selection = .common
            }
            loadDraft()
        }
        .onChange(of: selection) {
            loadDraft()
        }
        .onDisappear {
            savedToastTask?.cancel()
        }
        .confirmationDialog(
            "刪除詞庫「\(glossaryPendingDeletion?.name ?? "")」？",
            isPresented: Binding(
                get: { glossaryPendingDeletion != nil },
                set: { if !$0 { glossaryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("刪除詞庫", role: .destructive) {
                if let glossaryPendingDeletion {
                    viewModel.deleteGlossary(id: glossaryPendingDeletion.id)
                    selection = .common
                }
                glossaryPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                glossaryPendingDeletion = nil
            }
        } message: {
            Text("已排入佇列的工作仍保留加入當下的詞彙 Snapshot。")
        }
    }

    // MARK: - Sidebar

    private var filteredGlossaries: [GlossaryPreset] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return viewModel.glossaryCollection.glossaries
        }
        return viewModel.glossaryCollection.glossaries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜尋專案詞庫…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜尋")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppColors.insetSurface, in: RoundedRectangle(cornerRadius: AppRadius.badge))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.badge)
                    .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
            }
            .padding(AppSpacing.sm)

            Divider()

            List(
                selection: Binding(
                    get: { selection },
                    set: { newSelection in
                        guard newSelection != selection else { return }
                        guard !hasUnsavedChanges || saveDraft(showFeedback: false) else {
                            return
                        }
                        selection = newSelection
                        loadDraft()
                    }
                )
            ) {
                Section {
                    HStack {
                        Label("共用詞彙", systemImage: "person.2")
                        Spacer()
                        StatusBadge(
                            text: "\(viewModel.glossaryCollection.commonTerms.count)",
                            color: AppColors.neutral
                        )
                    }
                    .tag(GlossarySelection.common)
                }

                Section("專案詞庫") {
                    if filteredGlossaries.isEmpty {
                        Text(searchQuery.isEmpty ? "尚無專案詞庫" : "找不到符合的詞庫")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredGlossaries) { glossary in
                            HStack {
                                Label(glossary.name, systemImage: "text.book.closed")
                                    .lineLimit(1)
                                Spacer()
                                StatusBadge(
                                    text: "\(glossary.terms.count)",
                                    color: AppColors.neutral
                                )
                            }
                            .tag(GlossarySelection.glossary(glossary.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: AppSpacing.sm) {
                Button {
                    guard !hasUnsavedChanges || saveDraft(showFeedback: false) else {
                        return
                    }
                    searchQuery = ""
                    let id = viewModel.createGlossary()
                    selection = .glossary(id)
                    loadDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新增專案詞庫")
                .accessibilityLabel("新增專案詞庫")

                Button {
                    guard case let .glossary(id) = selection,
                          let glossary = viewModel.glossaryCollection.glossaries.first(
                              where: { $0.id == id }
                          )
                    else {
                        return
                    }
                    glossaryPendingDeletion = glossary
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(!isProjectGlossarySelected)
                .help("刪除選取詞庫")
                .accessibilityLabel("刪除選取詞庫")

                Spacer()

                Menu {
                    Button("從檔案匯入詞彙（附加至目前詞庫）…") {
                        importTermsIntoCurrentDraft()
                    }
                    Button("匯出目前詞庫為 TXT…") {
                        exportCurrentDraft()
                    }
                    .disabled(parsedDraftTerms.isEmpty)
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("匯入或匯出詞彙")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Editor

    private var parsedDraftTerms: [String] {
        TermParser.parse(draftTerms)
    }

    private var combinedTermCountWithCommon: Int {
        switch selection {
        case .common:
            return parsedDraftTerms.count
        case .glossary:
            let merged = TermParser.merge([
                viewModel.glossaryCollection.commonTerms,
                parsedDraftTerms
            ])
            return merged.count
        case nil:
            return 0
        }
    }

    private var hasUnsavedChanges: Bool {
        guard selection != nil else { return false }
        if isProjectGlossarySelected,
           draftName.trimmingCharacters(in: .whitespacesAndNewlines) != savedBaselineName
        {
            return true
        }
        return draftTerms != savedBaselineTerms
    }

    @ViewBuilder
    private var editor: some View {
        if selection == nil {
            ContentUnavailableView(
                "選擇一個詞庫",
                systemImage: "text.book.closed",
                description: Text("從左側選擇共用詞彙或專案詞庫。")
            )
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(spacing: AppSpacing.sm) {
                    if isProjectGlossarySelected {
                        TextField("詞庫名稱", text: $draftName)
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text("共用詞彙")
                            .font(.title3.weight(.semibold))
                    }

                    if hasUnsavedChanges {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(AppColors.warning)
                                .frame(width: 7, height: 7)
                            Text("未儲存變更")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AppColors.warning)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            AppColors.warning.opacity(AppColors.statusTintOpacity),
                            in: Capsule()
                        )
                        .accessibilityLabel("有未儲存的變更")
                    }

                    Spacer(minLength: 0)
                }

                Text("每行一個詞彙，也可使用逗號、頓號或分號分隔；儲存時會自動去重並保持順序。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let inlineErrorMessage {
                    InlineCallout(color: AppColors.danger) {
                        HStack(spacing: AppSpacing.sm) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(AppColors.danger)
                            Text(inlineErrorMessage)
                                .font(.caption)
                            Spacer()
                        }
                    }
                }

                TextEditor(text: $draftTerms)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(AppColors.insetSurface, in: RoundedRectangle(cornerRadius: AppRadius.row))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppRadius.row)
                            .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
                    }

                HStack(spacing: AppSpacing.sm) {
                    let count = parsedDraftTerms.count
                    let combined = combinedTermCountWithCommon
                    let overBudget = combined > PromptBuilder.maximumTerms

                    Text(
                        isProjectGlossarySelected
                            ? "此詞庫 \(count) 個詞彙（含共用合計 \(combined)／\(PromptBuilder.maximumTerms)）"
                            : "共 \(count)／\(PromptBuilder.maximumTerms) 個共用詞彙"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(overBudget ? AppColors.danger : .secondary)

                    if showSavedToast {
                        Label("已儲存", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColors.success)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                AppColors.success.opacity(AppColors.statusTintOpacity),
                                in: Capsule()
                            )
                            .transition(.opacity)
                    }

                    Spacer()

                    Button("還原") {
                        loadDraft()
                    }
                    .disabled(!hasUnsavedChanges)

                    Button("儲存") {
                        _ = saveDraft(showFeedback: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(AppSpacing.xl)
        }
    }

    private var isProjectGlossarySelected: Bool {
        if case .glossary = selection {
            return true
        }
        return false
    }

    private func loadDraft() {
        inlineErrorMessage = nil
        switch selection {
        case .common:
            draftName = ""
            draftTerms = viewModel.glossaryCollection.commonTerms.joined(separator: "\n")
            savedBaselineName = ""
            savedBaselineTerms = draftTerms
        case let .glossary(id):
            guard let glossary = viewModel.glossaryCollection.glossaries.first(
                where: { $0.id == id }
            ) else {
                selection = .common
                return
            }
            draftName = glossary.name
            draftTerms = glossary.terms.joined(separator: "\n")
            savedBaselineName = glossary.name
            savedBaselineTerms = draftTerms
        case nil:
            draftName = ""
            draftTerms = ""
            savedBaselineName = ""
            savedBaselineTerms = ""
        }
    }

    @discardableResult
    private func saveDraft(showFeedback: Bool = false) -> Bool {
        let didSave: Bool
        switch selection {
        case .common:
            inlineErrorMessage = nil
            viewModel.updateCommonTerms(draftTerms)
            loadDraft()
            didSave = true
        case let .glossary(id):
            if let validationError = viewModel.glossaryNameValidationError(id: id, name: draftName) {
                inlineErrorMessage = validationError
                return false
            }
            inlineErrorMessage = nil
            let updated = viewModel.updateGlossary(
                id: id,
                name: draftName,
                termsText: draftTerms,
                suppressAlert: true
            )
            if updated {
                loadDraft()
            }
            didSave = updated
        case nil:
            inlineErrorMessage = nil
            didSave = true
        }

        if didSave && showFeedback {
            presentSavedToast()
        }
        return didSave
    }

    private func presentSavedToast() {
        savedToastTask?.cancel()
        if reduceMotion {
            showSavedToast = true
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                showSavedToast = true
            }
        }
        savedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                showSavedToast = false
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSavedToast = false
                }
            }
        }
    }

    private func importTermsIntoCurrentDraft() {
        guard let imported = viewModel.chooseAndImportGlossaryTerms(),
              !imported.isEmpty
        else {
            return
        }
        let merged = TermParser.parse(
            ([draftTerms] + imported).filter { !$0.isEmpty }.joined(separator: "\n")
        )
        draftTerms = merged.joined(separator: "\n")
    }

    private func exportCurrentDraft() {
        let name = isProjectGlossarySelected
            ? (draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "專案詞庫" : draftName)
            : "共用詞彙"
        viewModel.exportGlossaryTerms(defaultFileName: name, terms: parsedDraftTerms)
    }
}

private enum GlossarySelection: Hashable {
    case common
    case glossary(String)
}
