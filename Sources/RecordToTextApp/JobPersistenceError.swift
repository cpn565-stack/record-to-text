import Foundation

enum JobPersistenceError: LocalizedError {
    case unreadableJournal(String)
    case credentialLoading
    case credentialMigration
    case timedOut
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableJournal(detail):
            return "既有工作紀錄無法讀取，為避免覆寫原始資料，已停止儲存。\(detail)"
        case .credentialLoading:
            return "仍在等待 Keychain 載入舊版 API Key，尚未改寫工作紀錄。請完成或取消系統的金鑰授權視窗，再重試儲存。"
        case .credentialMigration:
            return "舊版 API Key 尚未成功備份至 Keychain，因此保留原始工作紀錄。請在設定中處理金鑰儲存問題後重試。"
        case .timedOut:
            return "等待工作紀錄寫入逾時；背景儲存可能仍在進行，請稍候重試。"
        case let .writeFailed(detail):
            return "工作紀錄寫入失敗：\(detail)"
        }
    }
}
