import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Empty Trash confirmation: the single permanent delete, always confirmed in a sheet with the
/// destructive style (Global Constraints). It shows the total in red, the largest items (at most 50,
/// then "…and N more"), and deletes only the size it showed.
///
/// If the Trash can't be read, the button is off with the reason; it never asks to delete 0 bytes.
struct EmptyTrashSheet: View {
    @Environment(AppModels.self) private var models
    @Environment(\.dismiss) private var dismiss
    @State private var refusal: String?

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let trash = models.trash
        let shown = trash.canEmpty ? trash.contents?.size.bytes : nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.ink2)
                    .accessibilityHidden(true)
                Text("Empty the Trash?")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let shown {
                Text(Bytes.format(shown))
                    .font(DustlingTheme.Typography.figure)
                    .foregroundStyle(Palette.danger)
                Text("Everything in the Trash is deleted for good. It can't be put back.")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                    .foregroundStyle(Palette.ink2)
                if trash.externalVolumesSkipped {
                    Text("Trash folders on other disks aren't included without Full Disk Access.")
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                        .foregroundStyle(Palette.muted)
                }
                ItemList(listing: TrashListing.make(trash.items), home: models.homeDirectory)
            }
            if let reason = refusal ?? trash.disabledReason {
                Text(reason)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Empty Trash", role: .destructive) { if let shown { empty(confirmed: shown) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.danger)
                    .disabled(shown == nil || trash.isEmptying)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Palette.ground)
        // Show what is in the Trash now, not what it held when the screen last looked.
        .task { models.refreshTrash() }
    }

    private func empty(confirmed: UInt64) {
        Task {
            // Deletes only if the Trash still holds exactly what this sheet showed.
            switch await models.trash.emptyTrash(confirmedBytes: confirmed) {
            case .emptied:
                dismiss()
            case .refused(let reason):
                refusal = reason
            }
        }
    }
}

/// The largest items in the Trash, biggest first.
private struct ItemList: View {
    let listing: TrashListing
    let home: URL

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        if !listing.rows.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(listing.rows) { row in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name)
                                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                                    .foregroundStyle(Palette.ink)
                                Text(JunkScreen.displayPath(row.url.deletingLastPathComponent(), home: home))
                                    .font(DustlingTheme.Typography.path)
                                    .foregroundStyle(Palette.muted)
                            }
                            .lineLimit(1)
                            .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(Bytes.format(row.bytes))
                                .font(DustlingTheme.Typography.size)
                                .foregroundStyle(Palette.ink)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .accessibilityElement(children: .combine)
                    }
                    if let more = listing.moreLine {
                        Text(more)
                            .font(DustlingTheme.Typography.caption)
                            .foregroundStyle(Palette.muted)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
        }
    }
}
