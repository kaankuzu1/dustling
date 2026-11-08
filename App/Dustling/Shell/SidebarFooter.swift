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
private struct StorageMeter: View {
    /// nil while there is no reading: only the track shows, never a made-up value.
    let usedFraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SidebarTokens.meterTrack))
            guard let usedFraction else { return }
            let filled = (size.width * min(max(usedFraction, 0), 1)).rounded()
            var x: CGFloat = 0
            while x < filled {
                let w = min(4, filled - x)
                context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(DustlingTheme.Palette.accent))
                x += 5
            }
        }
        .frame(height: 6)
        .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.meter, reduceMotion: reduceMotion), value: usedFraction)
    }
}

// MARK: - Health lights

/// The Full Disk Access status line from the mockup, with the three health lights (Full Disk Access,
/// cleanup helper, last run) beside it. Clicking it opens the health popover.
private struct HealthLightsButton: View {
    @Binding var selection: Destination
    @Environment(AppModels.self) private var models
    @State private var showsPopover = false
    private typealias Palette = DustlingTheme.Palette

    /// The lights to show. The Full Disk Access light stays hidden until the first probe finishes.
    private var lights: [HealthLight] {
        models.health.lights.filter { $0.kind != .fullDiskAccess || models.hasProbedFullDiskAccess }
    }

    private var fullDiskAccessLight: HealthLight? { lights.first { $0.kind == .fullDiskAccess } }

    private var fullDiskAccessLine: String {
        switch models.health.fullDiskAccess {
        case .granted: return "Full Disk Access is on"
        case .denied: return "Full Disk Access is off"
        case .unknown: return "Couldn't verify Full Disk Access"
        }
    }

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                if let fda = fullDiskAccessLight {
                    PixelIconView(fda.state == .ok ? .shield : .warn, color: fda.state == .ok ? Palette.success : Palette.warning)
                    Text(fullDiskAccessLine)
                        .foregroundStyle(Palette.sidebarMuted)
                        .lineLimit(1)
                } else {
                    Text("Checking Full Disk Access…")
                        .foregroundStyle(Palette.sidebarMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(lights, id: \.kind) { light in
                        Circle().fill(light.state.color).frame(width: 7, height: 7)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dustling health")
        .accessibilityLabel("Dustling health")
        .accessibilityValue(lights.map { "\($0.kind.title): \($0.state.spoken)" }.joined(separator: ", "))
        .popover(isPresented: $showsPopover, arrowEdge: .trailing) {
            HealthPopover(lights: lights, isCheckingFullDiskAccess: !models.hasProbedFullDiskAccess) { fix in
                perform(fix)
            }
        }
    }

    private func perform(_ fix: FixAction) {
        switch fix {
        case .openFullDiskAccessSettings:
            if !NSWorkspace.shared.open(FullDiskAccessProbe.settingsURL) {
                NSLog("Dustling: couldn't open System Settings at \(FullDiskAccessProbe.settingsURL)")
                let alert = NSAlert()
                alert.messageText = "System Settings didn't open"
                alert.informativeText = "Open System Settings yourself, then go to Privacy & Security > Full Disk Access and switch Dustling on."
                alert.runModal()
            }
        case .viewLastRun:
            showsPopover = false
            selection = .history
        }
    }
}

/// The health popover (E03 in the approved mockups): each check with its light and its fix.
private struct HealthPopover: View {
    let lights: [HealthLight]
    let isCheckingFullDiskAccess: Bool
    let perform: (FixAction) -> Void
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dustling health")
                .font(DustlingTheme.Typography.rowTitle)
                .foregroundStyle(Palette.ink)
            if isCheckingFullDiskAccess {
                Text("Checking Full Disk Access…")
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
            }
            ForEach(lights, id: \.kind) { light in
                HStack(alignment: .center, spacing: 8) {
                    ZStack {
                        Circle().fill(light.state.color)
                        // The mockup draws a 12 pt glyph; pixel icons only come at integer scales, so 8 pt.
                        PixelIconView(light.state.icon, color: .white, size: .small)
                    }
                    .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(light.kind.title)
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                            .foregroundStyle(Palette.ink)
                        Text(light.detail)
                            .font(DustlingTheme.Typography.caption)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let fix = light.fix {
                        Button(fix.title) { perform(fix) }
                            .buttonStyle(.link)
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                            .foregroundStyle(Palette.accent)
                    } else if light.state == .ok {
                        Text("OK")
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: 320, alignment: .leading)
        .background(Palette.ground)
    }
}

private extension HealthLight.Kind {
    var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .helper: return "Cleanup helper"
        case .lastRun: return "Last run"
        }
    }
}

private extension HealthLight.State {
    var color: Color {
        switch self {
        case .ok: return DustlingTheme.Palette.success
        case .warning: return DustlingTheme.Palette.warning
        // Ruling R48: "not available yet" is neutral, not a problem.
        case .info: return DustlingTheme.Palette.muted
        }
    }

    var icon: PixelIcon {
        switch self {
        case .ok: return .check
        case .warning: return .warn
        case .info: return .info
        }
    }

    var spoken: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "needs attention"
        case .info: return "not available yet"
        }
    }
}

private extension FixAction {
    var title: String {
        switch self {
        case .openFullDiskAccessSettings: return "Open System Settings"
        case .viewLastRun: return "View last run"
        }
    }
}
