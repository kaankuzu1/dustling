import Foundation

/// A size that may be incomplete because something couldn't be read. Front ends must never show a
/// plain 0 where `couldNotScan` is true, and should say "at least" when `isComplete` is false.
public struct ScanTotal: Equatable, Sendable {
    public var bytes: UInt64
    /// Items found (including any whose bytes are left out of a total, e.g. items of open apps).
    public var itemCount: Int
    /// False when some folder or item couldn't be read, so `bytes` is a lower bound.
    public var isComplete: Bool
    /// True when at least one of the problems was missing Full Disk Access.
    public var needsFullDiskAccess: Bool

    public init(bytes: UInt64 = 0, itemCount: Int = 0, isComplete: Bool = true, needsFullDiskAccess: Bool = false) {
        self.bytes = bytes
        self.itemCount = itemCount
        self.isComplete = isComplete
        self.needsFullDiskAccess = needsFullDiskAccess
    }

    /// Nothing was found and something couldn't be read: the honest answer is "couldn't scan", not 0.
    public var couldNotScan: Bool { !isComplete && itemCount == 0 }

    mutating func add(_ other: ScanTotal) {
        bytes += other.bytes
        itemCount += other.itemCount
        isComplete = isComplete && other.isComplete
        needsFullDiskAccess = needsFullDiskAccess || other.needsFullDiskAccess
    }
}

extension CategoryScan {
    /// This category's size together with whether it is complete.
    public var total: ScanTotal {
        ScanTotal(
            bytes: bytes, itemCount: items.count, isComplete: issues.isEmpty && !stopped,
            needsFullDiskAccess: issues.contains { if case .missingFullDiskAccess = $0 { true } else { false } })
    }
}

/// The scan's totals, kept apart on purpose: what a default clean would move, what needs the user's
/// review, what needs admin rights, and the Trash. They are never added into one number.
public struct ScanTotals: Equatable, Sendable {
    /// Preselected categories that don't need admin, minus items of apps that are open right now.
    public var cleanableByDefault = ScanTotal()
    /// Bytes in the default categories that belong to apps open right now (a clean skips them).
    public var skippedInUse: UInt64 = 0
    /// Review categories (only cleaned when the user includes them).
    public var review = ScanTotal()
    /// Categories that need admin rights: the app moves them with the Mac password when the user ticks
    /// them; the CLI never touches them.
    public var needsAdmin = ScanTotal()
    /// The Trash (only ever emptied as a whole).
    public var trash = ScanTotal()

    public init(_ scans: [CategoryScan]) {
        for scan in scans {
            var total = scan.total
            if scan.category.selection == .emptyTrashOnly {
                trash.add(total)
            } else if scan.category.requiresAdmin {
                needsAdmin.add(total)
            } else if scan.category.selection == .review {
                review.add(total)
            } else {
                let inUseBytes = scan.items.filter { $0.inUseByBundleID != nil }.reduce(UInt64(0)) { $0 + $1.bytes }
                skippedInUse += inUseBytes
                total.bytes -= inUseBytes
                cleanableByDefault.add(total)
            }
        }
    }
}
