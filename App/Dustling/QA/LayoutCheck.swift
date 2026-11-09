#if DEBUG
import AppKit
import ApplicationServices
import SwiftUI

/// DEBUG only. `-DustlingLayoutCheck <folder>` checks the open windows at several sizes, then quits:
/// - the main window is resized to each of `LayoutCheck.sizes` (its smallest size first);
/// - every window and sheet is saved as `<size>-<window>.png` in the folder, for a person to look at,
///   with what VoiceOver can reach in it as `<size>-<window>.txt`;
/// - every control is checked: it has a name VoiceOver can read, and it isn't cut off by the edge of
///   its window or sheet (in a scroll view, scrolling reaches them, so there the scroll view itself
///   must fit instead).
///
/// Problems go to `report.txt`, and the exit status is 1 if there are any. Combine it with a fixture
/// (`-DustlingUninstallerFixture confirm-all`, ...) to check that state; `scripts/qa-screens.sh` runs
/// every state. It reads the app's own accessibility tree, which needs no permissions.
@MainActor enum LayoutCheck {
    static let argument = "DustlingLayoutCheck"

    /// The smallest window, the default, and a large one.
    static let sizes: [CGSize] = [
        RootView.minimumSize,
        DustlingTheme.Metrics.defaultWindow,
        CGSize(width: 1680, height: 1050),
    ]

    private static var started = false

    static func runIfRequested() {
        guard !started, let path = UserDefaults.standard.string(forKey: argument) else { return }
        started = true
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Let the fixture, the first layout and any sheet settle.
            try? await Task.sleep(for: .seconds(3))
            var problems: [String] = []
            for size in sizes {
                guard let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else {
                    problems.append("No main window")
                    break
                }
                main.setContentSize(size)
                try? await Task.sleep(for: .seconds(1.5))
                let tag = "\(Int(size.width))x\(Int(size.height))"
                for window in NSApp.windows where window.isVisible && window.contentView != nil {
                    save(window, to: folder.appending(path: "\(tag)-\(fileName(window)).png"))
                }
                for window in AccessibilityTree.windows() {
                    let result = AccessibilityTree.audit(window)
                    let name = AccessibilityTree.name(of: window)
                    problems += result.problems.map { "\(tag) \(name): \($0)" }
                    try? result.tree.write(
                        to: folder.appending(path: "\(tag)-\(name).txt"), atomically: true, encoding: .utf8)
                }
            }
            let report = problems.isEmpty ? "No problems found.\n" : problems.joined(separator: "\n") + "\n"
            try? report.write(to: folder.appending(path: "report.txt"), atomically: true, encoding: .utf8)
            exit(problems.isEmpty ? 0 : 1)
        }
    }

    private static func fileName(_ window: NSWindow) -> String {
        if window.sheetParent != nil { return "sheet" }
        if let id = window.identifier?.rawValue, !id.isEmpty, !id.contains(" ") { return id }
        return window.title.isEmpty ? "window\(window.windowNumber)" : window.title.replacingOccurrences(of: " ", with: "-")
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The app's own accessibility tree, read the way VoiceOver reads it: through the accessibility API,
/// which makes SwiftUI build its tree (asking the views directly returns nothing).
@MainActor enum AccessibilityTree {
    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXTextFieldRole, kAXSliderRole, kAXIncrementorRole, kAXComboBoxRole, kAXDisclosureTriangleRole,
        "AXLink", "AXSearchField",
    ]
    /// The title bar's buttons and scroll bar parts aren't Dustling's.
    private static let systemSubroles: Set<String> = [
        kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole,
        kAXToolbarButtonSubrole, kAXIncrementArrowSubrole, kAXDecrementArrowSubrole, kAXIncrementPageSubrole,
        kAXDecrementPageSubrole,
    ]
    /// Containers that clip what's inside them; scrolling reaches the rest.
    private static let scrollingRoles: Set<String> = [kAXScrollAreaRole, kAXOutlineRole, kAXTableRole, kAXListRole]

    static func windows() -> [AXUIElement] {
        let app = AXUIElementCreateApplication(getpid())
        return (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func name(of window: AXUIElement) -> String {
        if let id = string(window, "AXIdentifier"), !id.contains(" ") { return id }
        let title = string(window, kAXTitleAttribute) ?? "window"
        return title.replacingOccurrences(of: " ", with: "-")
    }

    /// Problems with the controls in `window` and its sheets, and the tree as text, one element per line.
    static func audit(_ window: AXUIElement) -> (problems: [String], tree: String) {
        var problems: [String] = []
        var tree: [String] = []
        func visit(_ element: AXUIElement, clip: CGRect, depth: Int, sheet: Bool, scrolled: Bool) {
            let role = string(element, kAXRoleAttribute) ?? "?"
            let subrole = string(element, kAXSubroleAttribute)
            let frame = frame(of: element)
            let name = label(of: element)
            let value = string(element, kAXValueAttribute).map { " = \($0)" } ?? ""
            tree.append(String(repeating: "  ", count: depth) + "\(role) \"\(name ?? "")\"\(value) \(describe(frame))")

            var childClip = clip
            var inSheet = sheet
            var inScroll = scrolled
            if role == kAXSheetRole {
                childClip = frame
                inSheet = true
                inScroll = false
            } else if scrollingRoles.contains(role) {
                inScroll = true
            }
            let isControl = controlRoles.contains(role) && !(subrole.map(systemSubroles.contains) ?? false)
            let place = "\(inSheet ? "sheet " : "")\(role.dropFirst(2)) \"\(name ?? "?")\""
            if isControl, name == nil, frame.width > 1, frame.height > 1 {
                problems.append("\(place) has no name for VoiceOver")
            }
            // Controls outside scroll views, and the scroll views themselves, must fit their window or sheet.
            if (isControl && !scrolled) || (role == kAXScrollAreaRole && !scrolled), isFinite(frame),
               frame.width > 1, frame.height > 1 {
                // Half a point of slack for rounding.
                if !clip.insetBy(dx: -0.5, dy: -0.5).contains(frame) {
                    problems.append(clip.intersects(frame)
                        ? "\(place) is cut off: \(describe(frame)) reaches past \(describe(clip))"
                        : "\(place) can't be seen: \(describe(frame)) is outside \(describe(clip))")
                }
            }
            // An element that stands for the app itself (some menus and popovers point back to it) is
            // not walked again: asking the app for its children here made AppKit list every window on
            // the system and run out of stack.
            guard role != kAXApplicationRole, depth < 80 else { return }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                visit(child, clip: childClip, depth: depth + 1, sheet: inSheet, scrolled: inScroll)
            }
        }
        visit(window, clip: frame(of: window), depth: 0, sheet: false, scrolled: false)
        return (problems, tree.joined(separator: "\n") + "\n")
    }

    private static func label(of element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let text = string(element, key), !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String? {
        switch attribute(element, key) {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
        if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    private static func describe(_ r: CGRect) -> String {
        guard isFinite(r) else { return "(no frame)" }
        return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    /// Some elements (off screen, not laid out yet) report NaN or infinite frames.
    private static func isFinite(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite)
    }
}
#endif
