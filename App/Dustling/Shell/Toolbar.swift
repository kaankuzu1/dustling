import AppKit
import SwiftUI

/// The 56 pt bar at the top of the content (SCREENS-final, Shell): the window title in Geist Pixel
/// 16 pt and a subtitle on the left, the screen's tools on the right.
struct ScreenToolbar<Tools: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var tools: () -> Tools

    private typealias Palette = DustlingTheme.Palette

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DustlingTheme.Typography.windowTitle)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.custom(DustlingTheme.Typography.sansFamily, size: 12))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            HStack(spacing: 8) { tools() }
        }
        .padding(.horizontal, DustlingTheme.Metrics.gutter)
        .frame(height: DustlingTheme.Metrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Hairline() }
        .windowDragArea()
    }
}

extension View {
    /// Lets the whole area drag the window, like a title bar. Controls inside keep their clicks.
    /// macOS 15 and later use `WindowDragGesture`; macOS 14 falls back to an AppKit view behind
    /// the content that calls `performDrag(with:)` (it covers the bar's empty space).
    @ViewBuilder func windowDragArea() -> some View {
        if #available(macOS 15.0, *) {
            gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            background(WindowDragView())
        }
    }
}

/// macOS 14 fallback for `windowDragArea()`: drags the window, and a double-click does what the
/// user chose for title bars in System Settings (zoom or minimise).
private struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return super.mouseDown(with: event) }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

extension ScreenToolbar where Tools == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
