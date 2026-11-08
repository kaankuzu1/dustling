import SwiftUI

/// Mote, the mascot, with its six moods (DESIGN-mosaic §7).
///
/// The sprite is drawn with `Canvas` at an integer scale. Animations run on `TimelineView(.periodic)`
/// and stop under Reduce Motion or while the window isn't key; Mote then shows a still frame.
struct MoteView: View {
    enum Mood: Equatable {
        /// Default, still.
        case idle
        /// Scanning: walks left to right across the available width in 3.2 s, bobbing 3 pt every 0.3 s.
        case sniff
        /// Moving to the Trash: a 2 x 2 mouth toggles every 0.17 s.
        case chomp
        /// Done: caret eyes and a smile, hops in once (0.7 s).
        case happy
        /// Errors and repair: raised brows, flat mouth, sweat drop. Still.
        case worried
        /// Empty states: closed eyes, breathing (3.4 s), and "z z".
        case sleepy
    }

    let mood: Mood
    /// Points per sprite pixel. Always an integer: 2 (32 pt wide), 3 (48 pt) or 6 (96 pt).
    let pixel: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var appeared = Date.now
    @State private var hopFinished = false

    init(_ mood: Mood = .idle, pixel: Int = 2) {
        self.mood = mood
        self.pixel = max(1, pixel)
    }

    private var spriteSize: CGSize { CGSize(width: 16 * CGFloat(pixel), height: 15 * CGFloat(pixel)) }
    private var animates: Bool { !reduceMotion && controlActiveState == .key }

    var body: some View {
        // Decorative: Mote never carries information that isn't also in text next to it.
        content.accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch mood {
        case .idle: sprite(.idle)
        case .worried: sprite(.worried)
        case .chomp: chomp
        case .happy: happy.task { await finishHop() }
        case .sleepy: sleepy
        case .sniff: sniff
        }
    }

    private func sprite(_ face: Mote.Face) -> some View {
        PixelArt.mote(face, pixel: CGFloat(pixel))
    }

    // MARK: Chomp

    @ViewBuilder private var chomp: some View {
        if animates {
            TimelineView(.periodic(from: appeared, by: DustlingTheme.Motion.chompFrame)) { context in
                let frame = Int(context.date.timeIntervalSince(appeared) / DustlingTheme.Motion.chompFrame)
                sprite(frame.isMultiple(of: 2) ? .idle : .chompOpen)
            }
        } else {
            sprite(.idle)
        }
    }

    // MARK: Happy

    private static let hopDelay = 0.15
    private static let hopDuration = 0.7

    @ViewBuilder private var happy: some View {
        if animates && !hopFinished {
            TimelineView(.periodic(from: appeared, by: 1.0 / 60)) { context in
                let t = (context.date.timeIntervalSince(appeared) - Self.hopDelay) / Self.hopDuration
                let hop = Self.hop(at: t)
                sprite(.happy)
                    .scaleEffect(hop.scale, anchor: .bottom)
                    .offset(y: hop.offsetY)
                    .opacity(hop.opacity)
            }
        } else {
            sprite(.happy)
        }
    }

    /// The hop plays once; afterwards the timeline stops instead of ticking on a still frame.
    private func finishHop() async {
        try? await Task.sleep(for: .seconds(Self.hopDelay + Self.hopDuration))
        hopFinished = true
    }

    /// Mirrors the mockup's `w-hop` keyframes: from (10 pt down, 50%, hidden) through
    /// (6 pt up, 104%, visible) at 60% to rest, with a slight overshoot.
    private static func hop(at t: Double) -> (offsetY: CGFloat, scale: CGFloat, opacity: Double) {
        if t <= 0 { return (10, 0.5, 0) }
        if t >= 1 { return (0, 1, 1) }
        if t < 0.6 {
            let p = easeOut(t / 0.6)
            return (CGFloat(10 - 16 * p), CGFloat(0.5 + 0.54 * p), p)
        }
        let p = easeOut((t - 0.6) / 0.4)
        return (CGFloat(-6 + 6 * p), CGFloat(1.04 - 0.04 * p), 1)
    }

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    // MARK: Sleepy

    @ViewBuilder private var sleepy: some View {
        VStack(alignment: .center, spacing: -6) {
            Text("z z")
                .font(.custom(DustlingTheme.Typography.monoFamily, size: 13).weight(.semibold))
                .foregroundStyle(DustlingTheme.Palette.muted)
                .offset(x: CGFloat(pixel) * 6)
            if animates {
                TimelineView(.periodic(from: appeared, by: 1.0 / 30)) { context in
                    let phase = context.date.timeIntervalSince(appeared)
                        .truncatingRemainder(dividingBy: DustlingTheme.Motion.sleepyBreath) / DustlingTheme.Motion.sleepyBreath
                    // 0 → 1 → 0 over one breath, eased like the mockup's ease-in-out `w-breathe`.
                    let b = (1 - cos(phase * 2 * .pi)) / 2
                    sprite(.sleepy)
                        .scaleEffect(x: 1 + 0.04 * b, y: 1 - 0.05 * b, anchor: .bottom)
                }
            } else {
                sprite(.sleepy)
            }
        }
    }

    // MARK: Sniff

    private static let bobPeriod = 0.3

    private var sniff: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Group {
                if animates {
                    TimelineView(.periodic(from: appeared, by: 1.0 / 30)) { context in
                        let elapsed = context.date.timeIntervalSince(appeared)
                        let crossing = elapsed.truncatingRemainder(dividingBy: DustlingTheme.Motion.sniffCrossing)
                            / DustlingTheme.Motion.sniffCrossing
                        // Bob: up 3 pt and back, each half taking 0.3 s, in whole points.
                        let bobPhase = elapsed.truncatingRemainder(dividingBy: 2 * Self.bobPeriod) / (2 * Self.bobPeriod)
                        let bob = ((1 - cos(bobPhase * 2 * .pi)) / 2 * 3).rounded()
                        sprite(.idle)
                            .offset(x: (crossing * width - spriteSize.width).rounded(), y: -bob)
                    }
                } else {
                    // The mockup's still frame: the walk paused at 55% of the bar.
                    sprite(.idle)
                        .offset(x: (0.55 * width - spriteSize.width).rounded())
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .frame(height: spriteSize.height + 3)
        .clipped()
    }
}

#Preview("Moods") {
    HStack(spacing: 24) {
        MoteView(.idle, pixel: 3)
        MoteView(.chomp, pixel: 3)
        MoteView(.happy, pixel: 3)
        MoteView(.worried, pixel: 3)
        MoteView(.sleepy, pixel: 3)
    }
    .padding()
}
