import AppKit
import SwiftUI

/// The main window's destinations (SCREENS-final, Shell). The sidebar lists `sidebarCases`; the
/// Diagnostics page (§8) is reached from the health lights and Settings, and highlights Settings.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case home, junkScan, uninstaller, startupItems, history, diagnostics

    var id: Self { self }

    static let sidebarCases: [Destination] = [.home, .junkScan, .uninstaller, .startupItems, .history]

    var title: String {
        switch self {
        case .home: return "Home"
        case .junkScan: return "Junk scan"
        case .uninstaller: return "Uninstaller"
        case .startupItems: return "Startup items"
        case .history: return "History"
        case .diagnostics: return "Dustling health"
        }
    }

    /// Icons as in the approved shell: home, broom, apps, power, clock.
    @MainActor func icon(color: Color) -> PixelIconView {
        switch self {
        case .home: return PixelIconView(.home, color: color)
        case .junkScan: return PixelIconView(.broom, color: color)
        case .uninstaller: return PixelIconView(PixelIcon.apps, color: color)
        case .startupItems: return PixelIconView(PixelIcon.power, color: color)
        case .history: return PixelIconView(.clock, color: color)
        case .diagnostics: return PixelIconView(.gear, color: color)
        }
    }
}

/// Sidebar colours the approved mockups use (`MOS` tokens in `screens.html`) that
/// `DustlingTheme.Palette` doesn't define. Kept here so the theme file stays verbatim.
enum SidebarTokens {
    /// The sidebar's right border and the footer's top rule (`sideLine`).
    static let line = DustlingTheme.dynamic(light: 0xE1E3E8, dark: 0x26272E)
    /// Text of the selected row (`sideSelInk`).
    static let selectedInk = DustlingTheme.dynamic(light: 0x0E1014, dark: 0xFFFFFF)
    /// The storage meter's track (`sideTrack`).
    static let meterTrack = DustlingTheme.dynamic(light: 0xDDE0E6, dark: 0x2B2D35)
}

/// The brand lockup, destinations and footer (SCREENS-final, Shell).
struct Sidebar: View {
    @Binding var selection: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            DestinationList(selection: $selection)
            SidebarFooter(selection: $selection)
        }
        // 46 pt clears the window's traffic lights, as in the mockup (14 + 2 + 12 + 18).
        .padding(EdgeInsets(top: 46, leading: 10, bottom: 14, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DustlingTheme.Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SidebarTokens.line).frame(width: 1).accessibilityHidden(true)
        }
        .foregroundStyle(DustlingTheme.Palette.sidebarInk)
    }
}

/// The app icon tile and the "Dustling" wordmark in Pixelify Sans SemiBold.
struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 9) {
            AppIconTile(size: 26)
            Text("Dustling")
                .font(DustlingTheme.Typography.lockup)
                .foregroundStyle(DustlingTheme.Palette.sidebarInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dustling")
    }
}

/// The app icon's squircle tile with Mote at an integer scale, as the mockups draw it in the sidebar.
struct AppIconTile: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let mascot = DustlingTheme.Mascot.self
        let top = colorScheme == .dark ? mascot.tileTopDark : mascot.tileTop
        let bottom = colorScheme == .dark ? mascot.tileBottomDark : mascot.tileBottom
        // The logo kit sizes Mote to about 66% of the tile; keep the nearest integer scale.
        let pixel = max(1, (size * 0.66 / 16).rounded())
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { PixelArt.mote(.idle, pixel: pixel) }
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// The destinations as a native `List(selection:)`, so arrow keys, type-select and VoiceOver's list
/// navigation work, drawn with the mockup's rows instead of the system highlight.
private struct DestinationList: View {
    @Binding var selection: Destination
    /// The rows draw their own selection, so the table's focus ring is gone too: while the list has
    /// keyboard focus, the selected row gets the system focus ring instead.
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: Binding<Destination?>(
            get: { selection == .diagnostics ? nil : selection },
            set: { if let new = $0 { selection = new } }
        )) {
            ForEach(Destination.sidebarCases) { destination in
                SidebarRow(
                    title: destination.title,
                    isSelected: selection == destination,
                    showsFocusRing: isFocused && selection == destination,
                    icon: { destination.icon(color: DustlingTheme.Palette.sidebarIcon) })
                    .tag(destination)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .background(PlainTableStyle())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        // The plain list still insets rows by 6 pt per side; the mockup's rows span the column.
        .padding(.horizontal, -6)
        .environment(\.defaultMinListRowHeight, 34)
        .focused($isFocused)
        .accessibilityLabel("Sections")
    }
}

/// The rows draw the mockup's selection fill, so the backing `NSTableView` drops its own highlight
/// and row padding. Selection itself (arrow keys, type-select, VoiceOver) is unchanged.
private struct PlainTableStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView else { return }
            table.selectionHighlightStyle = .none
            table.style = .fullWidth
            table.intercellSpacing = .zero
        }
    }
}

/// One 32 pt sidebar row: pixel icon, label, optional badge. Selection and hover fills follow the mockup.
struct SidebarRow<Icon: View>: View {
    let title: String
    var badge: String?
    var isSelected = false
    /// The keyboard focus ring around the row (the selected row while the list has focus).
    var showsFocusRing = false
    @ViewBuilder var icon: () -> Icon

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 9) {
            icon().frame(width: 18, height: 18)
            Text(title)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? SidebarTokens.selectedInk : Palette.sidebarInk)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 11.5))
                    .foregroundStyle(Palette.sidebarMuted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                .fill(Palette.sidebarSelection.opacity(isSelected ? 1 : isHovered ? 0.55 : 0))
        }
        .overlay {
            if showsFocusRing {
                RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5)
            }
        }
        .onHover { isHovered = $0 }
        .animation(DustlingTheme.Motion.animation(DustlingTheme.Motion.hover, reduceMotion: reduceMotion), value: isHovered)
        .accessibilityElement(children: .combine)
    }
}
