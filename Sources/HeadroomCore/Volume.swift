import Foundation

/// Capacity of the startup volume.
public struct VolumeStatus: Codable, Equatable, Sendable {
    public var total: Int64
    /// What macOS will make available for things you ask for, including purgeable space
    /// it can clear on demand (caches, iCloud files, local snapshots). Matches Finder's "available".
    public var available: Int64
    /// Blocks that are free right now, without purging anything.
    public var free: Int64

    public init(total: Int64, available: Int64, free: Int64) {
        self.total = total
        self.available = available
        self.free = free
    }

    public var availableFraction: Double {
        total > 0 ? Double(available) / Double(total) : 0
    }

    /// Space in use right now, before purging.
    public var used: Int64 { max(0, total - free) }

    /// Space macOS says it could clear on its own. Approximate by nature.
    public var purgeable: Int64 { max(0, available - free) }

    public static func current(path: String = "/") throws -> VolumeStatus {
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeStatus(total: total, available: max(available, free), free: free)
    }
}
