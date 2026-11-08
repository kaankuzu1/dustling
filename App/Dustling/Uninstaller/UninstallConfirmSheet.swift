import DustlingAppModel
import DustlingCore
import SwiftUI

/// "Move 3 apps to the Trash?" (`confirmSheet()` in the approved mockups): one row per app with its
/// item count and size, a separate block for checked data items, notes on running apps, launch agents
/// and helper-only items, the total, Cancel, and the primary "Quit <app> and move to Trash".
///
/// It shows the snapshot it was opened with, and the uninstall runs exactly that snapshot.
struct UninstallConfirmSheet: View {
    let confirm: ConfirmModel
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let text = ConfirmText.make(confirm)
        let layout = SheetLayout.uninstallConfirm
        VStack(alignment: .leading, spacing: CGFloat(layout.spacing)) {
            // Pinned: the header and the buttons. Everything between scrolls (`SheetMiddle`).
            HStack(alignment: .center, spacing: 12) {
                // The mockup's 36 pt Mote at the nearest integer scale.
                MoteView(.idle, pixel: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.title)
                        .font(.custom(DustlingTheme.Typography.pixelFamily, size: 22))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityAddTraits(.isHeader)
                    Text(text.message)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
            }
            .frame(maxHeight: CGFloat(layout.headerHeight))
            SheetMiddle(layout: layout, spacing: 12) {
                VStack(spacing: 4) {
                    ForEach(Array(zip(confirm.plan, text.apps).enumerated()), id: \.offset) { _, pair in
                        appRow(pair.0.app, pair.1)
                    }
                }
                if let heading = text.dataHeading {
                    DataWarningBlock(text: text.dataLines.joined(separator: " "), heading: heading)
                }
                if let limited = text.limitedNote {
                    DataWarningBlock(text: limited)
                }
                if !text.notes.isEmpty {
                    InfoNote(text: text.notes.joined(separator: " "))
                }
            }
            HStack(spacing: 8) {
                (Text("Total ").foregroundStyle(Palette.muted)
                 + Text(text.total).fontWeight(.semibold).foregroundStyle(Palette.ink))
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text.button) {
                    dismiss()
                    onConfirm()
                }
                .fixedSize()
                .dustlingPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!confirm.ready)
            }
            .frame(height: CGFloat(SheetLayout.buttonRowHeight))
        }
        .padding(.vertical, CGFloat(layout.verticalPadding))
        .padding(.horizontal, 22)
        .frame(width: 560)
        .background(Palette.ground)
    }

    private func appRow(_ app: InstalledApp, _ line: ConfirmText.AppLine) -> some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 24)
            Text(line.name)
                .font(DustlingTheme.Typography.rowTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text(line.items)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(line.bytes)
                .font(DustlingTheme.Typography.size)
                .foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The mockup's `.banner.info` with plain text: info icon and one or two sentences.
private struct InfoNote: View {
    let text: String

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PixelIconView(.info, color: Palette.accent)
            Text(text)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background {
            let shape = RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous)
            shape.fill(Palette.ground)
                .overlay(shape.fill(Palette.accent.opacity(0.07)))
                .overlay(shape.strokeBorder(Palette.accent.opacity(0.28), lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
    }
}
