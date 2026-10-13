import Foundation

public enum Format {
    /// "110 GB", "7.5 GB", "236 MB". Decimal units, like Finder.
    public static func bytes(_ value: Int64) -> String {
        let v = Double(abs(value))
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (scale, unit) in units where v >= scale {
            let n = v / scale
            let digits = n >= 10 ? 0 : 1
            return String(format: "%.\(digits)f %@", n, unit)
        }
        return "\(Int(v)) bytes"
    }

    /// "+4.1 GB", "−6.2 GB". Uses a real minus sign.
    public static func delta(_ value: Int64) -> String {
        (value < 0 ? "−" : "+") + bytes(value)
    }

    /// "22%". Rounds down so the menu bar never looks better than reality.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }

    /// Whether a delta is big enough to call out. Caches churn a little all the time.
    public static func isNotable(_ delta: Int64) -> Bool {
        abs(delta) >= 100_000_000
    }
}
