import DustlingCore
import Foundation

/// Plain-words wording for what a run did, shared by the Startup and History screens.
public enum OutcomePresentation {
    /// A startup toggle that worked is recorded by the engine as `skipped: disabled|enabled`; it is
    /// shown as "Turned off" / "Turned on", never as skipped. The mapping only applies to startup runs.
    /// An item needing admin rights needs the Mac password (`PasswordCopy`, by `fullDiskAccess` now),
    /// except in a startup run: switching startup items is still the cleanup helper's job.
    public static func text(_ outcome: DeletionOutcome, in kind: RunKind, fullDiskAccess: Bool = true) -> String {
        if kind == .startupChange, case .skipped(let reason) = outcome {
            if reason == "disabled" { return "Turned off" }
            if reason == "enabled" { return "Turned on" }
        }
        switch outcome {
        case .movedToTrash: return "Moved to Trash"
        case .skipped(let reason): return "Skipped: \(reason)"
        case .failed(let reason): return "Failed: \(reason)"
        case .needsAdmin:
            return kind == .startupChange ? helperText : PasswordCopy.reason(fullDiskAccess: fullDiskAccess)
        case .deleted: return "Deleted"
        }
    }

    /// A startup item that needs admin rights.
    static let helperText = "Needs the cleanup helper"

    /// True when a startup run's only job was done (turned on or off).
    public static func isSuccessfulToggle(_ outcome: DeletionOutcome, in kind: RunKind) -> Bool {
        kind == .startupChange && (outcome == .skipped(reason: "disabled") || outcome == .skipped(reason: "enabled"))
    }
}
