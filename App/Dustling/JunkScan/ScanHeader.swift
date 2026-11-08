import DustlingAppModel
import DustlingCore
import SwiftUI

/// The scanning header (`scanHead` in the mockups): the live "found so far" counter, the path being
/// checked and how many places are done, **Stop**, Mote sniffing along the track, and the scan bar.
struct ScanHeader: View {
    /// nil before the first scan starts.
    let progress: ScanProgress?

    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    (Text(Bytes.format(progress?.bytesFound ?? 0)).font(DustlingTheme.Typography.figure)
                     + Text(" found so far").font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.medium))
                        .foregroundStyle(Palette.muted))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(progress.map { JunkScreen.scanLine($0, home: models.homeDirectory) } ?? "Waiting to start")
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                if progress != nil {
                    Button("Stop", action: models.junk.stop)
                        .controlSize(.small)
                }
            }
            // Mote walks the track while scanning (a still frame under Reduce Motion).
            MoteView(progress == nil ? .idle : .sniff, pixel: 2)
                .frame(height: 34, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScanBar(fraction: fraction)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var fraction: Double {
        guard let progress, progress.categoriesTotal > 0 else { return 0 }
        return Double(progress.categoriesDone) / Double(progress.categoriesTotal)
    }
}

/// A 4 pt bar in `accent` over `ground`, filled to the share of places done.
private struct ScanBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DustlingTheme.Palette.ground)
                Capsule()
                    .fill(DustlingTheme.Palette.accent)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.meter, reduceMotion: reduceMotion), value: fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
