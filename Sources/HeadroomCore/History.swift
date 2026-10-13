import Foundation

/// A point-in-time reading of available space.
public struct VolumeSample: Codable, Equatable, Sendable {
    public var date: Date
    public var available: Int64

    public init(date: Date, available: Int64) {
        self.date = date
        self.available = available
    }
}

/// One full scan of every category. Only complete measurements are stored, so growth
/// is always computed between comparable numbers.
public struct CategoryScan: Codable, Equatable, Sendable {
    public var date: Date
    public var sizes: [String: Int64]

    public init(date: Date, sizes: [String: Int64]) {
        self.date = date
        self.sizes = sizes
    }
}

public struct History: Codable, Equatable, Sendable {
    public static let retention: TimeInterval = 8 * 24 * 3600
    /// Don't store volume samples closer together than this.
    public static let sampleSpacing: TimeInterval = 10 * 60

    public var samples: [VolumeSample] = []
    public var scans: [CategoryScan] = []

    public init(samples: [VolumeSample] = [], scans: [CategoryScan] = []) {
        self.samples = samples
        self.scans = scans
    }

    public mutating func record(_ sample: VolumeSample) {
        if let last = samples.last, sample.date.timeIntervalSince(last.date) < Self.sampleSpacing {
            samples[samples.count - 1] = VolumeSample(date: last.date, available: sample.available)
        } else {
            samples.append(sample)
        }
        prune(now: sample.date)
    }

    public mutating func record(_ scan: CategoryScan) {
        scans.append(scan)
        prune(now: scan.date)
    }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.date < cutoff }
        scans.removeAll { $0.date < cutoff }
    }

    /// Samples in the trailing window, oldest first.
    public func samples(inLast window: TimeInterval, now: Date) -> [VolumeSample] {
        let start = now.addingTimeInterval(-window)
        return samples.filter { $0.date >= start }
    }

    /// Change in available space versus the newest sample at least `window` old.
    /// Nil when there's no sample that old yet; we don't guess.
    public func availableChange(over window: TimeInterval, now: Date, current: Int64) -> Int64? {
        guard let baseline = samples.last(where: { now.timeIntervalSince($0.date) >= window }) else { return nil }
        return current - baseline.available
    }

    /// Growth per category versus the newest scan at least `window` old.
    /// Falls back to the oldest scan when it's at least `minimumAge` old, so a fresh install
    /// still shows something useful after a few hours.
    public func categoryGrowth(
        over window: TimeInterval, now: Date, current: [String: Int64], minimumAge: TimeInterval = 3600
    ) -> (since: Date, deltas: [String: Int64])? {
        let baseline = scans.last(where: { now.timeIntervalSince($0.date) >= window })
            ?? scans.first.flatMap { now.timeIntervalSince($0.date) >= minimumAge ? $0 : nil }
        guard let baseline else { return nil }
        var deltas: [String: Int64] = [:]
        for (id, size) in current {
            guard let before = baseline.sizes[id] else { continue }
            deltas[id] = size - before
        }
        return (baseline.date, deltas)
    }
}

/// Reads and writes history as JSON in Application Support.
public struct HistoryStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: HistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStore(url: base.appendingPathComponent("Headroom/history.json"))
    }

    public func load() -> History {
        guard let data = try? Data(contentsOf: url) else { return History() }
        return (try? JSONDecoder.history.decode(History.self, from: data)) ?? History()
    }

    public func save(_ history: History) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.history.encode(history).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var history: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var history: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
