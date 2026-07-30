import Darwin
import Foundation
import RecordToTextCore

private enum MockScenario: String {
    case success
    case unsupportedPrompt
    case failure
    case noCompleted
    case slow
}

private func emit(_ event: HelperEvent) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(event)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func argument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name) else {
        return nil
    }
    let valueIndex = CommandLine.arguments.index(after: index)
    guard valueIndex < CommandLine.arguments.endIndex else {
        return nil
    }
    return CommandLine.arguments[valueIndex]
}

guard let requestPath = argument(after: "--request-json") else {
    FileHandle.standardError.write(Data("missing --request-json\n".utf8))
    Darwin.exit(64)
}

let request = try JSONDecoder().decode(
    ASRRequest.self,
    from: Data(contentsOf: URL(fileURLWithPath: requestPath))
)
private let scenario = MockScenario(
    rawValue: request.modelID.replacingOccurrences(of: "mock/", with: "")
) ?? .success

try emit(
    HelperEvent(
        type: "capability",
        supportsSystemPrompt: scenario != .unsupportedPrompt,
        supportsContext: false
    )
)

if scenario == .unsupportedPrompt, !request.terms.isEmpty, !request.allowMissingPrompt {
    try emit(
        HelperEvent(
            type: "error",
            message: "Mock backend 不支援專有名詞提示。",
            code: "glossary_not_supported",
            recoverable: true
        )
    )
    Darwin.exit(2)
}

try emit(HelperEvent(type: "stage", value: "loading_model"))
try emit(HelperEvent(type: "stage", value: "transcribing"))

if scenario == .failure {
    try emit(
        HelperEvent(
            type: "error",
            message: "Mock ASR failure",
            code: "mock_failure",
            recoverable: true
        )
    )
    Darwin.exit(1)
}

if scenario == .slow {
    while true {
        try emit(HelperEvent(type: "heartbeat", message: "Mock ASR 仍在執行"))
        sleep(1)
    }
}

try AtomicFileWriter.writeText(
    "这是 mock 逐字稿，包含 OGSTM。",
    to: URL(fileURLWithPath: request.outputPath)
)

if scenario != .noCompleted {
    try emit(
        HelperEvent(
            type: "completed",
            outputPath: request.outputPath,
            durationSeconds: 0.01
        )
    )
}
