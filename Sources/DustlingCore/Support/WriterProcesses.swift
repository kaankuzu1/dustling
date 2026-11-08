import Darwin
import Foundation

/// Whether another process that writes the run history (the Dustling app or `dustling-cli`) is
/// running now. Recovery uses it: with no other writer, a run left "in progress" can only be
/// interrupted, so it is finished off at once instead of after the quiet period.
public enum WriterProcesses {
    /// The process names of everything that writes the history.
    public static let names: Set<String> = ["Dustling", "dustling-cli"]

    /// True when a process named in `names`, other than `excluding`, is running.
    public static func othersRunning(excluding pid: pid_t = getpid(), names: Set<String> = names) -> Bool {
        runningNames(excluding: pid).contains { names.contains($0) }
    }

    /// The names of every process this user can see, except `excluding`.
    static func runningNames(excluding pid: pid_t) -> [String] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        var result: [String] = []
        var name = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        for other in pids.prefix(Int(count)) where other > 0 && other != pid {
            let length = proc_name(other, &name, UInt32(name.count))
            guard length > 0 else { continue }
            result.append(String(decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return result
    }
}
