import Darwin
import Foundation
import RecordToTextCore

private enum MockScenario: String {
    case success
    case unsupportedPrompt
    case failure
    case noCompleted
    case slow
    case segmented
    case segmentedFailure
    case segmentedMiddleFailure
    case segmentedBlank
    case segmentedTokenLimit
    case segmentedNoCompleted
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

let isLastSegment = request.segmentIndex == request.segmentCount

if
    scenario == .failure
        || (scenario == .segmentedFailure && isLastSegment)
        || (scenario == .segmentedMiddleFailure && request.segmentIndex == 2)
{
    try emit(
        HelperEvent(
            type: "error",
            message: "Mock ASR failure at segment \(request.segmentIndex)",
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

let containsSkippedAudio = scenario == .segmentedTokenLimit && isLastSegment

let transcript: String
if scenario == .segmentedBlank && isLastSegment {
    transcript = " \n\t"
} else if [
    MockScenario.segmented,
    .segmentedFailure,
    .segmentedMiddleFailure,
    .segmentedBlank,
    .segmentedTokenLimit,
    .segmentedNoCompleted
].contains(scenario) {
    let tail = isLastSegment ? "尾段唯一验证句。" : ""
    let gap = containsSkippedAudio
        ? "\n【此處約缺少 30 秒：模型達到 token 上限，已跳過此片段】"
        : ""
    transcript = "这是第 \(request.segmentIndex) 段。\(tail)\(gap)"
} else {
    transcript = "这是 mock 逐字稿，包含 OGSTM。"
}

if containsSkippedAudio {
    try emit(
        HelperEvent(
            type: "warning",
            message: "Mock 約 30 秒片段達到 token 上限，已跳過並繼續。",
            code: "chunk_skipped_token_limit",
            recoverable: true
        )
    )
}

try AtomicFileWriter.writeText(
    transcript,
    to: URL(fileURLWithPath: request.outputPath)
)

if
    scenario != .noCompleted,
    !(scenario == .segmentedNoCompleted && isLastSegment)
{
    try emit(
        HelperEvent(
            type: "completed",
            outputPath: request.outputPath,
            durationSeconds: 0.01,
            containsSkippedAudio: containsSkippedAudio
        )
    )
}
