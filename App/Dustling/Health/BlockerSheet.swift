import DustlingAppModel
import DustlingCore
import SwiftUI

/// The blocker sheet (E02 "Sheet" in the approved mockups): only when a screen can't do its job, such
/// as Full Disk Access lost before a scan. Worried Mote, the title, why it happened, and Not now / fix.
/// Everything that doesn't block uses an inline banner instead.
struct BlockerSheet: View {
    let repair: RepairCase
    @Environment(AppModels.self) private var models
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let copy = repair == .fullDiskAccessLost
            ? RepairCase.fullDiskAccessLostCopy(models.fullDiskAccessLoss ?? .unknown)
            : repair.copy
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                // The mockup's 40 pt Mote at the nearest integer scale.
                MoteView(.worried, pixel: 2)
                Text(copy.title)
                    .font(.custom(DustlingTheme.Typography.pixelFamily, size: 22))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(copy.why)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Not now", role: .cancel, action: notNow)
                    .keyboardShortcut(.cancelAction)
                Button(copy.fix, action: fix)
                    .dustlingPrimary()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .frame(width: 560)
        .background(Palette.ground)
        // "Dustling checks again on its own": once access is back, the sheet goes and the scan runs.
        .onChange(of: models.health.fullDiskAccess) { _, status in
            guard repair == .fullDiskAccessLost, status == .granted else { return }
            models.blocker = nil
            models.scanJunk()
        }
    }

    /// Continue in limited mode: Dustling stops treating access as lost, scans only what macOS
    /// allows, and the limited-mode banner says what it can't see.
    private func notNow() {
        models.blocker = nil
        if repair == .fullDiskAccessLost {
            models.accessMemory.acknowledgeLoss()
            models.scanJunk()
        }
    }

    private func fix() {
        switch repair {
        case .fullDiskAccessLost:
            // The sheet stays until access is back; activation re-checks it with a real read.
            openFullDiskAccessSettings()
        case .helperNotResponding:
            HealthFix.perform(.repairHelper, models: models)
            models.blocker = nil
        case .itemsDidNotMove(let count):
            HealthFix.perform(.retryItems(count: count), models: models)
            models.blocker = nil
        }
    }
}
