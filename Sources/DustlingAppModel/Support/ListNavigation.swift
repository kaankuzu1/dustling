/// Arrow-key movement through a custom list (one drawn without a native `List`): the next or previous
/// row, clamped at the ends. With no current row, down starts at the first row and up at the last.
public enum ListNavigation {
    public static func step<ID: Equatable>(_ ids: [ID], from current: ID?, by offset: Int) -> ID? {
        guard !ids.isEmpty, offset != 0 else { return current }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}
