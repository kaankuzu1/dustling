import AppKit
import DustlingAppModel
import DustlingCore
import ServiceManagement
import SwiftUI

/// The Full Disk Access status line from the sidebar footer, with the three health lights (Full Disk
/// Access, cleanup helper, last run) beside it. Clicking it opens the health popover (SCREENS-final §8).
struct HealthLightsButton: View {
    @Binding var selection: Destination
    @Environment(AppModels.self) private var models
    @State private var showsPopover = false
    private typealias Palette = DustlingTheme.Palette

    /// The lights to show. The Full Disk Access light stays hidden until the first probe has published,
    /// so the pre-probe `.unknown` never flashes as a warning.
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
            HealthPopover(
                lights: lights, isCheckingFullDiskAccess: !models.hasProbedFullDiskAccess,
                openDiagnostics: {
                    showsPopover = false
                    selection = .diagnostics
                })
        }
    }
}

/// The health popover (E03 in the approved mockups): each check with its light and its fix link
/// (Open System Settings, Repair helper or Retry N items), the problem in one line, and Diagnostics.
struct HealthPopover: View {
    let lights: [HealthLight]
    let isCheckingFullDiskAccess: Bool
    let openDiagnostics: () -> Void
    @Environment(AppModels.self) private var models
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
                    HealthDot(state: light.state)
                    Text(light.kind.title)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                    Spacer(minLength: 8)
                    trailing(for: light)
                }
                .help(light.detail)
                .accessibilityElement(children: .combine)
                .accessibilityValue(light.detail)
            }
            if let message = models.retry.message {
                Text(message)
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headline)
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Diagnostics", action: openDiagnostics)
                    .buttonStyle(.link)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: 340, alignment: .leading)
        .background(Palette.ground)
    }

    @ViewBuilder private func trailing(for light: HealthLight) -> some View {
        if let fix = light.fix {
            if case .retryItems = fix, models.retry.isRetrying, models.isWaitingForPassword {
                BusyLabel(text: PasswordCopy.waiting)
            } else if case .retryItems = fix, models.retry.isRetrying {
                BusyIndicator(label: "Retrying…")
            } else {
                Button(fix.title) { HealthFix.perform(fix, models: models) }
                    .buttonStyle(.link)
                    .fixedSize()
                    .disabled(isRetry(fix) && models.junk.isBusy)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
        } else {
            Text(light.state == .info ? "Not available yet" : light.state == .ok ? "OK" : "See Diagnostics")
                .font(DustlingTheme.Typography.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    private func isRetry(_ fix: FixAction) -> Bool {
        if case .retryItems = fix { return true }
        return false
    }

    /// The problem in one line (the mockup's caption under the rows), or that all is well.
    private var headline: String {
        if let fda = lights.first(where: { $0.kind == .fullDiskAccess }), fda.state == .warning {
            if models.accessMemory.isLost(models.health.fullDiskAccess) {
                return RepairCase.fullDiskAccessLostCopy(models.fullDiskAccessLoss ?? .unknown).title + "."
            }
            return "Full Disk Access is off, so some folders can't be scanned."
        }
        if let helper = lights.first(where: { $0.kind == .helper }), helper.state == .warning {
            return RepairCase.helperNotResponding.copy.title + "."
        }
        if let run = lights.first(where: { $0.kind == .lastRun }), run.state == .warning {
            if case .retryItems(let count) = run.fix { return RepairCase.itemsDidNotMove(count: count).copy.title + "." }
            return "The last run left problems."
        }
        return "Everything is working."
    }
}

/// The 24 pt round status mark from the mockups' `.hdot`: green with a check, amber with a warning,
/// neutral for "not available yet".
struct HealthDot: View {
    let state: HealthLight.State

    var body: some View {
        ZStack {
            Circle().fill(state.color)
            // The mockup draws a 12 pt glyph; pixel icons only come at integer scales, so 8 pt.
            PixelIconView(state.icon, color: .white, size: .small)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// What each fix link does. None of them fails silently: each says so when it can't work.
@MainActor
enum HealthFix {
    static func perform(_ fix: FixAction, models: AppModels) {
        switch fix {
        case .openFullDiskAccessSettings:
            openFullDiskAccessSettings()
        case .repairHelper:
            // Approval happens in Login Items & Extensions. Only reachable once the helper exists (Plan 2).
            SMAppService.openSystemSettingsLoginItems()
        case .retryItems(let count):
            guard let run = models.health.lastRun, !models.junk.isBusy else { return }
            // Same gate as a cleanup: in limited mode ask first (the model also refuses without it).
            let gate = models.retry.currentGate
            guard gate.kind == .confirmFirst else {
                Task { await models.retry.retry(run) }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Retry without Full Disk Access?"
            alert.informativeText = gate.note ?? ""
            alert.addButton(withTitle: RepairCase.itemsDidNotMove(count: count).copy.fix)
            alert.addButton(withTitle: "Cancel")
            // A sheet on the main window, so Quit can dismiss it (Cancel).
            ModalAlert.show(alert) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task { await models.retry.retry(run, confirmedLimited: true) }
            }
        }
    }
}

extension HealthLight.Kind {
    var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .helper: return "Cleanup helper"
        case .lastRun: return "Last run"
        }
    }
}

extension HealthLight.State {
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

extension FixAction {
    var title: String {
        switch self {
        case .openFullDiskAccessSettings: return "Open System Settings"
        case .repairHelper: return "Repair helper"
        case .retryItems(let count): return RepairCase.itemsDidNotMove(count: count).copy.fix
        }
    }
}
