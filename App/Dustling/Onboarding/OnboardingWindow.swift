import AppKit
import DustlingAppModel
import DustlingCore
import Observation
import SwiftUI

extension OnboardingStep {
    /// The step list labels. "Cleanup helper" instead of "Helper and notifications": the notifications
    /// row is left out of v1 (Ruling R33), and O03 in the approved mockups labels this step so.
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .fullDiskAccess: return "Full Disk Access"
        case .permissions: return "Cleanup helper"
        case .ready: return "Ready"
        }
    }
}

extension OnboardingState {
    /// Opens the onboarding once per launch when it was never completed. In Debug builds,
    /// `-DustlingOnboardingStep N` (1 to 4) opens it at step N regardless, for screenshots, also only
    /// once per launch (the main window's task runs again each time the window reappears).
    func openAtLaunchIfNeeded(models: AppModels, openWindow: OpenWindowAction) {
        #if DEBUG
        let firstTime = !Self.debugLaunchHandled
        Self.debugLaunchHandled = true
        #endif
        let shouldOpen = takeLaunchRequest()
        #if DEBUG
        let forced = UserDefaults.standard.integer(forKey: "DustlingOnboardingStep")
        if let step = OnboardingStep(rawValue: forced - 1) {
            if firstTime { models.openOnboarding(at: step, using: openWindow) }
            return
        }
        #endif
        if shouldOpen {
            models.openOnboarding(at: .welcome, using: openWindow)
        }
    }
}

#if DEBUG
@MainActor private var debugOnboardingLaunchHandled = false

extension OnboardingState {
    fileprivate static var debugLaunchHandled: Bool {
        get { debugOnboardingLaunchHandled }
        set { debugOnboardingLaunchHandled = newValue }
    }
}
#endif

extension AppModels {
    /// Opens (or brings forward) the onboarding window at `step`. Used on first launch, by the
    /// limited-mode banner's "Grant access", and by Settings > Permissions and helper (Task 15).
    func openOnboarding(at step: OnboardingStep, using openWindow: OpenWindowAction) {
        onboarding.step = step
        openWindow(id: OnboardingWindow.id)
    }
}

/// The onboarding window: the step list on the left, the current step on the right (the Stepper frame,
/// `stepWin` in the approved mockups). Polls Full Disk Access while it is open.
struct OnboardingWindow: View {
    static let id = "onboarding"
    static let title = "Welcome to Dustling"

    @Environment(AppModels.self) private var models
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            StepList(
                current: models.onboarding.step,
                isDone: { models.onboarding.isDone($0, fullDiskAccessGranted: models.health.fullDiskAccess == .granted) }
            ) { models.onboarding.step = $0 }
                .frame(width: 270)
            // Centred vertically like the mockup; scrolls instead of clipping in a short window.
            GeometryReader { proxy in
                ScrollView {
                    StepContent(step: models.onboarding.step, finish: finish)
                        .padding(.vertical, 44)
                        .padding(.horizontal, 56)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(DustlingTheme.Palette.ground)
        .font(DustlingTheme.Typography.body)
        .foregroundStyle(DustlingTheme.Palette.ink)
        .onAppear { models.health.startPolling() }
        .onDisappear {
            // Closing the window any way (finished, skipped or the close button) ends polling and
            // leaves Dustling in limited mode if access is still off; Home says so in a banner.
            models.health.stopPolling()
            models.onboarding.windowClosed()
        }
        .task(id: models.fullDiskAccessKey) { await models.refreshPlaces() }
    }

    /// Closes the onboarding and shows the main window, optionally at a destination.
    private func finish(_ destination: Destination?) {
        models.onboarding.markCompleted()
        if let destination { models.selection = destination }
        dismissWindow(id: Self.id)
        openWindow(id: "main")
    }
}

/// The step on the right.
private struct StepContent: View {
    let step: OnboardingStep
    let finish: (Destination?) -> Void

    var body: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .fullDiskAccess: FullDiskAccessStep()
        case .permissions: PermissionsStep(skip: { finish(nil) })
        case .ready: ReadyStep(start: { finish(.junkScan) })
        }
    }
}

// MARK: - Step list

/// The left column: lockup, the four steps and the footer line.
private struct StepList: View {
    let current: OnboardingStep
    let isDone: (OnboardingStep) -> Bool
    let select: (OnboardingStep) -> Void
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppIconTile(size: 28)
                Text("Dustling")
                    .font(DustlingTheme.Typography.lockup)
                    .foregroundStyle(Palette.sidebarInk)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dustling")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(OnboardingStep.allCases) { step in
                    StepRow(step: step, current: current, isDone: step != current && isDone(step)) { select(step) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Steps")
            Text("You can skip any step and use limited mode. Dustling says what it can't see.")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.line).frame(width: 1).accessibilityHidden(true)
        }
    }
}

/// One step: a 20 pt dot (ring, accent ring when current, green with a check when done) and the label.
/// Only steps actually completed get the check; a skipped step keeps the plain ring.
private struct StepRow: View {
    let step: OnboardingStep
    let current: OnboardingStep
    let isDone: Bool
    let action: () -> Void
    private typealias Palette = DustlingTheme.Palette

    private var isCurrent: Bool { step == current }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isDone {
                        Circle().fill(Palette.success)
                        PixelIconView(.check, color: .white, size: .small)
                    } else {
                        Circle().strokeBorder(isCurrent ? Palette.accent : Palette.line, lineWidth: isCurrent ? 2 : 1.5)
                    }
                }
                .frame(width: 20, height: 20)
                Text(step.title)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.ink : isDone ? Palette.ink2 : Palette.muted)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                    .fill(isCurrent ? Palette.rowSelection : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title)
        .accessibilityValue(isDone ? "Done" : isCurrent ? "Current step" : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Shared pieces

/// Onboarding type: the big headline (Geist Pixel 30, or 22 for `.small`) and the caption.
enum OnboardingType {
    static func headline(small: Bool = false) -> Font {
        .custom(DustlingTheme.Typography.pixelFamily, size: small ? 22 : 30, relativeTo: .title)
    }

    static func caption(size: CGFloat = 12.5) -> Font {
        .custom(DustlingTheme.Typography.sansFamily, size: size)
    }
}

/// A headline and its caption, as in the mockups' `big-ttl` and `cap`.
struct StepHeadline: View {
    let title: String
    var caption: String?
    var small = true
    var captionSize: CGFloat = 12.5

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 4 : 16) {
            Text(title)
                .font(OnboardingType.headline(small: small))
                .foregroundStyle(DustlingTheme.Palette.ink)
                .lineSpacing(2)
                .accessibilityAddTraits(.isHeader)
                .skeletonText()
            if let caption {
                Text(caption)
                    .font(OnboardingType.caption(size: captionSize))
                    .foregroundStyle(DustlingTheme.Palette.muted)
                    .skeletonText()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension StepHeadline {
    /// The headline's loading skeleton while the places check runs: a headline and a one-line
    /// caption, in placeholder mode.
    static var placeholder: some View {
        StepHeadline(title: "Dustling can see 00 of 00 places", caption: Placeholder.text(0, base: 30, spread: 0))
            .skeleton(true, accessibilityLabel: "Checking which places Dustling can see")
    }
}

/// A `panel`-filled block with 10 pt corners and 14 x 16 pt padding (the mockups' `.pnl`).
struct OnboardingPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DustlingTheme.Palette.panel,
                        in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
    }
}

/// Opens Privacy & Security > Full Disk Access. If System Settings doesn't open, says so and how to
/// get there instead of failing silently.
@MainActor
func openFullDiskAccessSettings() {
    if !NSWorkspace.shared.open(FullDiskAccessProbe.settingsURL) {
        NSLog("Dustling: couldn't open System Settings at \(FullDiskAccessProbe.settingsURL)")
        let alert = NSAlert()
        alert.messageText = "System Settings didn't open"
        alert.informativeText = "Open System Settings yourself, then go to Privacy & Security > Full Disk Access and switch Dustling on."
        ModalAlert.show(alert)
    }
}

/// The primary "Open System Settings" button with the pixel arrow.
struct OpenSettingsButton: View {
    var primary = true

    var body: some View {
        let button = Button(action: openFullDiskAccessSettings) {
            HStack(spacing: 6) {
                PixelIconView(.arrow, tint: .foreground)
                Text("Open System Settings")
            }
        }
        .help("Opens Privacy & Security, Full Disk Access")
        if primary {
            button.dustlingPrimary()
        } else {
            button
        }
    }
}
