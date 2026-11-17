import RecordToTextCore
import SwiftUI

/// Keep an unfinished custom ID out of saved settings and queued job snapshots.
struct GeminiModelPicker: View {
    @Binding var modelID: String
    @State private var isEditingCustomModel: Bool
    @State private var customModelDraft: String

    init(modelID: Binding<String>) {
        _modelID = modelID
        _isEditingCustomModel = State(initialValue: !Self.isPreset(modelID.wrappedValue))
        _customModelDraft = State(initialValue: modelID.wrappedValue)
    }

    var body: some View {
        Picker("模型選擇", selection: Binding(
            get: { isEditingCustomModel ? "custom" : modelID },
            set: { selection in
                if selection == "custom" {
                    customModelDraft = modelID
                    isEditingCustomModel = true
                } else {
                    isEditingCustomModel = false
                    customModelDraft = selection
                    modelID = selection
                }
            }
        )) {
            ForEach(GeminiModelDescriptor.presetModels) { preset in
                Text(preset.displayName).tag(preset.id)
            }
            Text("自訂模型 ID…").tag("custom")
        }
        .accessibilityIdentifier("gemini-model-picker")
        // Follow explicit changes from the main window's quick selector.
        .onChange(of: modelID) { _, newValue in
            customModelDraft = newValue
            isEditingCustomModel = !Self.isPreset(newValue)
        }

        if isEditingCustomModel {
            HStack {
                TextField("自訂模型 ID (Model ID)", text: $customModelDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCustomModel)
                    .accessibilityIdentifier("gemini-custom-model-id")
                Button("套用", action: applyCustomModel)
                    .disabled(normalizedDraft.isEmpty || normalizedDraft == modelID)
                    .accessibilityIdentifier("gemini-apply-custom-model")
            }
            Text("自訂模型 ID 輸入完成後按「套用」。目前使用：\(modelID)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let preset = GeminiModelDescriptor.presetModels.first(where: { $0.id == modelID }) {
            Text(preset.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var normalizedDraft: String {
        customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyCustomModel() {
        let value = normalizedDraft
        guard !value.isEmpty, value != modelID else { return }
        customModelDraft = value
        isEditingCustomModel = !Self.isPreset(value)
        modelID = value
    }

    private static func isPreset(_ value: String) -> Bool {
        GeminiModelDescriptor.presetModels.contains { $0.id == value }
    }
}
