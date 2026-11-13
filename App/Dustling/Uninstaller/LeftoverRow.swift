import DustlingAppModel
import DustlingCore
import SwiftUI

/// One leftover of the selected app (`leftItem()` in the approved mockups): checkbox, kind and badges,
/// the path in Geist Mono and the size. A checked data row gets the warning tint and the inline
/// "This is your data" text; excluded rows are disabled with the reason.
struct LeftoverRowView: View {
    let row: LeftoverRow
    let home: URL
    /// No ticking while an uninstall runs.
    let isLocked: Bool
    let onToggle: @MainActor (Bool) -> Void

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        LeftoverLine(
            title: UninstallerScreen.kindName(row.leftover.kind),
            path: UninstallerScreen.path(row.leftover.url, home: home),
            size: Bytes.format(row.leftover.bytes),
            warned: row.warning != nil
        ) {
            Toggle(isOn: Binding(get: { row.checked }, set: { value in onToggle(value) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                // Excluded ones never move. Items of the system move with the Mac password after the
                // last app, so the user can leave them out here too.
                .disabled(isLocked || row.isDisabled)
                .accessibilityLabel(UninstallerScreen.kindName(row.leftover.kind))
        } badges: {
            ForEach(Array(row.badges.enumerated()), id: \.offset) { _, badge in
                let shown = UninstallerScreen.badge(badge)
                Chip(text: shown.text, kind: chipKind(shown.style))
            }
        } detail: {
            if let warning = row.warning {
                DataWarningBlock(text: warning)
            } else if let note = UninstallerScreen.note(for: row) {
                Text(note)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                    .foregroundStyle(row.isDisabled ? Palette.warning : Palette.muted)
            }
        }
    }

    private func chipKind(_ style: UninstallerScreen.BadgeStyle) -> Chip.Kind {
        switch style {
        case .neutral: return .neutral
        case .warning: return .warning
        case .admin: return .admin
        }
    }
}

/// The row layout shared by leftovers, the app itself and the Removing list (`.litem`): a 20 pt status
/// column, the kind with badges over the path, then the size in a 76 pt column.
struct LeftoverLine<Status: View, Badges: View, Detail: View>: View {
    let title: String
    let path: String
    let size: String
    var warned = false
    @ViewBuilder var status: () -> Status
    @ViewBuilder var badges: () -> Badges
    @ViewBuilder var detail: () -> Detail

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            status()
                .skeletonBlock()
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .skeletonText()
                    badges()
                }
                .lineLimit(1)
                Text(path)
                    .font(DustlingTheme.Typography.path)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .skeletonText()
                detail()
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(size)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .skeletonText()
                .frame(width: 76, alignment: .trailing)
                .padding(.top, 2)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            warned ? Palette.warning.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// A leftover row's loading skeleton: `LeftoverLine` with placeholder text, in placeholder mode.
struct LeftoverLineSkeleton: View {
    let index: Int

    var body: some View {
        LeftoverLine(
            title: Placeholder.text(index, base: 11, spread: 8, step: 5),
            path: "~/" + Placeholder.text(index, base: 30, spread: 24, step: 11),
            size: "000 MB"
        ) { LeftoverCheckbox() } detail: { EmptyView() }
            .skeleton(true, index: index)
    }
}

/// A checkbox that only stands in for a leftover's, in the loading skeleton.
struct LeftoverCheckbox: View {
    var body: some View {
        Toggle(isOn: .constant(false)) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
    }
}

extension LeftoverLine where Badges == EmptyView {
    init(title: String, path: String, size: String, warned: Bool = false,
         @ViewBuilder status: @escaping () -> Status, @ViewBuilder detail: @escaping () -> Detail) {
        self.init(title: title, path: path, size: size, warned: warned, status: status, badges: { EmptyView() },
                  detail: detail)
    }
}

/// The warning block (`.dwarn`): warn icon, then the text with its first sentence in bold.
struct DataWarningBlock: View {
    let text: String
    /// Bold lead-in; by default the text's first sentence.
    var heading: String?

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let (bold, rest) = split
        HStack(alignment: .top, spacing: 8) {
            PixelIconView(.warn, color: Palette.warning)
            (Text(bold).fontWeight(.semibold).foregroundStyle(Palette.ink)
             + Text(rest.isEmpty ? "" : " " + rest).foregroundStyle(Palette.ink2))
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            let shape = RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
            shape.fill(Palette.ground)
                .overlay(shape.fill(Palette.warning.opacity(0.10)))
                .overlay(shape.strokeBorder(Palette.warning.opacity(0.35), lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
    }

    private var split: (String, String) {
        if let heading { return (heading, text) }
        guard let end = text.range(of: ". ") else { return (text, "") }
        return (String(text[..<end.lowerBound]) + ".", String(text[end.upperBound...]))
    }
}
