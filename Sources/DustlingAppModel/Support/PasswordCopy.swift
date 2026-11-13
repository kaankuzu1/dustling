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

    /// While a password step runs: the title of the work's bar or its busy label.
    public static let waiting = "Waiting for your Mac password"
    /// Why Stop is off then (a password step can't be stopped from Dustling's window).
    public static let answerToFinish = "Answer or cancel the password box to finish"

    /// "1 needs your Mac password", "3 need Full Disk Access, then your Mac password".
    public static func count(_ count: Int, fullDiskAccess: Bool) -> String {
        let what = fullDiskAccess ? "your Mac password" : "Full Disk Access, then your Mac password"
        return "\(count) \(count == 1 ? "needs" : "need") \(what)"
    }
}
