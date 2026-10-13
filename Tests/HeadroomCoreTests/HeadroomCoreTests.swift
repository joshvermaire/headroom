import Foundation
import Testing
@testable import HeadroomCore

private let gb: Int64 = 1_000_000_000

struct FormatTests {
    @Test func bytes() {
        #expect(Format.bytes(110 * gb) == "110 GB")
        #expect(Format.bytes(7_500_000_000) == "7.5 GB")
        #expect(Format.bytes(236_000_000) == "236 MB")
        #expect(Format.bytes(512) == "512 bytes")
    }

    @Test func delta() {
        #expect(Format.delta(-6_200_000_000) == "−6.2 GB")
        #expect(Format.delta(4_100_000_000) == "+4.1 GB")
    }

    @Test func percentRoundsDown() {
        #expect(Format.percent(0.229) == "22%")
    }
}

struct VolumeTests {
    @Test func derivedValues() {
        let v = VolumeStatus(total: 500 * gb, available: 110 * gb, free: 100 * gb)
        #expect(v.used == 400 * gb)
        #expect(v.purgeable == 10 * gb)
        #expect(abs(v.availableFraction - 0.22) < 0.0001)
    }

    @Test func readsStartupVolume() throws {
        let v = try VolumeStatus.current()
        #expect(v.total > 0)
        #expect(v.available >= v.free)
    }
}

struct HistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func coalescesCloseSamples() {
        var h = History()
        h.record(VolumeSample(date: now, available: 100))
        h.record(VolumeSample(date: now.addingTimeInterval(60), available: 90))
        #expect(h.samples.count == 1)
        #expect(h.samples[0].available == 90)
        h.record(VolumeSample(date: now.addingTimeInterval(History.sampleSpacing + 1), available: 80))
        #expect(h.samples.count == 2)
    }

    @Test func prunesOldSamples() {
        var h = History()
        h.record(VolumeSample(date: now.addingTimeInterval(-9 * 86_400), available: 1))
        h.record(VolumeSample(date: now, available: 2))
        #expect(h.samples.map(\.available) == [2])
    }

    @Test func availableChangeNeedsOldEnoughBaseline() {
        var h = History()
        h.record(VolumeSample(date: now.addingTimeInterval(-3600), available: 100 * gb))
        #expect(h.availableChange(over: 86_400, now: now, current: 90 * gb) == nil)
        h.samples.insert(VolumeSample(date: now.addingTimeInterval(-90_000), available: 120 * gb), at: 0)
        #expect(h.availableChange(over: 86_400, now: now, current: 90 * gb) == -30 * gb)
    }

    @Test func categoryGrowthUsesNewestBaselineOlderThanWindow() {
        var h = History()
        h.record(CategoryScan(date: now.addingTimeInterval(-3 * 86_400), sizes: ["docker": 10 * gb]))
        h.record(CategoryScan(date: now.addingTimeInterval(-86_500), sizes: ["docker": 20 * gb, "npm": 5 * gb]))
        h.record(CategoryScan(date: now.addingTimeInterval(-600), sizes: ["docker": 25 * gb]))
        let growth = h.categoryGrowth(over: 86_400, now: now, current: ["docker": 26 * gb, "npm": 5 * gb, "uv": gb])
        #expect(growth?.deltas == ["docker": 6 * gb, "npm": 0])
    }

    @Test func categoryGrowthFallsBackToOldestAfterAnHour() {
        var h = History()
        h.record(CategoryScan(date: now.addingTimeInterval(-1800), sizes: ["npm": gb]))
        #expect(h.categoryGrowth(over: 86_400, now: now, current: ["npm": 2 * gb]) == nil)
        h.scans[0].date = now.addingTimeInterval(-7200)
        #expect(h.categoryGrowth(over: 86_400, now: now, current: ["npm": 2 * gb])?.deltas == ["npm": gb])
    }

    @Test func storeRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(url: dir.appendingPathComponent("history.json"))
        var h = History()
        h.record(VolumeSample(date: now, available: 42))
        try store.save(h)
        #expect(store.load() == h)
    }
}

struct LowSpaceAlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let threshold = 25 * gb

    @Test func alertsOnceThenDaily() {
        var a = LowSpaceAlert()
        #expect(a.evaluate(available: 30 * gb, threshold: threshold, now: now) == false)
        #expect(a.evaluate(available: 24 * gb, threshold: threshold, now: now) == true)
        #expect(a.evaluate(available: 23 * gb, threshold: threshold, now: now.addingTimeInterval(3600)) == false)
        #expect(a.evaluate(available: 23 * gb, threshold: threshold, now: now.addingTimeInterval(86_401)) == true)
    }

    @Test func hysteresisPreventsFlapping() {
        var a = LowSpaceAlert()
        #expect(a.evaluate(available: 24 * gb, threshold: threshold, now: now) == true)
        // Recovers just above the line: not re-armed.
        #expect(a.evaluate(available: 26 * gb, threshold: threshold, now: now.addingTimeInterval(60)) == false)
        #expect(a.evaluate(available: 24 * gb, threshold: threshold, now: now.addingTimeInterval(120)) == false)
        // Recovers past the margin: re-armed.
        #expect(a.evaluate(available: 31 * gb, threshold: threshold, now: now.addingTimeInterval(180)) == false)
        #expect(a.evaluate(available: 24 * gb, threshold: threshold, now: now.addingTimeInterval(240)) == true)
    }
}

struct FileSystemTests {
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func measuresAndCountsHardLinksOnce() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.bin")
        try Data(count: 1_000_000).write(to: file)
        let single = Measure.allocatedSize(of: [root.path])
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("b.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/usr"))
        let linked = Measure.allocatedSize(of: [root.path])
        #expect(single.bytes >= 1_000_000)
        #expect(linked.bytes == single.bytes)
        #expect(linked.complete)
        #expect(!linked.missing)
    }

    @Test func missingPathsAreMissingNotZero() {
        let m = Measure.allocatedSize(of: ["/nonexistent/headroom-test"])
        #expect(m.missing)
    }

    @Test func findsNodeModulesWithoutDescending() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("node_modules/dep/node_modules"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        let found = NodeModules.find(in: [root.path])
        #expect(found.map(\.projectName) == ["app"])
        #expect(Date().timeIntervalSince(found[0].lastActive) < 60)
        #expect(found[0].isStale(now: Date().addingTimeInterval(31 * 86_400), after: 30))
    }

    @Test func monorepoPackageUsesRepositoryActivity() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let pkg = repo.appendingPathComponent("packages/web")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-90 * 86_400)
        let pkgJSON = pkg.appendingPathComponent("package.json")
        try Data("{}".utf8).write(to: pkgJSON)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: pkgJSON.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: pkg.path)
        try Data().write(to: repo.appendingPathComponent(".git/index"))  // committed just now

        let found = NodeModules.find(in: [root.path, repo.path])
        #expect(found.count == 1)  // overlapping roots don't duplicate
        #expect(!found[0].isStale(now: Date(), after: 30))
        // A scan root inside the repository still finds the repository's activity.
        let inner = NodeModules.find(in: [repo.appendingPathComponent("packages").path])
        #expect(inner.count == 1)
        #expect(!inner[0].isStale(now: Date(), after: 30))
    }

    @Test func worktreeGitFileIsFollowed() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent("main/.git/worktrees/feature")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let tree = root.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDir.path)\n".utf8).write(to: tree.appendingPathComponent(".git"))
        #expect(NodeModules.gitDirectory(in: tree.path) == gitDir.path)
    }

    @Test func deleteContentsKeepsDirectoryAndRefusesUnknownPaths() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: cache.appendingPathComponent("x"))
        try Cleaner.deleteContents(of: [cache.path], allowed: [cache.path], trustedRoot: root.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        #expect(throws: CleanError.self) {
            try Cleaner.deleteContents(of: [root.path], allowed: [cache.path], trustedRoot: root.path)
        }
    }

    @Test func refusesSymlinkedCacheOrAncestor() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("caches"), withIntermediateDirectories: true)
        let precious = elsewhere.appendingPathComponent("caches/precious")
        try Data(count: 10).write(to: precious)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // ~/.gradle is a symlink to another location.
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".gradle"), withDestinationURL: elsewhere)
        let viaAncestor = home.appendingPathComponent(".gradle/caches").path
        #expect(throws: CleanError.self) {
            try Cleaner.deleteContents(of: [viaAncestor], allowed: [viaAncestor], trustedRoot: home.path)
        }
        // The cache folder itself is a symlink.
        let direct = home.appendingPathComponent("cache").path
        try FileManager.default.createSymbolicLink(atPath: direct, withDestinationPath: elsewhere.appendingPathComponent("caches").path)
        #expect(throws: CleanError.self) {
            try Cleaner.deleteContents(of: [direct], allowed: [direct], trustedRoot: home.path)
        }
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func deleteNodeModulesOnlyDeletesNodeModules() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let nm = root.appendingPathComponent("app/node_modules")
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        #expect(throws: CleanError.self) { try Cleaner.deleteNodeModules(at: root.appendingPathComponent("app").path) }
        try Cleaner.deleteNodeModules(at: nm.path)
        #expect(!FileManager.default.fileExists(atPath: nm.path))
    }

    @Test func catalogDeletionPathsAreAllUnderHome() {
        let allowed = Cleaner.allowedPaths(home: "/Users/test")
        #expect(!allowed.isEmpty)
        #expect(allowed.allSatisfy { $0.hasPrefix("/Users/test/") })
        #expect(Set(Catalog.all.map(\.id)).count == Catalog.all.count)
    }
}

struct ShellTests {
    @Test func resolvesLoginShellPathAndRunsTools() throws {
        let path = try #require(Shell.loginShellPath())
        #expect(path.contains("/usr/bin"))
        let result = try Shell.shared.run(tool: "echo", arguments: ["hi"], timeout: 10)
        #expect(result.succeeded)
        #expect(result.output == "hi\n")
        #expect(throws: ShellError.self) { try Shell.shared.run(tool: "definitely-not-a-tool-xyz", arguments: []) }
    }
}

struct ShellRobustnessTests {
    @Test func doesNotWaitForBackgroundChildrenHoldingThePipe() throws {
        let start = Date()
        let result = try Shell.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 5 & printf done"],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        #expect(result.output == "done")
        #expect(Date().timeIntervalSince(start) < 2.5)
    }

    @Test func killsCommandsThatIgnoreSIGTERM() throws {
        let start = Date()
        #expect(throws: ShellError.self) {
            try Shell.run(
                executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 10"],
                environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func runsFromHomeDirectory() throws {
        let result = try Shell.run(executable: "/bin/pwd", arguments: [], environment: [:], timeout: 5)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == NSHomeDirectory())
    }
}
