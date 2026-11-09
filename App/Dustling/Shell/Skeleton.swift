import AppKit
import DustlingAppModel
import Observation
import SwiftUI

// Loading skeletons (DESIGN-mosaic §8): `panel`-coloured blocks in the shape of the rows that will
// appear, pulsing in opacity only (1.3 s), staggered 0.12 s per row, still under Reduce Motion.
//
// A skeleton is never drawn by hand. Each screen draws its real row view with placeholder data
// (`StartupRow.placeholder(_:)` and friends) inside `.skeleton(true, index:)`. In that mode the
// row's texts (`.skeletonText()`) and controls and icons (`.skeletonBlock()`) keep their exact size
// and place but show as blocks. The skeleton therefore has the row's container, padding, column
// widths and height by construction, and the loaded row replaces it without moving anything.

extension EnvironmentValues {
    /// Non-nil while views draw as their loading skeleton: the row's place, for the pulse's stagger.
    @Entry var skeletonIndex: Int?
    /// The skeleton sits on a `panel` surface (hero, tool cards), where `panel` blocks would vanish.
    @Entry var skeletonOnPanel = false
}

extension View {
    /// Draws this subtree as its loading skeleton while `active`; `index` staggers the pulse.
    func skeleton(_ active: Bool, index: Int = 0) -> some View {
        transformEnvironment(\.skeletonIndex) { if active { $0 = index } }
            .allowsHitTesting(!active)
            // The placeholder's controls are invisible but still there: keep them out of the Tab order.
            .disabled(active)
            .accessibilityHidden(active)
    }

    /// Like `skeleton(_:index:)`, and while active VoiceOver reads `accessibilityLabel` for the whole
    /// subtree (its placeholder content stays hidden), such as "Browser caches: scanning".
    func skeleton(_ active: Bool, index: Int = 0, accessibilityLabel: String) -> some View {
        transformEnvironment(\.skeletonIndex) { if active { $0 = index } }
            .allowsHitTesting(!active)
            .disabled(active)
            .modifier(SkeletonAccessibility(active: active, label: accessibilityLabel))
    }

    /// Marks a `panel`-filled container, so skeleton blocks inside it stay visible.
    func skeletonSurfaceIsPanel() -> some View {
        environment(\.skeletonOnPanel, true)
    }

    /// In a skeleton: one block the exact size of this view (a control, an icon, a meter).
    func skeletonBlock(cornerRadius: CGFloat = SkeletonMetrics.textRadius) -> some View {
        modifier(SkeletonBlockModifier(cornerRadius: cornerRadius))
    }

    /// In a skeleton: a line of text as a block as wide as the text and as tall as its glyphs,
    /// centred on the line, so the line keeps its exact height and baseline.
    func skeletonText() -> some View {
        modifier(SkeletonTextModifier())
    }
}

/// The skeleton's few metrics, in one place.
enum SkeletonMetrics {
    /// Corner radius of text lines and small controls (the mockups' `.sk`: 4 px).
    static let textRadius: CGFloat = 4
    /// A text block covers this share of its line's height: the glyphs, not the leading.
    static let textHeightRatio: CGFloat = 0.62
    /// How many placeholder rows fill `height` (see `SkeletonMath.rowCount`).
    static func rowCount(height: CGFloat, rowHeight: CGFloat, spacing: CGFloat = 0) -> Int {
        SkeletonMath.rowCount(height: Double(height), rowHeight: Double(rowHeight), spacing: Double(spacing))
    }
}

/// One element with `label` whose children are hidden, while `active`.
private struct SkeletonAccessibility: ViewModifier {
    let active: Bool
    let label: String

    func body(content: Content) -> some View {
        if active {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
        }
    }
}

// When loading ends the block fades out as the real content fades in, in place (0.25 s; at once under
// Reduce Motion). The content keeps its identity, so only opacity animates, never layout.

private struct SkeletonBlockModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.skeletonIndex) private var index
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let reveal = DustlingTheme.Motion.animation(DustlingTheme.Motion.reveal, reduceMotion: reduceMotion)
        content
            .animation(reveal) { $0.opacity(index == nil ? 1 : 0) }
            .overlay {
                ZStack {
                    if let index {
                        SkeletonBlock(cornerRadius: cornerRadius, index: index).transition(.opacity)
                    }
                }
                .animation(reveal, value: index == nil)
            }
    }
}

private struct SkeletonTextModifier: ViewModifier {
    @Environment(\.skeletonIndex) private var index
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let reveal = DustlingTheme.Motion.animation(DustlingTheme.Motion.reveal, reduceMotion: reduceMotion)
        content
            .animation(reveal) { $0.opacity(index == nil ? 1 : 0) }
            .overlay {
                ZStack {
                    if let index {
                        GeometryReader { proxy in
                            SkeletonBlock(
                                height: (proxy.size.height * SkeletonMetrics.textHeightRatio).rounded(),
                                cornerRadius: SkeletonMetrics.textRadius, index: index)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(reveal, value: index == nil)
            }
    }
}

/// One placeholder block. It fills the space it is given unless `width` or `height` is set. It pulses
/// in opacity only, on the shared `SkeletonClock`; under Reduce Motion or while the window isn't key
/// it stays still.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat?
    var cornerRadius: CGFloat = SkeletonMetrics.textRadius
    /// The row's place, used for the stagger.
    var index: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.skeletonOnPanel) private var onPanel

    private var pulses: Bool { !reduceMotion && controlActiveState == .key }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            // On a `panel` surface a `panel` block would vanish: one step darker, `line`.
            .fill(onPanel ? DustlingTheme.Palette.line : DustlingTheme.Palette.panel)
            .frame(width: width, height: height)
            // Reading the clock only while pulsing: a still block never redraws.
            .opacity(pulses ? opacity(at: SkeletonClock.shared.now) : 1)
            .onAppear { SkeletonClock.shared.subscribe() }
            .onDisappear { SkeletonClock.shared.unsubscribe() }
            .accessibilityHidden(true)
    }

    private func opacity(at time: TimeInterval) -> Double {
        SkeletonMath.pulseOpacity(
            at: time, index: index, period: DustlingTheme.Motion.skeletonPulse,
            stagger: DustlingTheme.Motion.skeletonStagger)
    }
}

/// The one clock every skeleton block pulses on: a single 30 Hz timer for the whole app instead of a
/// timeline per block. It runs only while a skeleton is on screen, Dustling is active, its key window
/// is visible (not covered or minimised) and the displays are awake.
@MainActor @Observable
final class SkeletonClock {
    static let shared = SkeletonClock()

    /// Seconds since the reference date, updated each tick.
    private(set) var now = Date.timeIntervalSinceReferenceDate

    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let app = NotificationCenter.default
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            observe(app, name) { _ in }
        }
    }

    func subscribe() {
        subscribers += 1
        update()
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        update()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (SkeletonClock) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.update()
            }
        }
        observers.append((center, token))
    }

    private var shouldRun: Bool {
        guard subscribers > 0, !screensAsleep, NSApp.isActive, let window = NSApp.keyWindow else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func update() {
        if shouldRun {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date.timeIntervalSinceReferenceDate }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Swaps a loading skeleton for the content it stands in for with a cross-fade (0.25 s; at once under
/// Reduce Motion). Both sit in one place while they fade, so nothing below moves.
struct LoadingSwap<Placeholder: View, Content: View>: View {
    let isLoading: Bool
    var alignment: Alignment = .topLeading
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: alignment) {
            if isLoading {
                placeholder().transition(.opacity)
            } else {
                content().transition(.opacity)
            }
        }
        .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.reveal, reduceMotion: reduceMotion), value: isLoading)
    }
}
