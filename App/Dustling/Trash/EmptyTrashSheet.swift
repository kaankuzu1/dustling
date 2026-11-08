import DustlingAppModel
import DustlingCore
import SwiftUI

/// The Empty Trash confirmation: the single permanent delete, always confirmed in a sheet with the
/// destructive style (Global Constraints). Task 12 adds the list of the largest items.
///
/// The size is shown before anything is deleted. If the Trash can't be read, the button is off with
/// the reason; it never asks to delete 0 bytes.
struct EmptyTrashSheet: View {
    @Environment(AppModels.self) private var models
    @Environment(\.dismiss) private var dismiss
    @State private var refusal: String?

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let trash = models.trash
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.ink2)
                    .accessibilityHidden(true)
                Text("Empty the Trash?")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }
            if let bytes = trash.contents?.size.bytes, trash.canEmpty {
                Text(Bytes.format(bytes))
                    .font(DustlingTheme.Typography.figure)
                    .foregroundStyle(Palette.danger)
                Text("Everything in the Trash is deleted for good. It can't be put back.")
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                    .foregroundStyle(Palette.ink2)
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
                Button("Empty Trash", role: .destructive, action: empty)
                    .disabled(!trash.canEmpty || trash.isEmptying)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Palette.ground)
    }

    private func empty() {
        Task {
            switch await models.trash.emptyTrash() {
            case .emptied:
                dismiss()
            case .refused(let reason):
                refusal = reason
            }
        }
    }
}
