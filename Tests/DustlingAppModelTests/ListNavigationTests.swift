import Testing
@testable import DustlingAppModel

struct ListNavigationTests {
    @Test func movesAndClampsAtTheEnds() {
        let ids = ["a", "b", "c"]
        #expect(ListNavigation.step(ids, from: "a", by: 1) == "b")
        #expect(ListNavigation.step(ids, from: "c", by: 1) == "c")
        #expect(ListNavigation.step(ids, from: "a", by: -1) == "a")
        #expect(ListNavigation.step(ids, from: "b", by: -1) == "a")
    }

    @Test func startsFromAnEndWithoutACurrentRow() {
        let ids = ["a", "b", "c"]
        #expect(ListNavigation.step(ids, from: nil, by: 1) == "a")
        #expect(ListNavigation.step(ids, from: nil, by: -1) == "c")
        #expect(ListNavigation.step(ids, from: "gone", by: 1) == "a")
        #expect(ListNavigation.step([String](), from: nil, by: 1) == nil)
    }
}
