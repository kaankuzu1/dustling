import Foundation

/// The arithmetic behind the loading skeletons (DESIGN-mosaic §8), kept here so it is tested.
public enum SkeletonMath {
    /// Fewest and most placeholder rows a list shows.
    public static let minRows = 3
    public static let maxRows = 24

    /// How many placeholder rows, `rowHeight` tall with `spacing` between them, fit in `height`
    /// (the list's visible height less its padding), so the skeleton fills the list without scrolling.
    /// Never fewer than `minRows` (a list that hasn't been measured yet still shows some) or more
    /// than `maxRows`.
    public static func rowCount(height: Double, rowHeight: Double, spacing: Double = 0) -> Int {
        guard height > 0, rowHeight > 0 else { return minRows }
        let rows = Int(((height + spacing) / (rowHeight + spacing)).rounded(.down))
        return min(maxRows, max(minRows, rows))
    }

    /// The pulse: opacity 1 → 0.45 → 1 once per `period` seconds (the mockup's `w-pulse`), on one
    /// clock for every block, each row `stagger` seconds behind the one above.
    public static func pulseOpacity(at time: TimeInterval, index: Int, period: Double, stagger: Double) -> Double {
        guard period > 0 else { return 1 }
        var phase = (time - Double(index) * stagger).truncatingRemainder(dividingBy: period) / period
        if phase < 0 { phase += 1 }
        return 1 - 0.55 * (1 - cos(phase * 2 * .pi)) / 2
    }
}
