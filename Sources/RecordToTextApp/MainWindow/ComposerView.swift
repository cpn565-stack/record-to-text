import RecordToTextCore
import SwiftUI

/// Top intake composer combining the adaptive Hero/Compact drop zone and Progressive-Disclosure setting chips.
struct ComposerView: View {
    @ObservedObject var viewModel: AppViewModel
    let isDropTargeted: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    /// Hero drop zone stays open whenever nothing is actively queued or running,
    /// even when completed history items are listed below (fixes D-04).
    private var isCompactDropZone: Bool {
        viewModel.hasQueuedJobs || viewModel.hasActiveJob
    }

    private var isCompletelyEmpty: Bool {
        viewModel.jobs.isEmpty && viewModel.recentJobs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            DropZoneView(
                isTargeted: isDropTargeted,
                compact: isCompactDropZone,
                showOnboardingSteps: isCompletelyEmpty,
                chooseFiles: { viewModel.chooseAudioFiles() }
            )

            SettingChipsBar(viewModel: viewModel)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.composer))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.composer)
                .stroke(AppColors.hairlineBorder(colorSchemeContrast: contrast), lineWidth: 1)
        }
    }
}
