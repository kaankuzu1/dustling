import DustlingAppModel
import SwiftUI

/// Keyboard support for a list drawn without a native `List` (the Uninstaller's apps, History's
/// runs): the list takes keyboard focus (a click into it, or Tab with keyboard navigation on), shows
/// the system focus ring, and the up and down arrows move the current row, which stays in view.
struct ArrowKeyList<ID: Hashable>: ViewModifier {
    let ids: [ID]
    let current: ID?
    let proxy: ScrollViewProxy
    let select: (ID) -> Void
    /// Off for a list that only shows placeholders: it takes no focus and no keys.
    var isEnabled = true

    func body(content: Content) -> some View {
        content
            .focusable(isEnabled)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard isEnabled, let next = ListNavigation.step(ids, from: current, by: offset) else { return .ignored }
        select(next)
        proxy.scrollTo(next)
        return .handled
    }
}

extension View {
    func arrowKeyList<ID: Hashable>(
        _ ids: [ID], current: ID?, proxy: ScrollViewProxy, isEnabled: Bool = true, select: @escaping (ID) -> Void
    ) -> some View {
        modifier(ArrowKeyList(ids: ids, current: current, proxy: proxy, select: select, isEnabled: isEnabled))
    }
}
