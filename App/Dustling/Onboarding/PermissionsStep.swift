import DustlingAppModel
import DustlingCore
import SwiftUI

/// Step 3 (O04 "Permission board" in the Stepper frame): one row per permission with its status.
/// The helper arrives in a later version, so its row says "Not available yet" and offers no button.
/// The notifications row is left out of v1 (Ruling R33).
struct PermissionsStep: View {
    let skip: () -> Void
    @Environment(AppModels.self) private var models

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeadline(
                title: "Set up Dustling",
                caption: "Dustling checks these every time it opens, so nothing fails silently later.")
            VStack(spacing: 16) {
                PermissionRow(
                    icon: .disk, title: "Full Disk Access", detail: "Checked by reading a protected folder."
                ) {
                    fullDiskAccessStatus
                }
                PermissionRow(
                    icon: .lock, title: "Cleanup helper",
                    detail: "Moves system caches and logs that belong to macOS."
                ) {
                    Chip(text: "Not available yet", onPanel: true)
                }
            }
            HStack(spacing: 12) {
                Button("Continue") { models.onboarding.step = .ready }
                    .dustlingPrimary()
                    .keyboardShortcut(.defaultAction)
                Button("Skip for now", action: skip)
            }
        }
    }

    @ViewBuilder private var fullDiskAccessStatus: some View {
        if !models.hasProbedFullDiskAccess {
            Chip(text: "Checking…", onPanel: true)
        } else {
            switch models.health.fullDiskAccess {
            case .granted:
                Chip(text: "On", kind: .success, icon: .check)
            case .denied:
                Chip(text: "Off", kind: .warning)
                OpenSettingsButton(primary: false)
            case .unknown:
                Chip(text: "Couldn't verify", kind: .warning)
                OpenSettingsButton(primary: false)
            }
        }
    }
}

/// One row of the permission board: a 36 pt icon tile, the title and one sentence, then the status chip
/// and an action, if there is one that works.
private struct PermissionRow<Status: View>: View {
    let icon: PixelIcon
    let title: String
    let detail: String
    @ViewBuilder var status: () -> Status
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.ground)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.accent.opacity(0.14)))
                .frame(width: 36, height: 36)
                .overlay { PixelIconView(icon, color: Palette.accent) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 14).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(OnboardingType.caption())
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) { status() }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
