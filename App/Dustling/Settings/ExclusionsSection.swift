import AppKit
import DustlingAppModel
import SwiftUI
import UniformTypeIdentifiers

/// Exclusions (SCREENS-final §7, P05 layout): folders Dustling never scans or moves, with Add and
/// Remove, and the always-protected folders as locked chips. The list is `ScanOptions.exclusions`, and
/// the protected paths every move goes through follow it right away.
struct ExclusionsSection: View {
    @Environment(AppModels.self) private var models
    @State private var note: String?
    @State private var isTargeted = false
    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        let settings = models.settings
        VStack(alignment: .leading, spacing: 12) {
            SettingsForm {
                ForEach(settings.exclusionRows) { row in
                    HStack(spacing: 8) {
                        PixelIconView(.folder, color: Palette.muted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.display)
                                .font(.custom(DustlingTheme.Typography.monoFamily, size: 12.5))
                                .foregroundStyle(row.problem == nil ? Palette.ink : Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let problem = row.problem {
                                Text(problem)
                                    .font(DustlingTheme.Typography.caption)
                                    .foregroundStyle(Palette.warning)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove") {
                            note = nil
                            settings.removeExclusion(row)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Remove \(row.display)")
                    }
                    .padding(.vertical, 11)
                    .frame(minHeight: 46)
                }
                HStack(spacing: 14) {
                    Text(settings.exclusionRows.isEmpty
                         ? "No folders excluded. Drop a folder here or"
                         : "Drop a folder here or")
                        .font(DustlingTheme.Typography.caption)
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Add folder…", action: pickFolder)
                        .dustlingPrimary()
                        .controlSize(.small)
                }
                .padding(.vertical, 11)
                .frame(minHeight: 46)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: DustlingTheme.Metrics.panelRadius, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 2)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                add(urls.filter(\.hasDirectoryPath))
                return true
            } isTargeted: { isTargeted = $0 }
            if let note {
                Text(note)
                    .font(.custom(DustlingTheme.Typography.sansFamily, size: 12.5))
                    .foregroundStyle(Palette.ink2)
            }
            Text("Always protected")
                .font(.custom(DustlingTheme.Typography.sansFamily, size: 13).weight(.semibold))
                .foregroundStyle(Palette.ink)
            ChipFlow(spacing: 6) {
                ForEach(AppSettings.alwaysProtected, id: \.self) { name in
                    HStack(spacing: 6) {
                        PixelIconView(.lock, color: Palette.ink2, size: .small)
                        Text(name)
                            .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Palette.panel, in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(name), always protected")
                }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Choose folders Dustling should never scan or move."
        // A sheet on the Settings window, so Quit can dismiss it.
        ModalAlert.show(panel) { response in
            guard response == .OK else { return }
            add(panel.urls)
        }
    }

    private func add(_ urls: [URL]) {
        let notes = urls.compactMap { models.settings.addExclusion($0) }
        note = notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

/// Lays chips out left to right and wraps them onto new lines.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
