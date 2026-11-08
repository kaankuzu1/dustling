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

    /// The names (`p_comm`, at most 16 characters) of every process on the system except
    /// `excluding`, from `sysctl` `KERN_PROC_ALL`, which lists all processes, not only this user's.
    static func runningNames(excluding pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            // Room for processes started between the two calls.
            size += size / 8
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = procs.withUnsafeMutableBytes { buffer in
                sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            let count = size / MemoryLayout<kinfo_proc>.stride
            return procs.prefix(count).compactMap { proc -> String? in
                guard proc.kp_proc.p_pid != pid else { return nil }
                return withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                    let bytes = raw.prefix { $0 != 0 }
                    return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
                }
            }
        }
        return []
    }
}
