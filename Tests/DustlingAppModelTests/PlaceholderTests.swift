import Foundation
import Testing
@testable import DustlingAppModel

/// The loading skeletons draw real rows with these placeholders, so they must vary from row to row
/// and never name anything real.
struct PlaceholderTests {
    @Test func textLengthVariesWithinItsSpread() {
        let lengths = (0..<12).map { Placeholder.text($0, base: 10, spread: 8).count }
        #expect(lengths.allSatisfy { (10...18).contains($0) })
        #expect(Set(lengths).count > 3)
        #expect(Placeholder.text(5, base: 26, spread: 0).count == 26)
    }

    @Test func textHasWordsSoItWrapsLikeText() {
        #expect(Placeholder.text(0, base: 12, spread: 0) == "xxxxx xxxxx ")
    }

    @Test func rowsAreMadeUp() {
        for index in 0..<4 {
            #expect(StartupRow.placeholder(index).item.label.hasPrefix("com.example."))
            #expect(StartupRow.placeholder(index).item.plistURL == nil)
            #expect(AppRow.placeholder(index).app.url.path(percentEncoded: false).hasPrefix("/placeholder-"))
            #expect(HistoryItem.placeholder(index).path.hasPrefix("/x"))
            #expect(HistoryScreen.LogRow.placeholder(index).id == index)
        }
    }
}
