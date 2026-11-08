import DustlingAppModel
import SwiftUI

/// The part of a confirmation sheet between its pinned header and its pinned buttons. It is as tall
/// as its content up to `layout.middleCap` and scrolls past that, so the sheet always fits the window
/// with its buttons in view (`SheetLayout`). The scroller shows whenever there is more below.
struct SheetMiddle<Content: View>: View {
    let layout: SheetLayout
    let spacing: CGFloat
    @ViewBuilder let content: Content
    /// The content's own height, measured; the scroll view takes it up to the cap.
    @State private var contentHeight: CGFloat?

    var body: some View {
        let cap = CGFloat(layout.middleCap)
        let scrolls = (contentHeight ?? 0) > cap
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: spacing) { content }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(scrolls ? .visible : .hidden)
        .frame(height: min(contentHeight ?? cap, cap))
    }
}
