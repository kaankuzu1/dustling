import Foundation

/// Locale-independent English byte formatting.
///
/// ByteCountFormatter has no locale setting (it follows the system language, so a Turkish Mac would
/// print "MB" with a comma), so this mirrors its `.file` style: decimal units, up to 0/1/2 decimals (trailing zeros dropped), English.
public enum Bytes {
    public static func format(_ count: UInt64) -> String {
        format(Int64(clamping: count))
    }

    public static func format(_ count: Int64) -> String {
        let value = Double(max(0, count))
        if value < 1000 { return count == 1 ? "1 byte" : "\(max(0, count)) bytes" }
        let units: [(name: String, decimals: Int)] = [("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2), ("PB", 2)]
        var scaled = value / 1000
        var index = 0
        while index < units.count - 1 {
            // A value that rounds up to 1000 in this unit ("1000 KB") belongs in the next unit.
            let step = pow(10.0, Double(units[index].decimals))
            let rounded = (scaled * step).rounded() / step
            if rounded < 1000 { break }
            scaled /= 1000
            index += 1
        }
        var text = String(format: "%.\(units[index].decimals)f", scaled)
        // Like ByteCountFormatter: "1 MB", "1.5 MB", never "1.0 MB".
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return "\(text) \(units[index].name)"
    }
}
