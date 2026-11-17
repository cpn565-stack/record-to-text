import RecordToTextCore
import SwiftUI

struct ComposerView: View {
    @ObservedObject var viewModel: AppViewModel
    let isDropTargeted: Bool
    @State private var isTranscriptionSettingsExpanded = false

    var body: some View {
        AppCard {
            VStack(spacing: 14) {
                transcriptionSettingsDisclosure

                Divider()

                DropZoneView(
                    isTargeted: isDropTargeted,
                    compact: !viewModel.jobs.isEmpty,
                    chooseFiles: { viewModel.chooseAudioFiles() }
                )

                if viewModel.hasQueuedJobs {
                    HStack(spacing: 10) {
                        Button {
                            viewModel.startQueuedJobs()
                        } label: {
                            Label("開始轉文字", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("開始處理佇列中等待的錄音")

                        splitQueuedAction
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                QueueSleepControls(coordinator: viewModel.queueSleep, setEnabled: viewModel.setSleepAfterCompletion)

                HStack(spacing: 10) {
                    Button {
                        viewModel.chooseAndMergeTranscriptFiles()
                    } label: {
                        Label("合併文字稿…", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.bordered)
                    .help("選取兩份以上 TXT，依分段編號排序後合併成新檔")

                    Text("可直接選取切半後的多份 TXT；原檔不會被覆寫。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("輸出位置")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.outputLocationSummary)
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text(viewModel.hasQueuedJobs ? "加入後不會自動開始" : "等待加入檔案")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transcriptionSettingsDisclosure: some View {
        DisclosureGroup(
            isExpanded: $isTranscriptionSettingsExpanded
        ) {
            terminologyEditor
                .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Label("轉錄設定", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))

                Text("\(selectedGlossarySummary) · \(viewModel.promptTermCount) 個詞彙")
                    .font(.caption)
                    .foregroundStyle(
                        viewModel.promptErrorMessage == nil
                            ? Color.secondary
                            : Color.red
                    )
                    .lineLimit(1)

                Spacer()

                Text("詞庫與背景於加入時固定；模型可於開始前切換")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHint("展開後可調整專案詞庫、本次補充詞彙與雲端錄音背景")
    }

    private var terminologyEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker(
                    "專案詞庫",
                    selection: Binding(
                        get: { viewModel.settings.lastSelectedGlossaryID },
                        set: { viewModel.selectGlossary($0) }
                    )
                ) {
                    Text("不使用專案詞庫").tag(String?.none)
                    ForEach(viewModel.glossaryCollection.glossaries) { glossary in
                        Text(glossary.name).tag(Optional(glossary.id))
                    }
                }
                .frame(maxWidth: 330)

                Button("管理詞庫…") {
                    viewModel.isGlossaryManagerPresented = true
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("本次補充")
                    .font(.subheadline.weight(.medium))

                TextEditor(
                    text: Binding(
                        get: { viewModel.settings.lastTemporaryTerms },
                        set: { viewModel.setTemporaryTerms($0) }
                    )
                )
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 84, maxHeight: 116)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityLabel("本次補充專有名詞")

                Text("可用逗號、頓號、分號、空格（中文詞彙）或換行分隔。加入檔案時會鎖定為該工作的 Snapshot。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.settings.backendType != .localQwen {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("錄音背景（選填）").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(viewModel.recordingContextCount) / 500")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(viewModel.recordingContextErrorMessage == nil ? Color.secondary : .red)
                    }
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $viewModel.cloudRecordingContextDraft)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .accessibilityLabel("錄音背景（選填）")
                        if viewModel.cloudRecordingContextDraft.isEmpty {
                            Text("這是一場半導體封裝製程訪談，主要討論先進封裝與量產良率，包含中英文術語。")
                                .font(.body).foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: 96)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    Text("簡述主題或情境，專有名詞請填在詞彙欄。背景會隨音訊送至所選雲端服務。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = viewModel.recordingContextErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }

            if let error = viewModel.promptErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Button {
                    viewModel.isPromptPreviewPresented = true
                } label: {
                    Label("預覽轉錄提示", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.link)
                .disabled(viewModel.recordingContextErrorMessage != nil)
            }
        }
    }

    private var selectedGlossarySummary: String {
        guard let selectedID = viewModel.settings.lastSelectedGlossaryID,
              let selected = viewModel.glossaryCollection.glossaries
                .first(where: { $0.id == selectedID })
        else {
            return "不使用專案詞庫"
        }
        return selected.name
    }

    @ViewBuilder
    private var splitQueuedAction: some View {
        if let job = viewModel.splittableQueuedJobs.first,
           viewModel.splittableQueuedJobs.count == 1
        {
            Button {
                viewModel.splitQueuedAudioFileInHalf(job.id)
            } label: {
                Label("切分再依序轉", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("把已加入佇列的錄音切成前後兩段；第一段先處理，第二段排在後面")
        } else if viewModel.hasSplittableQueuedJobs {
            Menu {
                ForEach(viewModel.splittableQueuedJobs) { job in
                    Button {
                        viewModel.splitQueuedAudioFileInHalf(job.id)
                    } label: {
                        Label(job.displayName, systemImage: "scissors")
                    }
                }
            } label: {
                Label("切分再依序轉", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("選擇已加入佇列的錄音，切成前後兩段並依序處理")
        }
    }
}
