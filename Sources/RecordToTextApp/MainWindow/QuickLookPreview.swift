import QuickLook
import SwiftUI

extension View {
    /// Attaches SwiftUI's native Quick Look sheet/panel for completed transcript files.
    func transcriptQuickLookPreview(_ previewURL: Binding<URL?>) -> some View {
        self.quickLookPreview(previewURL)
    }
}

/// Standardized Quick Look eye button with disabled tooltip support.
struct TranscriptQuickLookButton: View {
    let outputPath: String?
    let isOutputAvailable: Bool
    let onPreview: (URL) -> Void

    var body: some View {
        Group {
            if let outputPath, isOutputAvailable {
                Button {
                    onPreview(URL(fileURLWithPath: outputPath))
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("快速預覽文字稿（Quick Look）")
                .accessibilityLabel("快速預覽文字稿")
            } else {
                Button {} label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .help("文字檔已移動或刪除")
                }
                .accessibilityLabel("快速預覽文字稿（不可用）")
            }
        }
    }
}
