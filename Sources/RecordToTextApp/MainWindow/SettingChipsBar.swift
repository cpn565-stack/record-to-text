import RecordToTextCore
import SwiftUI

/// Wrapping bar of 4 Progressive-Disclosure chips for per-batch transcription settings.
struct SettingChipsBar: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var isGlossaryPopoverPresented = false
    @State private var isTemporaryTermsPopoverPresented = false
    @State private var isRecordingContextPopoverPresented = false
    @State private var isOutputLocationPopoverPresented = false

    private var temporaryTermCount: Int {
        TermParser.parse(viewModel.settings.lastTemporaryTerms).count
    }

    var body: some View {
        FlowLayout(horizontalSpacing: AppSpacing.sm, verticalSpacing: AppSpacing.sm) {
            glossaryChip
            temporaryTermsChip
            if viewModel.settings.backendType != .localQwen {
                recordingContextChip
            }
            outputLocationChip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 1. Glossary Chip

    private var glossaryChip: some View {
        let selectedName = viewModel.selectedGlossary?.name
        return SettingChip(
            isActive: selectedName != nil,
            action: { isGlossaryPopoverPresented.toggle() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "text.book.closed")
                Text("詞庫：\(selectedName ?? "不使用")")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help("選擇專案詞庫（加入錄音時與共用詞彙一併鎖定為 Snapshot）")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("專案詞庫")
        .accessibilityValue(selectedName ?? "不使用")
        .accessibilityHint("點擊以切換專案詞庫或開啟詞庫管理")
        .popover(isPresented: $isGlossaryPopoverPresented, arrowEdge: .bottom) {
            glossaryPopover
                .tint(AppColors.accent)
        }
    }

    private var glossaryPopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("專案詞庫")
                    .font(.headline)
                Text("加入錄音時會與共用詞彙一併鎖定為該工作的 Snapshot。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(
                "專案詞庫",
                selection: Binding(
                    get: { viewModel.settings.lastSelectedGlossaryID },
                    set: { viewModel.selectGlossary($0) }
                )
            ) {
                Text("不使用專案詞庫").tag(String?.none)
                ForEach(viewModel.glossaryCollection.glossaries) { glossary in
                    Text("\(glossary.name)（\(glossary.terms.count)）").tag(Optional(glossary.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Text("共用詞彙 \(viewModel.glossaryCollection.commonTerms.count) 個 · 目前合計 \(viewModel.promptTermCount) 個詞彙")
                .font(AppTypography.numericCaption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("管理詞庫…") {
                    isGlossaryPopoverPresented = false
                    viewModel.isGlossaryManagerPresented = true
                }

                Spacer()

                promptPreviewButton {
                    isGlossaryPopoverPresented = false
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 330)
    }

    // MARK: - 2. Temporary Terms Chip

    private var temporaryTermsChip: some View {
        let count = temporaryTermCount
        let hasRawInput = !viewModel.settings.lastTemporaryTerms
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasError = viewModel.promptErrorMessage != nil
        let chipText: String = {
            if count > 0 {
                return "補充詞彙：\(count) 個"
            }
            if hasRawInput {
                return "補充詞彙：已填寫"
            }
            return "+ 補充詞彙"
        }()

        return SettingChip(
            isActive: count > 0,
            isError: hasError,
            action: { isTemporaryTermsPopoverPresented.toggle() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: hasError ? "exclamationmark.triangle.fill" : "plus.bubble")
                Text(chipText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .help(viewModel.promptErrorMessage ?? "設定本次批次補充的專有名詞（加入檔案時鎖定）")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("本次補充詞彙")
        .accessibilityValue(hasError ? "設定錯誤" : (count > 0 ? "\(count) 個" : "未填寫"))
        .accessibilityHint("點擊以編輯臨時補充專有名詞")
        .popover(isPresented: $isTemporaryTermsPopoverPresented, arrowEdge: .bottom) {
            temporaryTermsPopover
                .tint(AppColors.accent)
        }
    }

    private var temporaryTermsPopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("本次補充詞彙")
                    .font(.headline)
                Spacer()
                Text("\(temporaryTermCount) 個詞彙")
                    .font(AppTypography.numericCaption)
                    .foregroundStyle(viewModel.promptErrorMessage == nil ? Color.secondary : AppColors.danger)
                if !viewModel.settings.lastTemporaryTerms.isEmpty {
                    Button("清空") {
                        viewModel.setTemporaryTerms("")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            TextEditor(
                text: Binding(
                    get: { viewModel.settings.lastTemporaryTerms },
                    set: { viewModel.setTemporaryTerms($0) }
                )
            )
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(AppSpacing.sm)
            .frame(height: 96)
            .background(AppColors.insetSurface, in: RoundedRectangle(cornerRadius: AppRadius.row))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.row)
                    .stroke(
                        viewModel.promptErrorMessage == nil
                            ? Color(nsColor: .separatorColor)
                            : AppColors.danger,
                        lineWidth: 1
                    )
            }
            .accessibilityLabel("本次補充專有名詞")

            Text("可用逗號、頓號、分號、空格（中文詞彙）或換行分隔。加入檔案時會鎖定為該工作的 Snapshot。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = viewModel.promptErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.danger)
            }

            Divider()

            HStack {
                Spacer()
                promptPreviewButton {
                    isTemporaryTermsPopoverPresented = false
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 360)
    }

    // MARK: - 3. Cloud Recording Context Chip

    private var recordingContextChip: some View {
        let count = viewModel.recordingContextCount
        let hasError = viewModel.recordingContextErrorMessage != nil
        let labelText = count == 0 ? "錄音背景：未填寫" : "錄音背景：\(count)/500 字"

        return SettingChip(
            isActive: count > 0,
            isError: hasError,
            action: { isRecordingContextPopoverPresented.toggle() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: hasError ? "exclamationmark.triangle.fill" : "text.quote")
                Text(labelText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .help(viewModel.recordingContextErrorMessage ?? "補充錄音主題或情境（最多 500 字，加入檔案時固定並隨音訊送至雲端）")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("錄音背景")
        .accessibilityValue(hasError ? "設定錯誤，\(count) 字" : (count == 0 ? "未填寫" : "\(count) / 500 字"))
        .accessibilityHint("點擊以輸入本次雲端轉錄的錄音背景")
        .popover(isPresented: $isRecordingContextPopoverPresented, arrowEdge: .bottom) {
            recordingContextPopover
                .tint(AppColors.accent)
        }
    }

    private var recordingContextPopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("錄音背景（選填）")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.recordingContextCount) / 500")
                    .font(AppTypography.numericCaption)
                    .foregroundStyle(
                        viewModel.recordingContextErrorMessage == nil ? Color.secondary : AppColors.danger
                    )
                if !viewModel.cloudRecordingContextDraft.isEmpty {
                    Button("清空") {
                        viewModel.cloudRecordingContextDraft = ""
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.cloudRecordingContextDraft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(AppSpacing.sm)
                    .accessibilityLabel("錄音背景（選填）")

                if viewModel.cloudRecordingContextDraft.isEmpty {
                    Text("這是一場半導體封裝製程訪談，主要討論先進封裝與量產良率，包含中英文術語。")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 104)
            .background(AppColors.insetSurface, in: RoundedRectangle(cornerRadius: AppRadius.row))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.row)
                    .stroke(
                        viewModel.recordingContextErrorMessage == nil
                            ? Color(nsColor: .separatorColor)
                            : AppColors.danger,
                        lineWidth: 1
                    )
            }

            Text("簡述主題或情境，專有名詞請填在詞彙欄。背景於加入時固定，並隨音訊送至所選雲端服務。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = viewModel.recordingContextErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.danger)
            }

            Divider()

            HStack {
                Spacer()
                promptPreviewButton {
                    isRecordingContextPopoverPresented = false
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 380)
    }

    // MARK: - 4. Output Location Chip

    private var outputLocationChip: some View {
        let shortSummary = JobModelDisplayHelper.compactOutputFolderSummary(viewModel.settings)
        return SettingChip(
            action: { isOutputLocationPopoverPresented.toggle() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text("輸出：\(shortSummary)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help("輸出位置：\(viewModel.outputLocationSummary)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("輸出位置")
        .accessibilityValue(shortSummary)
        .accessibilityHint("點擊以變更文字稿輸出資料夾或模式")
        .popover(isPresented: $isOutputLocationPopoverPresented, arrowEdge: .bottom) {
            outputLocationPopover
                .tint(AppColors.accent)
        }
    }

    private var outputLocationPopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("輸出位置")
                    .font(.headline)
                Text("決定轉錄完成後的文字稿儲存方式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(
                "輸出模式",
                selection: Binding(
                    get: { viewModel.settings.outputLocationMode },
                    set: { viewModel.setSetting(\.outputLocationMode, to: $0) }
                )
            ) {
                ForEach(OutputLocationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if viewModel.settings.outputLocationMode == .fixedDirectory {
                Text(viewModel.settings.defaultOutputDirectory)
                    .font(AppTypography.monoDetail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(AppSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.insetSurface, in: RoundedRectangle(cornerRadius: AppRadius.badge))

                HStack(spacing: AppSpacing.sm) {
                    Button("選擇資料夾…") {
                        isOutputLocationPopoverPresented = false
                        viewModel.chooseDefaultOutputDirectory()
                    }
                    Button("在 Finder 顯示") {
                        isOutputLocationPopoverPresented = false
                        viewModel.revealDefaultOutputDirectory()
                    }
                }
            } else if viewModel.settings.outputLocationMode == .sameAsSource {
                Text("文字稿會直接儲存在每個原始錄音檔所在的同一資料夾。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("每次加入錄音檔時，都會詢問這批檔案要輸出的目標資料夾。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("檔名範例：錄音\(viewModel.settings.resolvedOutputFilenameSuffix).txt")
                .font(AppTypography.monoDetail)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.lg)
        .frame(width: 350)
    }

    private func promptPreviewButton(beforeOpen: @escaping () -> Void) -> some View {
        Button {
            beforeOpen()
            viewModel.isPromptPreviewPresented = true
        } label: {
            Label("預覽轉錄提示", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.link)
        .font(.caption)
        .disabled(viewModel.promptErrorMessage != nil || viewModel.recordingContextErrorMessage != nil)
    }
}
