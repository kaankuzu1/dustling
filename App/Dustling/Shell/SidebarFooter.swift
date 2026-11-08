import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// The sidebar footer (SCREENS-final, Shell and §8): the startup disk's storage meter, available and
/// total space, the macOS update requirement, the health lights and Settings.
struct SidebarFooter: View {
    @Binding var selection: Destination
    @Environment(AppModels.self) private var models
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(models.volumeName)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                .lineLimit(1)
            StorageSummary(storage: models.storage, goal: models.goal)
            HealthLightsButton(selection: $selection)
            // Settings opens the Settings window. It shows as selected while the Diagnostics page (which
            // belongs to Settings > Permissions and helper) is open, as in the approved mockup.
            SettingsLink {
                HStack(spacing: 9) {
                    PixelIconView(.gear, color: Palette.sidebarIcon).frame(width: 18, height: 18)
                    Text("Settings")
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                        .foregroundStyle(Palette.sidebarInk)
                    Spacer(minLength: 0)
                }
                .frame(height: 32)
                .padding(.horizontal, 4)
                .background {
                    RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                        .fill(Palette.sidebarSelection.opacity(selection == .diagnostics ? 1 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
        .padding(EdgeInsets(top: 14, leading: 8, bottom: 0, trailing: 8))
        .overlay(alignment: .top) {
            Rectangle().fill(SidebarTokens.line).frame(height: 1).accessibilityHidden(true)
        }
    }
}

// MARK: - Storage

private struct StorageSummary: View {
    let storage: StorageModel
    let goal: UpdateGoal
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        if let info = storage.info {
            // "Available" is what Finder and the macOS updater count: it includes purgeable space.
            let available = info.availableForImportantUsage
            let used = info.totalBytes > 0 ? 1 - Double(available) / Double(info.totalBytes) : 0
            StorageMeter(usedFraction: used)
                .accessibilityLabel("Storage used")
                .accessibilityValue("\(Int((used * 100).rounded())) percent")
            Text("\(Bytes.format(available)) available of \(Bytes.format(info.totalBytes))")
                .foregroundStyle(Palette.sidebarMuted)
                .monospacedDigit()
                .contentTransition(.numericText())
        } else if let problem = storage.problems.first {
            StorageMeter(usedFraction: nil)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PixelIconView(.warn, color: Palette.warning).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(problem).foregroundStyle(Palette.sidebarMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            StorageMeter(usedFraction: nil)
            Text("Reading storage…").foregroundStyle(Palette.sidebarMuted)
        }
        Text("The macOS update needs \(Bytes.format(goal.neededBytes))")
            .foregroundStyle(Palette.sidebarMuted)
            .monospacedDigit()
    }
}

/// A 6 pt meter, square-cornered and segmented 4 on / 1 off like the mockup's `.win.pix .w-meter`.
/// Changes animate over 0.6 s (DESIGN-mosaic §9), instantly under Reduce Motion.
private struct StorageMeter: View {
    /// nil while there is no reading: only the track shows, never a made-up value.
    let usedFraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MeterBar(fraction: usedFraction ?? 0, showsFill: usedFraction != nil)
            .frame(height: 6)
            .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.meter, reduceMotion: reduceMotion), value: usedFraction)
    }
}

/// The meter's drawing. `Animatable`, so SwiftUI interpolates the fraction and redraws the Canvas.
private struct MeterBar: View, Animatable {
    var fraction: Double
    let showsFill: Bool

    nonisolated var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        let fraction = min(max(self.fraction, 0), 1)
        let showsFill = self.showsFill
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SidebarTokens.meterTrack))
            guard showsFill else { return }
            let filled = (size.width * fraction).rounded()
            var x: CGFloat = 0
            while x < filled {
                let w = min(4, filled - x)
                context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(DustlingTheme.Palette.accent))
                x += 5
            }
        }
    }
}
