import AppKit
import SwiftUI

/// Centralized color tokens for the macOS app UI layer.
enum AppColors {
    /// Brand accent aligned with the indigo AppIcon; macOS supplies Light/Dark/High-Contrast variants.
    static let accent = Color(nsColor: .systemIndigo)

    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let neutral = Color.secondary

    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let insetSurface = Color(nsColor: .textBackgroundColor).opacity(0.65)

    static func hairlineBorder(colorSchemeContrast: ColorSchemeContrast = .standard) -> Color {
        let opacity = colorSchemeContrast == .increased ? 0.9 : 0.5
        return Color(nsColor: .separatorColor).opacity(opacity)
    }

    static let statusTintOpacity: Double = 0.09
    static let activeRowTintOpacity: Double = 0.05
}

extension View {
    /// Applies a subtle glass-ready surface on macOS 26+ with a material fallback on macOS 14–15.
    @ViewBuilder
    func adaptiveGlassSurface<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.background(.regularMaterial, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}
