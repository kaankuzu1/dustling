import DustlingAppModel
import SwiftUI

/// The Settings window (SCREENS-final §7, the MIX "Settings" frame): sections in a 220 pt sidebar on
/// the left, and one scrolling page with every section on the right. The sidebar jumps to a section
/// and highlights the one you're in as you scroll.
struct SettingsWindow: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, scanning, exclusions, permissions, about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .scanning: return "Scanning"
            case .exclusions: return "Exclusions"
            case .permissions: return "Permissions and helper"
            case .about: return "About"
            }
        }

        @MainActor var icon: PixelIconView {
            let color = DustlingTheme.Palette.accent
            switch self {
            case .general: return PixelIconView(.gear, color: color)
            case .scanning: return PixelIconView(.broom, color: color)
            case .exclusions: return PixelIconView(.folder, color: color)
            case .permissions: return PixelIconView(.lock, color: color)
            case .about: return PixelIconView(.info, color: color)
            }
        }
    }

    @Environment(AppModels.self) private var models
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: Section = .general
    /// Set while a sidebar click scrolls, so the scroll position doesn't fight the highlight.
    @State private var jumping: Section?
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Section.allCases) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(section.title)
                                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.semibold))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.top, section == .general ? 0 : 12)
                                    .accessibilityAddTraits(.isHeader)
                                content(for: section)
                            }
                            .id(section)
                            .background(GeometryReader { geo in
                                Color.clear.preference(
                                    key: SectionOffsets.self,
                                    value: [section: geo.frame(in: .named(Self.space)).minY])
                            })
                        }
                    }
                    .padding(DustlingTheme.Metrics.gutter)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(SectionOffsets.self) { offsets in
                    guard jumping == nil else { return }
                    // The section whose top has passed the top quarter of the page is the current one.
                    let passed = Section.allCases.filter { (offsets[$0] ?? .infinity) <= 80 }
                    if let section = passed.last ?? Section.allCases.first, section != current { current = section }
                }
                .onChange(of: jumping) { _, target in
                    guard let target else { return }
                    current = target
                    if reduceMotion {
                        proxy.scrollTo(target, anchor: .top)
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 350))
                        jumping = nil
                    }
                }
            }
        }
        .frame(width: 880, height: 620)
        .background(Palette.ground)
        .font(DustlingTheme.Typography.body)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .onAppear {
            models.settings.refreshLoginItem()
            #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "DustlingSettingsSection"), let section = Section(rawValue: raw) {
                jumping = section
            }
            #endif
        }
    }

    private static let space = "settingsPage"

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { section in
                Button { jumping = section } label: {
                    HStack(spacing: 8) {
                        section.icon.frame(width: 18, height: 18)
                        Text(section.title)
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5).weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background {
                        RoundedRectangle(cornerRadius: DustlingTheme.Metrics.controlRadius, style: .continuous)
                            .fill(current == section ? Palette.rowSelection : .clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.line).frame(width: 1).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    @ViewBuilder private func content(for section: Section) -> some View {
        switch section {
        case .general: GeneralSection()
        case .scanning: ScanningSection()
        case .exclusions: ExclusionsSection()
        case .permissions: PermissionsSection()
        case .about: AboutSection()
        }
    }
}

private struct SectionOffsets: PreferenceKey {
    static let defaultValue: [SettingsWindow.Section: CGFloat] = [:]
    static func reduce(value: inout [SettingsWindow.Section: CGFloat], nextValue: () -> [SettingsWindow.Section: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A standard macOS switch, as in the mockups' `.w-sw`.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }
}
