import DustlingAppModel
import DustlingCore
import SwiftUI

/// The cleanup summary (`summaryHead` in the mockups): happy Mote, the moved total counted up, the
/// item count with anything skipped or failed and why, the "Empty the Trash" sentence, and **Empty
/// Trash… N GB**, **Put everything back** and **View log**. Every figure comes from the run's
/// recorded outcomes.
struct SummaryView: View {
    let record: RunRecord
    @Binding var confirmingEmptyTrash: Bool

    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var restoreError: String?

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let summary = JunkSummary.make(record) { AppModels.appName(bundleID: $0) }
        HStack(alignment: .top, spacing: 18) {
            MoteView(models.junk.restoreOutcomes == nil ? .happy : .idle, pixel: 3)
            VStack(alignment: .leading, spacing: 8) {
                if let outcomes = models.junk.restoreOutcomes {
                    putBack(outcomes)
                } else {
                    moved(summary)
                }
                reasons(summary)
                if let restoreError {
                    Text(restoreError)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
    }

    // MARK: Headline

    private func moved(_ summary: JunkSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CountUpText(bytes: summary.movedBytes)
                    .font(DustlingTheme.Typography.figureLarge)
                    .foregroundStyle(Palette.success)
                Text("moved to the Trash")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.medium))
                    .foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)
            (Text(summary.sentence + " ").foregroundStyle(Palette.muted)
             + Text("Empty the Trash to free the space").fontWeight(.semibold).foregroundStyle(Palette.ink)
             + Text("; until then everything can go back.").foregroundStyle(Palette.muted))
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func putBack(_ outcomes: [RestoreOutcome]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(JunkSummary.restoreHeadline(outcomes))
                .font(DustlingTheme.Typography.figure)
                .foregroundStyle(Palette.ink)
            Text(JunkSummary.restoreLine(outcomes))
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Reasons

    /// One line per reason, with the first file it happened to (Errors name the file and the reason).
    @ViewBuilder private func reasons(_ summary: JunkSummary) -> some View {
        if !summary.reasons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(summary.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PixelIconView(.warn, color: Palette.warning, size: .small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.text)
                                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                                .foregroundStyle(Palette.ink2)
                            if let first = reason.paths.first {
                                Text(path(first) + (reason.paths.count > 1 ? " and \(reason.paths.count - 1) more" : ""))
                                    .font(DustlingTheme.Typography.path)
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func path(_ text: String) -> String {
        text.hasPrefix("/") ? JunkScreen.displayPath(URL(filePath: text), home: models.homeDirectory) : text
    }

    // MARK: Buttons

    private var buttons: some View {
        let trash = models.trash
        let junk = models.junk
        let size = trash.canEmpty && !trash.externalVolumesSkipped ? trash.contents?.size.bytes : nil
        return HStack(spacing: 8) {
            Button { confirmingEmptyTrash = true } label: {
                HStack(spacing: 6) {
                    PixelIconView(.trash, color: Palette.onAccent)
                    Text(size.map { "Empty Trash… \(Bytes.format($0))" } ?? "Empty Trash…")
                        .monospacedDigit()
                }
            }
            .dustlingPrimary()
            .disabled(!trash.canEmpty || trash.isEmptying || junk.isRestoring)
            .help(trash.disabledReason ?? "Shows what is in the Trash and asks before deleting it")

            switch junk.cleanupGate.undo {
            case .putEverythingBack:
                Button(action: putEverythingBack) {
                    HStack(spacing: 6) {
                        PixelIconView(.undo, color: Palette.ink)
                        Text(junk.isRestoring ? "Putting back…" : "Put everything back")
                    }
                }
                .disabled(!junk.canPutBack || junk.isRestoring)
            case .showInTrash:
                // Dustling can't take items out of the Trash without Full Disk Access; Finder can.
                Button("Show in Trash", action: models.showTrashInFinder)
                    .help("Opens the Trash in Finder, where you can drag items back")
            }

            Button("View log") { models.openLog(for: record) }
        }
    }

    private func putEverythingBack() {
        restoreError = nil
        Task {
            do {
                _ = try await models.junk.putEverythingBack()
            } catch {
                restoreError = "Couldn't put the items back: \(error.localizedDescription)"
            }
            // The model's run-completed hook re-reads the Trash, storage and the last-run light.
        }
    }
}

/// The moved total, counted up over 0.9 s with a cubic ease-out; shown at once under Reduce Motion.
struct CountUpText: View {
    let bytes: UInt64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || finished)) { context in
            let value = finished
                ? bytes : CountUp.value(bytes, elapsed: context.date.timeIntervalSince(start), reduceMotion: reduceMotion)
            Text(Bytes.format(value))
                .monospacedDigit()
        }
        .task(id: bytes) {
            start = .now
            finished = false
            try? await Task.sleep(for: .seconds(CountUp.duration))
            if !Task.isCancelled { finished = true }
        }
        .accessibilityLabel(Bytes.format(bytes))
    }
}
