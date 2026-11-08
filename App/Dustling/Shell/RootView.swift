import SwiftUI

/// The main window: the 236 pt sidebar and the selected screen (SCREENS-final, Shell).
struct RootView: View {
    @Environment(AppModels.self) private var models
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var models = models
        NavigationSplitView {
            Sidebar(selection: $models.selection)
                .navigationSplitViewColumnWidth(DustlingTheme.Metrics.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
                .ignoresSafeArea()
        } detail: {
            DestinationView(destination: models.selection)
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
        // Full Disk Access changed (polling, activation): re-check which places are locked.
        .task(id: models.health.fullDiskAccess) { await models.refreshPlaces() }
        .task { models.onboarding.openAtLaunchIfNeeded(models: models, openWindow: openWindow) }
    }
}

/// The screen for a destination. Every screen is a placeholder until its own task builds it
/// (Home: Task 11, Junk scan: 12, Uninstaller: 13, Startup items and History: 14).
struct DestinationView: View {
    let destination: Destination

    @Environment(AppModels.self) private var models

    var body: some View {
        VStack(spacing: 0) {
            ScreenToolbar(title: destination.title, subtitle: subtitle)
            if destination == .home, LimitedModeBanner.isShown(models) {
                LimitedModeBanner()
                    .padding(.horizontal, DustlingTheme.Metrics.gutter)
                    .padding(.top, 16)
            }
            PlaceholderContent(destination: destination)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if destination.isToolScreen {
                ActionBar(title: "Nothing selected", caption: "This screen is built in a later step.")
            }
        }
        .background(DustlingTheme.Palette.ground)
    }

    private var subtitle: String {
        if destination == .home, LimitedModeBanner.isShown(models) {
            return LimitedModeBanner.subtitle(lockedCount: models.places.lockedPlaces.count)
        }
        return destination.placeholderSubtitle
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
