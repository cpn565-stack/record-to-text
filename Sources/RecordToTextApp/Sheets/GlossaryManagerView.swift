import RecordToTextCore
import SwiftUI

struct GlossaryManagerView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selection: GlossarySelection?
    @State private var draftName = ""
    @State private var draftTerms = ""
    @State private var glossaryPendingDeletion: GlossaryPreset?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("詞庫管理")
                        .font(.title2.weight(.semibold))
                    Text("共用詞彙會套用到所有工作；專案詞庫只套用目前選取的項目。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") {
                    if saveDraft() {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            HSplitView {
                sidebar
                    .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)

                editor
                    .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 540)
        .interactiveDismissDisabled()
        .onAppear {
            if let selectedID = viewModel.settings.lastSelectedGlossaryID,
               viewModel.glossaryCollection.glossaries.contains(where: { $0.id == selectedID }) {
                selection = .glossary(selectedID)
            } else {
                selection = .common
            }
            loadDraft()
        }
        .onChange(of: selection) {
            loadDraft()
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(
                selection: Binding(
                    get: { selection },
                    set: { newSelection in
                        guard saveDraft() else {
                            return
                        }
                        selection = newSelection
                        loadDraft()
                    }
                )
            ) {
                Section {
                    Label("共用詞彙", systemImage: "person.2")
                        .tag(GlossarySelection.common)
                }

                Section("專案詞庫") {
                    ForEach(viewModel.glossaryCollection.glossaries) { glossary in
                        Label(glossary.name, systemImage: "text.book.closed")
                            .tag(GlossarySelection.glossary(glossary.id))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button {
                    guard saveDraft() else {
                        return
                    }
                    let id = viewModel.createGlossary()
                    selection = .glossary(id)
                    loadDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新增詞庫")

                Button {
                    guard case let .glossary(id) = selection,
                          let glossary = viewModel.glossaryCollection.glossaries.first(
                            where: { $0.id == id }
                          ) else {
                        return
                    }
                    glossaryPendingDeletion = glossary
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(!isProjectGlossarySelected)
                .help("刪除詞庫")

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
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
            VStack(alignment: .leading, spacing: 14) {
                if isProjectGlossarySelected {
                    TextField("詞庫名稱", text: $draftName)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text("共用詞彙")
                        .font(.title3.weight(.semibold))
                }

                Text("每行一個詞彙，也可以使用逗號、頓號或分號。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $draftTerms)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(9)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                HStack {
                    Text("\(TermParser.parse(draftTerms).count) 個詞彙")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("還原") {
                        loadDraft()
                    }
                Button("儲存") {
                        _ = saveDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(20)
        }
    }

    private var isProjectGlossarySelected: Bool {
        if case .glossary = selection {
            return true
        }
        return false
    }

    private func loadDraft() {
        switch selection {
        case .common:
            draftName = ""
            draftTerms = viewModel.glossaryCollection.commonTerms.joined(separator: "\n")
        case let .glossary(id):
            guard let glossary = viewModel.glossaryCollection.glossaries.first(
                where: { $0.id == id }
            ) else {
                selection = .common
                return
            }
            draftName = glossary.name
            draftTerms = glossary.terms.joined(separator: "\n")
        case nil:
            draftName = ""
            draftTerms = ""
        }
    }

    @discardableResult
    private func saveDraft() -> Bool {
        switch selection {
        case .common:
            viewModel.updateCommonTerms(draftTerms)
            loadDraft()
            return true
        case let .glossary(id):
            let didSave = viewModel.updateGlossary(
                id: id,
                name: draftName,
                termsText: draftTerms
            )
            if didSave {
                loadDraft()
            }
            return didSave
        case nil:
            return true
        }
    }
}

private enum GlossarySelection: Hashable {
    case common
    case glossary(String)
}
