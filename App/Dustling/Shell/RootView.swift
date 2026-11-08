import SwiftUI

/// The main window: the 236 pt sidebar and the selected screen (SCREENS-final, Shell).
struct RootView: View {
    @State private var selection: Destination = .home

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(DustlingTheme.Metrics.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
                .ignoresSafeArea()
        } detail: {
            DestinationView(destination: selection)
                .frame(minWidth: DustlingTheme.Metrics.contentMinWidth)
                // Only the title bar: on macOS 26 the leading safe area keeps content clear of the sidebar.
                .ignoresSafeArea(edges: .top)
        }
        .toolbar(removing: .sidebarToggle)
        .font(DustlingTheme.Typography.body)
        .foregroundStyle(DustlingTheme.Palette.ink)
        .tint(DustlingTheme.Palette.accent)
        .frame(
            minWidth: DustlingTheme.Metrics.sidebarWidth + DustlingTheme.Metrics.contentMinWidth,
            minHeight: 560)
    }
}

/// The screen for a destination. Every screen is a placeholder until its own task builds it
/// (Home: Task 11, Junk scan: 12, Uninstaller: 13, Startup items and History: 14).
struct DestinationView: View {
    let destination: Destination

    var body: some View {
        VStack(spacing: 0) {
            ScreenToolbar(title: destination.title, subtitle: destination.placeholderSubtitle)
            PlaceholderContent(destination: destination)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if destination.isToolScreen {
                ActionBar(title: "Nothing selected", caption: "This screen is built in a later step")
            }
        }
        .background(DustlingTheme.Palette.ground)
    }
}

private struct PlaceholderContent: View {
    let destination: Destination

    var body: some View {
        VStack(spacing: 10) {
            MoteView(.sleepy, pixel: 6)
            Text(destination.title)
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 17).weight(.semibold))
                .foregroundStyle(DustlingTheme.Palette.ink)
            Text("This screen is built in a later step.")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13))
                .foregroundStyle(DustlingTheme.Palette.muted)
        }
        .padding(24)
    }
}

private extension Destination {
    /// Tool screens end with the 60 pt action bar; Home doesn't.
    var isToolScreen: Bool { self != .home }

    var placeholderSubtitle: String {
        switch self {
        case .home: return "Free space and what Dustling can reclaim"
        case .junkScan: return "Caches, logs and other files apps rebuild"
        case .uninstaller: return "Apps and the files they leave behind"
        case .startupItems: return "What opens when you log in"
        case .history: return "Every run and what it moved"
        }
    }
}
