import Foundation

/// Shared Gemini prompt contract for a readable, speaker-attributed transcript.
///
/// Speaker names remain evidence-gated: the model may use a real name only when
/// the audio identifies that person or the canonical prompt/glossary supplies it.
public enum GeminiTranscriptPrompt {
    public static let systemInstruction = """
    你是一位專業的高精度語音逐字稿轉錄專家。請仔細聆聽這段音訊，直接將其轉錄為排版乾淨整齊的「純文字逐字稿 (Plain Text Transcript)」。請忠實保留音訊中實際聽到的原意、語序、口語重複與不完整語句，不要摘要、改寫、刪除或補充。

    【排版與輸出規範】
    1. 純文字輸出：嚴禁使用任何 Markdown 格式標記（禁止使用 **粗體**、### 標題、--- 分隔線、Markdown 標題文字等）。
    2. 時間標記：固定每 5 分鐘標註一次時間區間；若對話主題提早明顯轉換，也可以提前開始下一個區間。格式固定為：[00:00 - 05:00]。不得省略錄音中間應有的 5 分鐘區間。
    3. 講者分辨與分段：
       - 請根據不同說話者的聲音特徵區分講者，每次講者輪替時使用「講者名稱：內容」格式。
       - 只有音訊中有自我介紹、明確稱呼，或詞庫／Prompt 提供姓名且音訊內容相符時，才能使用真實姓名。
       - 無法可靠確認姓名時，一律使用「講者 1：」「講者 2：」等中性標示，不得猜測身分。
       - 每一個講者回合各占一段；不同講者回合之間必須保留一個空白行，不可把多位講者擠在同一段。
       - 禁止在講者名稱外包覆任何符號（嚴禁寫成 **講者**：）。
    4. 中文使用台灣繁體中文，英文專有名詞維持正確大小寫與拼寫。
    5. 嚴禁多餘內容：從音訊第一秒直接開始輸出逐字內容，嚴禁輸出重複內容、前言草稿、開場白（如「好的，以下是逐字稿」）、結尾客套話、背景說明、會議摘要或待辦事項。

    【格式範例】
    [00:00 - 05:00]

    講者 1：大家早，今天我們主要是對齊進度。

    講者 2：我想先補充目前遇到的問題。

    [05:00 - 10:00]

    講者 1：好，我們接著討論下一項。
    """

    public static func buildUserPrompt(
        terms: [String],
        canonicalPrompt: String,
        timeOffsetSeconds: Double
    ) -> String {
        var parts: [String] = []

        if timeOffsetSeconds > 0 {
            let startMin = Int(timeOffsetSeconds) / 60
            let startSec = Int(timeOffsetSeconds) % 60
            let startFormatted = String(
                format: "%02d:%02d",
                startMin,
                startSec
            )
            parts.append(
                "【時間基準通知】：本音訊片段在整場錄音中的起始時間為 \(startFormatted)（第 \(Int(timeOffsetSeconds)) 秒）。請將輸出中的所有時間區間依據此起始時間計算與標註，第一行即從 [\(startFormatted) - ...] 開始；不要從 00:00 重新計時，也不要補寫、重複或猜測前後片段。"
            )
        }

        let trimmedPrompt = canonicalPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedPrompt.isEmpty {
            // JobSnapshot.prompt is canonical and already contains its glossary.
            // Do not append `terms` again or the glossary is duplicated.
            parts.append(trimmedPrompt)
        } else if !terms.isEmpty {
            let termsFormatted = terms.map { "- \($0)" }.joined(separator: "\n")
            parts.append(
                "以下詞彙可能出現在錄音中，也可能包含講者姓名；只有音訊內容相符時才採用，不得自行加入：\n\(termsFormatted)"
            )
        }

        parts.append("請直接開始轉錄上述音訊。")
        return parts.joined(separator: "\n\n")
    }
}
