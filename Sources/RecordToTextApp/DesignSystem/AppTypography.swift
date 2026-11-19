import SwiftUI

/// Typography hierarchy for main window, job rows, and sheets.
enum AppTypography {
    static let sectionTitle: Font = .headline
    static let rowTitle: Font = .body.weight(.semibold)
    static let rowMeta: Font = .callout
    static let chipLabel: Font = .caption.weight(.medium)
    static let numericMeta: Font = .callout.monospacedDigit()
    static let numericCaption: Font = .caption.monospacedDigit()
    static let monoDetail: Font = .caption.monospaced()
}
