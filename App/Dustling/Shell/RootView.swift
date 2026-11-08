import SwiftUI

/// The main window: the 236 pt sidebar and the selected screen (SCREENS-final, Shell).
struct RootView: View {
    @Environment(AppModels.self) private var models
    @Environment(\.openWindow) private var openWindow
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

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
        .task(id: models.fullDiskAccessKey) { await models.refreshPlaces() }
        .task { models.onboarding.openAtLaunchIfNeeded(models: models, openWindow: openWindow) }
        #if DEBUG
        // QA: `-DustlingSettingsSection about` also opens the Settings window at launch, at that section.
        .task { if UserDefaults.standard.string(forKey: "DustlingSettingsSection") != nil { openSettings() } }
        #endif
        // Only for blockers, such as Full Disk Access lost before a scan (SCREENS-final §8).
        .dismissedOnQuit($models.blocker)
        .sheet(isPresented: Binding(get: { models.blocker != nil }, set: { if !$0 { models.blocker = nil } })) {
            if let blocker = models.blocker { BlockerSheet(repair: blocker) }
        }
    }
}

/// The screen for a destination. Every destination is built; the placeholder stays for safety.
struct DestinationView: View {
    let destination: Destination

    var body: some View {
        if destination == .home {
            HomeView()
        } else if destination == .junkScan {
            JunkScanView()
        } else if destination == .uninstaller {
            UninstallerView()
        } else if destination == .startupItems {
            StartupView()
        } else if destination == .history {
            HistoryView()
        } else if destination == .diagnostics {
            DiagnosticsView()
        } else {
            VStack(spacing: 0) {
                ScreenToolbar(title: destination.title, subtitle: destination.placeholderSubtitle)
                PlaceholderContent(destination: destination)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ActionBar(title: "Nothing selected", caption: "This screen is built in a later step.")
            }
            .background(DustlingTheme.Palette.ground)
        }
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
    var placeholderSubtitle: String {
        switch self {
        case .home: return "Free space and what Dustling can reclaim"
        case .junkScan: return "Caches, logs and other files apps rebuild"
        case .uninstaller: return "Apps and the files they leave behind"
        case .startupItems: return "What opens when you log in"
        case .history: return "Every run and what it moved"
        case .diagnostics: return "Every check and its last result"
        }
    }
}
