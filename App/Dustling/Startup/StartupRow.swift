import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// One startup item at the compact-list density (`suTable()` in the approved mockups): switch, icon,
/// name with badge, identifier in Geist Mono, kind, and the app it belongs to. Remove is secondary:
/// it lives in the row's context menu and always confirms.
struct StartupRowView: View {
    let row: StartupRow
    /// A change to this item is running: its switch becomes a spinner.
    let isBusy: Bool
    /// Another change is running: no switching meanwhile.
    let isLocked: Bool
    let canRemove: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    @Environment(AppModels.self) private var models
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 44, alignment: .leading)
            StartupIcon(row: row)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let badge = row.badge { BadgeChip(badge: badge) }
                }
                Text(row.item.label)
                    .font(.custom(DustlingTheme.Typography.monoFamily, size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.kindName)
                .frame(width: 130, alignment: .leading)
                .foregroundStyle(Palette.ink)
            Text(row.owner ?? "Not known")
                .frame(width: 170, alignment: .leading)
                .foregroundStyle(row.owner == nil ? Palette.muted : Palette.ink2)
                .lineLimit(1)
        }
        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .background(row.isOrphaned ? Palette.warning.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .help(row.item.plistURL.map { HistoryScreen.displayPath($0.path(percentEncoded: false), home: models.homePath) }
              ?? row.item.label)
        .contextMenu {
            Button("Remove…", action: onRemove)
                .disabled(!canRemove || isLocked)
            if let plist = row.item.plistURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([plist]) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if row.canToggle && !isLocked {
                Button(row.item.isEnabled ? "Turn off" : "Turn on", action: onToggle)
            }
            if canRemove && !isLocked {
                Button("Remove…", action: onRemove)
            }
        }
    }

    @ViewBuilder private var leading: some View {
        if isBusy {
            BusyIndicator(label: "Changing…")
        } else if row.showsSystemSettingsLink {
            Button {
                NSWorkspace.shared.open(StartupView.loginItemsSettings)
            } label: {
                PixelIconView(.arrow, color: Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Opens Login Items in System Settings")
            .accessibilityLabel("Open Login Items in System Settings")
        } else {
            Toggle(row.name, isOn: Binding(get: { row.item.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Palette.accentFill)
                .disabled(!row.canToggle || isLocked)
                .help(row.canToggle ? (row.item.isEnabled ? "Turn off" : "Turn on") : (row.badge?.help ?? ""))
        }
    }

    private var accessibilityText: String {
        var parts = [row.name, row.item.isEnabled ? "on" : "off", row.kindName]
        if let owner = row.owner { parts.append("belongs to \(owner)") }
        if let badge = row.badge { parts.append(badge.help) }
        return parts.joined(separator: ", ")
    }
}

/// The row's badge: "App not found" (warning), "In System Settings" (a link) or "Helper" (admin).
private struct BadgeChip: View {
    let badge: StartupScreen.Badge

    var body: some View {
        switch badge {
        case .appNotFound:
            Chip(text: badge.text, kind: .warning, icon: .warn).help(badge.help)
        case .inSystemSettings:
            Button {
                NSWorkspace.shared.open(StartupView.loginItemsSettings)
            } label: {
                Chip(text: badge.text)
            }
            .buttonStyle(.plain)
            .help(badge.help)
            .accessibilityLabel("\(badge.text). Open Login Items in System Settings")
        case .helper:
            Chip(text: badge.text, kind: .admin).help(badge.help)
        }
    }
}

/// The owning app's real icon at 24 pt, or a neutral tile with the power icon when the app is
/// unknown or gone.
private struct StartupIcon: View {
    let row: StartupRow
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                    .fill(DustlingTheme.Palette.panel)
                    .overlay {
                        PixelIconView(.power, color: row.isOrphaned ? DustlingTheme.Palette.warning : DustlingTheme.Palette.muted)
                    }
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .task(id: row.ownerAppURL) {
            image = row.ownerAppURL.map { AppIconView.icon(for: $0) }
        }
    }
}

/// Remove always confirms (SCREENS-final §5). It moves the item's file to the Trash, so the button is
/// the normal primary one; Empty Trash is the only destructive confirmation.
struct RemoveStartupItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModels.self) private var models
    let row: StartupRow
    let canTakeOutOfTrash: Bool
    let onConfirm: () -> Void

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let text = StartupScreen.removeConfirm(name: row.name, canTakeOutOfTrash: canTakeOutOfTrash)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MoteView(.idle, pixel: 2)
                Text(text.title)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 15).weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.plistURL.map {
                    HistoryScreen.displayPath($0.path(percentEncoded: false), home: models.homePath)
                } ?? row.item.label)
                    .font(DustlingTheme.Typography.path)
                    .foregroundStyle(Palette.ink2)
                    .textSelection(.enabled)
                Text("\(row.kindName), \(row.owner ?? "app not known")")
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
            Text(text.message)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let note = text.limitedNote {
                Text(note)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text.button) {
                    dismiss()
                    onConfirm()
                }
                .dustlingPrimary()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Palette.ground)
    }
}
