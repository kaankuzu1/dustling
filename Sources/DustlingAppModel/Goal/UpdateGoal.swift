import DustlingCore
import Foundation

/// How much free space the user wants for a macOS update.
public struct UpdateGoal: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        case userSet
        case measured(Date)
    }

    public var neededBytes: Int64
    public var source: Source

    /// Default 30 GB, decimal, matching Finder.
    public init(neededBytes: Int64 = 30_000_000_000, source: Source = .userSet) {
        self.neededBytes = neededBytes
        self.source = source
    }

    public func shortfall(available: Int64) -> Int64 {
        max(0, neededBytes - available)
    }

    public struct MeasureError: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
    }

    /// Size in bytes of the largest pending macOS update, or nil only when no macOS entry is listed.
    /// Runs `softwareupdate --list` (it contacts Apple), so call it only when the user clicks
    /// "Check update size" (Ruling R32). It blocks on the network, so call it off the main actor. Failure throws; no number is ever invented.
    public static func measure(commands: CommandRunning) throws -> Int64? {
        let result = try commands.run("/usr/sbin/softwareupdate", ["--list"])
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MeasureError(
                description: "softwareupdate exited with status \(result.status)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        var largest: Int64?
        // softwareupdate prints its listing on stdout but some of it on stderr, so read both.
        for line in (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline) {
            guard let title = field("Title:", in: line), title.hasPrefix("macOS") else { continue }
            // A macOS entry whose size can't be read must not look like "no update pending".
            guard let size = field("Size:", in: line), size.hasSuffix("KiB"),
                let kib = Int64(size.dropLast(3)), kib >= 0,
                case let (bytes, overflow) = kib.multipliedReportingOverflow(by: 1024), !overflow
            else { throw MeasureError(description: "couldn't read the update size") }
            if bytes > (largest ?? 0) || largest == nil { largest = bytes }
        }
        return largest
    }

    /// The text after `key` up to the next comma, trimmed.
    private static func field(_ key: String, in line: Substring) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        let value = rest.prefix { $0 != "," }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
