import Foundation

/// How Dustling words an item that belongs to the system and is still where it was. With Full Disk
/// Access on, Dustling moves such items after asking for the Mac password, once per action. Without
/// it Dustling can't open the Trash for that step, so access comes first. Startup items keep the
/// cleanup helper's wording: switching them is still the helper's job.
public enum PasswordCopy {
    public static let needed = "Needs your Mac password"
    public static let neededAfterAccess = "Needs Full Disk Access, then your Mac password"

    /// "Needs your Mac password", or without Full Disk Access "Needs Full Disk Access, then your Mac
    /// password".
    public static func reason(fullDiskAccess: Bool) -> String {
        fullDiskAccess ? needed : neededAfterAccess
    }

    /// The same, starting in lower case: "needs your Mac password".
    public static func lowercased(fullDiskAccess: Bool) -> String {
        let text = reason(fullDiskAccess: fullDiskAccess)
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// "1 needs your Mac password", "3 need Full Disk Access, then your Mac password".
    public static func count(_ count: Int, fullDiskAccess: Bool) -> String {
        let what = fullDiskAccess ? "your Mac password" : "Full Disk Access, then your Mac password"
        return "\(count) \(count == 1 ? "needs" : "need") \(what)"
    }
}
