import AppKit
import HeadroomCore
import Observation
import ServiceManagement
import UserNotifications

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percent, bytes, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percent: "Percent available"
        case .bytes: "Space available"
        case .icon: "Icon only"
        }
    }
}

/// Inline confirmation state for a row: what will run and what it will remove.
struct PendingClean: Equatable {
    var categoryID: String
    var previewText: String?
    var loadingPreview: Bool
}

@MainActor
@Observable
final class AppModel {
    // MARK: Settings

    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    /// Notify when available space drops below this many bytes.
    var alertThreshold: Int64 {
        didSet { defaults.set(alertThreshold, forKey: "alertThreshold"); evaluateAlert() }
    }
    var alertsEnabled: Bool {
        didSet {
            defaults.set(alertsEnabled, forKey: "alertsEnabled")
            if alertsEnabled { requestNotificationPermission() }
        }
    }
    var projectRoots: [String] {
        didSet { defaults.set(projectRoots, forKey: "projectRoots") }
    }
    var staleAfterDays: Int {
        didSet { defaults.set(staleAfterDays, forKey: "staleAfterDays") }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Couldn't change Open at Login: \(error.localizedDescription)"
            }
            loginItemRevision += 1
        }
    }
    /// Bumped so SwiftUI re-reads `launchAtLogin`, which lives in SMAppService.
    private(set) var loginItemRevision = 0

    // MARK: State

    private(set) var volume: VolumeStatus?
    private(set) var history: History
    private(set) var measurements: [String: SizeReading] = [:]
    private(set) var growth: (since: Date, deltas: [String: Int64])?
    private(set) var nodeModules: [NodeModulesFolder] = []
    private(set) var lastScan: Date?
    private(set) var scanning = false
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    private(set) var cleaning: Set<String> = []
    var pending: PendingClean?
    /// One-line result of the last clean, e.g. "Freed 11 GB".
    var lastResult: String?
    var lastError: String?

    private var clearResultTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let store = HistoryStore.standard
    private var alert: LowSpaceAlert
    private var timers: [Timer] = []

    static let scanInterval: TimeInterval = 3600
    static let volumeInterval: TimeInterval = 60
    /// Rows smaller than this are hidden to keep the panel short.
    static let minimumShownBytes: Int64 = 100_000_000

    init() {
        defaults.register(defaults: [
            "menuBarStyle": MenuBarStyle.percent.rawValue,
            "alertThreshold": Int64(25_000_000_000),
            "alertsEnabled": true,
            "projectRoots": ["~/github"],
            "staleAfterDays": 30,
        ])
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .percent
        alertThreshold = (defaults.object(forKey: "alertThreshold") as? NSNumber)?.int64Value ?? 25_000_000_000
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        projectRoots = defaults.stringArray(forKey: "projectRoots") ?? ["~/github"]
        staleAfterDays = defaults.integer(forKey: "staleAfterDays")
        history = store.load()
        if let data = defaults.data(forKey: "lowSpaceAlert"),
           let saved = try? JSONDecoder().decode(LowSpaceAlert.self, from: data) {
            alert = saved
        } else {
            alert = LowSpaceAlert()
        }
        if let last = history.scans.last {
            lastScan = last.date
            let allowed = Set(measurable(Catalog.all).map(\.id))
            measurements = last.sizes
                .filter { allowed.contains($0.key) }
                .mapValues { SizeReading(bytes: $0, complete: true, missing: false) }
        }
    }

    func start() {
        // A disk monitor is only useful if it's running, so opt in to Open at Login once.
        // Turning it off in Settings sticks. Dev builds run from ./build are left alone.
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        if installed, !defaults.bool(forKey: "didEnableLoginItem") {
            defaults.set(true, forKey: "didEnableLoginItem")
            try? SMAppService.mainApp.register()
        }
        if alertsEnabled { requestNotificationPermission() }
        refreshVolume()
        scan()
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.volumeInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshVolume() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            },
        ]
        // Wake from sleep can jump a lot of time; catch up right away.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshVolume()
                if let self, Date().timeIntervalSince(self.lastScan ?? .distantPast) > Self.scanInterval { self.scan() }
            }
        }
    }

    // MARK: Derived

    var isLow: Bool { (volume?.available ?? .max) < alertThreshold }

    var availableChangeToday: Int64? {
        guard let volume else { return nil }
        return history.availableChange(over: 86_400, now: Date(), current: volume.available)
    }

    struct Row: Identifiable {
        var category: StorageCategory
        var measurement: SizeReading
        var growth: Int64?
        var id: String { category.id }
    }

    func rows(_ safety: Safety) -> [Row] {
        Catalog.all
            .filter { $0.safety == safety }
            .compactMap { category -> Row? in
                guard let m = measurements[category.id], !m.missing else { return nil }
                guard m.bytes >= Self.minimumShownBytes || !m.complete else { return nil }
                return Row(category: category, measurement: m, growth: growth?.deltas[category.id])
            }
            .sorted { $0.measurement.bytes > $1.measurement.bytes }
    }

    var safeTotal: Int64 { rows(.safe).reduce(0) { $0 + $1.measurement.bytes } }

    var staleNodeModules: [NodeModulesFolder] {
        nodeModules.filter { $0.isStale(now: Date(), after: staleAfterDays) }
    }

    /// Categories skipped because they need Full Disk Access. Docker is listed only if installed.
    var blockedCategories: [StorageCategory] {
        guard !hasFullDiskAccess else { return [] }
        return Catalog.all.filter {
            $0.requiresFullDiskAccess
                && ($0.id != "docker" || FileManager.default.fileExists(atPath: "/Applications/Docker.app"))
        }
    }

    /// Measured, but parts of the tree couldn't be read.
    var hasPartialMeasurements: Bool {
        measurements.values.contains { !$0.complete && !$0.missing }
    }

    // MARK: Volume

    func refreshVolume() {
        guard let status = try? VolumeStatus.current() else { return }
        volume = status
        history.record(VolumeSample(date: Date(), available: status.available))
        persist()
        evaluateAlert()
    }

    private func evaluateAlert() {
        // With alerts off, leave the alert state alone so turning them on still fires.
        guard alertsEnabled, canNotify, let volume else { return }
        let fire = alert.evaluate(available: volume.available, threshold: alertThreshold, now: Date())
        defaults.set(try? JSONEncoder().encode(alert), forKey: "lowSpaceAlert")
        guard fire else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(Format.bytes(volume.available)) available"
        let top = rows(.safe).first.map { " \($0.category.name) alone is \(Format.bytes($0.measurement.bytes))." } ?? ""
        content.body = "You're below \(Format.bytes(alertThreshold)).\(top) Click the menu bar icon to clear space."
        let request = UNNotificationRequest(identifier: "low-space", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// UNUserNotificationCenter traps outside an app bundle (e.g. `swift run`).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Scanning

    /// Scans and cleans never overlap: a scan that started before a clean would otherwise
    /// finish with pre-clean sizes, resurrect deleted folders, and skew growth history.
    func scan() {
        guard !scanning, cleaning.isEmpty else { return }
        scanning = true
        hasFullDiskAccess = FullDiskAccess.isGranted
        let categories = measurable(Catalog.all)
        let roots = projectRoots.map { Paths.expand($0) }
        Task {
            async let measured = Self.measure(categories)
            async let folders = Self.findNodeModules(roots: roots)
            let (results, found) = await (measured, folders)
            finishScan(results, nodeModules: found)
        }
    }

    private func finishScan(_ results: [String: SizeReading], nodeModules found: [NodeModulesFolder]) {
        let now = Date()
        measurements = results
        nodeModules = found.sorted { $0.bytes > $1.bytes }
        lastScan = now
        scanning = false
        pending = nil
        // Only complete, existing measurements go into history, so growth compares like with like.
        let comparable = results.filter { $0.value.complete && !$0.value.missing }.mapValues(\.bytes)
        growth = history.categoryGrowth(over: 86_400, now: now, current: comparable)
        history.record(CategoryScan(date: now, sizes: comparable))
        persist()
    }

    private func remeasure(_ ids: [String]) async {
        let categories = measurable(Catalog.all.filter { ids.contains($0.id) })
        let results = await Self.measure(categories)
        for (id, m) in results { measurements[id] = m }
        if let growth {
            var deltas = growth.deltas
            for id in ids { deltas[id] = nil }
            self.growth = (growth.since, deltas)
        }
    }

    /// Never touch protected locations without Full Disk Access: macOS would either
    /// deny the read or show a consent prompt that blocks the scan until answered.
    private func measurable(_ categories: [StorageCategory]) -> [StorageCategory] {
        hasFullDiskAccess ? categories : categories.filter { !$0.requiresFullDiskAccess }
    }

    nonisolated private static func measure(_ categories: [StorageCategory]) async -> [String: SizeReading] {
        let readings = await parallelMap(categories.map { $0.expandedPaths() }) { Measure.allocatedSize(of: $0) }
        return Dictionary(uniqueKeysWithValues: zip(categories.map(\.id), readings))
    }

    nonisolated private static func findNodeModules(roots: [String]) async -> [NodeModulesFolder] {
        let found = await parallelMap([roots]) { NodeModules.find(in: $0) }.first ?? []
        let sizes = await parallelMap(found.map(\.path)) { Measure.allocatedSize(of: [$0]).bytes }
        return zip(found, sizes).map { folder, bytes in
            var folder = folder
            folder.bytes = bytes
            return folder
        }
    }

    /// Runs blocking file-system work on GCD rather than the Swift concurrency pool,
    /// which shouldn't be tied up by long synchronous traversals.
    nonisolated private static func parallelMap<T: Sendable, R: Sendable>(
        _ items: [T], _ transform: @escaping @Sendable (T) -> R
    ) async -> [R] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let results = LockedArray<R?>(repeating: nil, count: items.count)
                DispatchQueue.concurrentPerform(iterations: items.count) { i in
                    results[i] = transform(items[i])
                }
                continuation.resume(returning: results.values.map { $0! })
            }
        }
    }

    // MARK: Cleaning

    var canClean: Bool { !scanning && cleaning.isEmpty }

    func requestClean(_ category: StorageCategory) {
        lastError = nil
        guard category.action.isDestructive else {
            reveal(category)
            return
        }
        pending = PendingClean(categoryID: category.id, previewText: nil, loadingPreview: category.preview != nil)
        guard let preview = category.preview else { return }
        Task {
            let text = await Self.runPreview(preview)
            if pending?.categoryID == category.id {
                pending?.previewText = text
                pending?.loadingPreview = false
            }
        }
    }

    nonisolated private static func runPreview(_ preview: CleanPreview) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let text: String
                do {
                    let result = try Shell.shared.run(tool: preview.tool, arguments: preview.arguments, timeout: 30)
                    let lines = result.output.split(separator: "\n").map(String.init)
                        .filter { !$0.hasPrefix("==") && !$0.hasPrefix("--") }
                    if !result.succeeded {
                        text = "Couldn't check: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"
                    } else if lines.isEmpty {
                        text = "Nothing listed. Cleaning will only remove unused data."
                    } else {
                        let shown = lines.prefix(8).joined(separator: "\n")
                        text = "\(preview.heading)\n\(shown)" + (lines.count > 8 ? "\n…and \(lines.count - 8) more" : "")
                    }
                } catch {
                    text = error.localizedDescription
                }
                continuation.resume(returning: text)
            }
        }
    }

    func confirmClean(_ ids: [String]) {
        pending = nil
        lastError = nil
        guard canClean else { return }
        hasFullDiskAccess = FullDiskAccess.isGranted
        let categories = measurable(Catalog.all.filter { ids.contains($0.id) && $0.action.isDestructive })
        guard !categories.isEmpty else { return }
        cleaning.formUnion(categories.map(\.id))
        let before = (try? VolumeStatus.current())?.available
        Task {
            let errors = await Self.runCleans(categories)
            await remeasure(categories.map(\.id))
            cleaning.subtract(categories.map(\.id))
            reportFreed(since: before)
            if !errors.isEmpty { lastError = errors.joined(separator: "\n") }
        }
    }

    nonisolated private static func runCleans(_ categories: [StorageCategory]) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errors: [String] = []
                for category in categories {
                    do {
                        try Cleaner.clean(category)
                    } catch {
                        errors.append("\(category.name): \(error.localizedDescription)")
                    }
                }
                continuation.resume(returning: errors)
            }
        }
    }

    func deleteNodeModules(_ folders: [NodeModulesFolder]) {
        pending = nil
        lastError = nil
        guard canClean else { return }
        let paths = folders.map(\.path)
        cleaning.formUnion(paths)
        let before = (try? VolumeStatus.current())?.available
        Task {
            let failures = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var failures: [String] = []
                    for path in paths {
                        do { try Cleaner.deleteNodeModules(at: path) } catch { failures.append(path) }
                    }
                    continuation.resume(returning: failures)
                }
            }
            nodeModules.removeAll { paths.contains($0.path) && !failures.contains($0.path) }
            cleaning.subtract(paths)
            reportFreed(since: before)
            if !failures.isEmpty { lastError = "Couldn't delete \(failures.count) folder(s)." }
        }
    }

    /// Reports what actually came back, measured on the volume, rather than what we predicted.
    private func reportFreed(since before: Int64?) {
        refreshVolume()
        guard let before, let after = volume?.available else { return }
        let freed = after - before
        lastResult = freed > 50_000_000 ? "Freed \(Format.bytes(freed))" : "Done. macOS may take a minute to report the space."
        clearResultTask?.cancel()
        clearResultTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { lastResult = nil }
        }
    }

    func reveal(_ category: StorageCategory) {
        let urls = category.expandedPaths().filter { FileManager.default.fileExists(atPath: $0) }.map(URL.init(fileURLWithPath:))
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func persist() {
        try? store.save(history)
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element]

    init(repeating value: Element, count: Int) {
        storage = Array(repeating: value, count: count)
    }

    subscript(index: Int) -> Element {
        get { lock.withLock { storage[index] } }
        set { lock.withLock { storage[index] = newValue } }
    }

    var values: [Element] { lock.withLock { storage } }
}
