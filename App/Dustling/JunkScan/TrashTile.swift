import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Trash as its own tile at the end of **Review first** (`trashTile` in the mockups): the system
/// trash icon, its size, "Already in the Trash. Emptying it frees the space" and **Empty Trash…**.
/// It is never part of a clean, uses neutral colours, and always confirms first.
struct TrashTile: View {
    @Binding var confirmingEmptyTrash: Bool

    @Environment(AppModels.self) private var models

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let trash = models.trash
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("Trash")
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
            }
            size(trash)
            Text(note(trash))
                .font(DustlingTheme.Typography.caption)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Empty Trash…") { confirmingEmptyTrash = true }
                .controlSize(.small)
                .disabled(!trash.canEmpty || trash.isEmptying || models.junk.isRestoring)
                .help(trash.disabledReason ?? "Shows what is in the Trash and asks before deleting it")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func size(_ trash: TrashModel) -> some View {
        if let contents = trash.contents, contents.issues.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Bytes.format(contents.size.bytes))
                    .font(.custom(DustlingTheme.Typography.pixelFamily, size: 18))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                if trash.sizeIsLowerBound {
                    Text("or more")
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(Palette.muted)
                }
            }
        } else {
            // Unread or unreadable: never 0 bytes.
            Text("Size unknown")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                .foregroundStyle(Palette.muted)
                .frame(height: 22, alignment: .leading)
        }
    }

    private func note(_ trash: TrashModel) -> String {
        if let contents = trash.contents, !contents.issues.isEmpty, let reason = trash.disabledReason {
            return reason
        }
        return "Already in the Trash. Emptying it frees the space"
    }
}
