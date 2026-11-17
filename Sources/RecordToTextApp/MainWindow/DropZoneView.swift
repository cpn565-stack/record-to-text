import SwiftUI

struct DropZoneView: View {
    let isTargeted: Bool
    let compact: Bool
    let chooseFiles: () -> Void

    var body: some View {
        Group {
            if compact {
                compactContent
            } else {
                expandedContent
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 10 : 28)
        .padding(.horizontal, compact ? 12 : 0)
        .background(
            isTargeted ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: compact ? 10 : 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 10 : 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [7, 5])
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: compact ? 10 : 12))
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("錄音檔拖放區")
        .accessibilityHint("可將錄音檔拖到主視窗文字輸入框以外的位置，或按下按鈕選擇檔案")
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            VStack(spacing: 4) {
                Text(isTargeted ? "放開以加入佇列" : "將錄音拖入視窗")
                    .font(.title3.weight(.semibold))
                Text("M4A、MP3、WAV、AAC、FLAC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("選擇錄音檔…", action: chooseFiles)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                .font(.system(size: 18, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(isTargeted ? "放開以加入佇列" : "將錄音拖入視窗")
                    .font(.subheadline.weight(.semibold))
                Text("M4A、MP3、WAV、AAC、FLAC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("選擇錄音檔…", action: chooseFiles)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }
}
