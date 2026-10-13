import Foundation

/// Decides when to send a low-space notification. Alerts once on crossing below the
/// threshold, again at most once a day while it stays low, and re-arms only after
/// space recovers past the threshold plus a margin, so hovering near the line is quiet.
public struct LowSpaceAlert: Codable, Equatable, Sendable {
    public static let rearmMargin: Int64 = 5_000_000_000
    public static let repeatInterval: TimeInterval = 24 * 3600

    public var lastAlert: Date?
    public var armed = true

    public init(lastAlert: Date? = nil, armed: Bool = true) {
        self.lastAlert = lastAlert
        self.armed = armed
    }

    /// Returns true when a notification should go out now.
    public mutating func evaluate(available: Int64, threshold: Int64, now: Date) -> Bool {
        if available >= threshold + Self.rearmMargin {
            armed = true
            return false
        }
        guard available < threshold else { return false }
        if armed {
            armed = false
            lastAlert = now
            return true
        }
        if let last = lastAlert, now.timeIntervalSince(last) >= Self.repeatInterval {
            lastAlert = now
            return true
        }
        return false
    }
}
