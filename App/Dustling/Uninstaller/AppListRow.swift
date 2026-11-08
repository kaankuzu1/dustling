import AppKit
import DustlingAppModel
import DustlingCore
import SwiftUI

/// One app in the left pane (`aRow()` in the approved mockups): checkbox, icon, name and caption, the
/// total with leftovers and when it was last used. While removing, the checkbox becomes a spinner or a
/// check.
struct AppListRow: View {
    let row: AppRow
    let isCurrent: Bool
    let isSelected: Bool
    /// The app's place in a running or finished uninstall, if it is part of one.
    let progress: UninstallProgress.AppState?
    /// No ticking while an uninstall runs.
    let isLocked: Bool
    let onToggle: @MainActor (Bool) -> Void
    let onSelect: () -> Void

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 20)
            AppIconView(app: row.app, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.app.displayName)
                    .font(DustlingTheme.Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text(UninstallerScreen.appCaption(row))
                    .font(DustlingTheme.Typography.caption)
                    .foregroundStyle(isCurrent ? Palette.ink2 : Palette.muted)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Bytes.format(row.totalBytes))
                    .font(DustlingTheme.Typography.size)
                    .foregroundStyle(row.isCounting ? Palette.muted : Palette.ink)
                if let used = UninstallerScreen.lastUsed(row.app.lastUsed, now: .now) {
                    Text(used)
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(isCurrent ? Palette.ink2 : Palette.muted)
                }
            }
            .lineLimit(1)
            .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .frame(minHeight: 54)
        .background(
            isCurrent ? Palette.rowSelection : Color.clear,
            in: RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.app.displayName)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Show details", onSelect)
    }

    @ViewBuilder private var leading: some View {
        switch progress {
        case .finished(removed: true):
            CheckMark()
        case .finished(removed: false):
            PixelIconView(.warn, color: Palette.warning)
                .accessibilityLabel("Left alone")
        case .quitting:
            BusyIndicator(label: "Quitting…")
        case .removing:
            BusyIndicator(label: "Moving…")
        case .waiting:
            Toggle(isOn: .constant(true)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
        case .stopped:
            // Stop left it alone: nothing of it moves any more.
            Toggle(isOn: .constant(false)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
                .help("Left alone")
                .accessibilityLabel("Left alone")
        case nil:
            Toggle(isOn: Binding(get: { isSelected }, set: { value in onToggle(value) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isLocked)
                .accessibilityLabel("Remove \(row.app.displayName)")
        }
    }
}

/// The real app icon from `NSWorkspace` (DESIGN-mosaic §6), or the generic app icon when the bundle
/// isn't there.
struct AppIconView: View {
    let app: InstalledApp
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: app.url) { image = AppIconView.icon(for: app.url) }
    }

    @MainActor static func icon(for url: URL) -> NSImage {
        #if DEBUG
        // The screenshot fixture's apps are samples: draw a generic tile, never a real app's icon.
        if usesFixtureIcons { return fixtureIcon(name: url.deletingPathExtension().lastPathComponent) }
        #endif
        let path = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    #if DEBUG
    /// Set by the Uninstaller screenshot fixture.
    @MainActor static var usesFixtureIcons = false

    /// A rounded tile in a colour picked from the name, with its first letter.
    @MainActor static func fixtureIcon(name: String) -> NSImage {
        let palette: [NSColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemBlue, .systemPurple]
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            let tile = rect.insetBy(dx: 5, dy: 5)
            palette[index].setFill()
            NSBezierPath(roundedRect: tile, xRadius: 13, yRadius: 13).fill()
            let letter = String(name.prefix(1)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.white,
            ]
            let textSize = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: tile.midX - textSize.width / 2, y: tile.midY - textSize.height / 2),
                        withAttributes: attributes)
            return true
        }
    }
    #endif
}
