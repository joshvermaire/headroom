import Foundation

/// A project's `node_modules` folder.
public struct NodeModulesFolder: Identifiable, Equatable, Sendable {
    public var id: String { path }
    /// Path to the `node_modules` directory itself.
    public let path: String
    public let projectName: String
    /// Most recent sign of work on the project: a commit, checkout, or lockfile change.
    public let lastActive: Date
    public var bytes: Int64

    public init(path: String, projectName: String, lastActive: Date, bytes: Int64) {
        self.path = path
        self.projectName = projectName
        self.lastActive = lastActive
        self.bytes = bytes
    }

    public func isStale(now: Date, after days: Int) -> Bool {
        now.timeIntervalSince(lastActive) > Double(days) * 86_400
    }
}

public enum NodeModules {
    /// Files whose modification time means someone worked on the project. A directory's own
    /// mtime isn't used: it changes when anything inside is added or removed, including by tools.
    static let activityMarkers = [
        "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb",
    ]
    static let gitMarkers = ["index", "HEAD", "FETCH_HEAD", "logs/HEAD"]

    /// Finds top-level `node_modules` folders under `roots`, without descending into them
    /// or into hidden directories. Sizes are left at zero; measure the ones you show.
    public static func find(in roots: [String], maxDepth: Int = 5) -> [NodeModulesFolder] {
        var found: [NodeModulesFolder] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for root in roots {
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            let rootDepth = rootURL.pathComponents.count
            guard let enumerator = fm.enumerator(
                at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if url.lastPathComponent == "node_modules" {
                    enumerator.skipDescendants()
                    // Overlapping roots (~/github and ~/github/acme) would find it twice.
                    guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                    let project = url.deletingLastPathComponent()
                    found.append(NodeModulesFolder(
                        path: url.path, projectName: project.lastPathComponent,
                        lastActive: lastActive(project: project.path, root: rootURL.path), bytes: 0))
                } else if url.pathComponents.count - rootDepth >= maxDepth {
                    enumerator.skipDescendants()
                }
            }
        }
        return found
    }

    /// Newest activity for a project, looking from the package folder up to its repository
    /// root (or `root`), so a package inside a busy monorepo isn't called idle just because
    /// its own package.json is old. Handles worktrees, where `.git` is a file.
    static func lastActive(project: String, root: String) -> Date {
        let fm = FileManager.default
        func modified(_ path: String) -> Date? {
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        var dates: [Date] = []
        var dir = (project as NSString).standardizingPath
        let stop = (root as NSString).standardizingPath
        while true {
            dates += activityMarkers.compactMap { modified((dir as NSString).appendingPathComponent($0)) }
            if let gitDir = gitDirectory(in: dir) {
                dates += gitMarkers.compactMap { modified((gitDir as NSString).appendingPathComponent($0)) }
                break
            }
            if dir == stop || dir == "/" || !dir.hasPrefix(stop) { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        // No markers at all: fall back to the project folder itself.
        return dates.max() ?? modified(project) ?? .distantPast
    }

    /// The git directory for a working tree: `.git` itself, or where a worktree's `.git` file points.
    static func gitDirectory(in dir: String) -> String? {
        let dotGit = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : (dir as NSString).appendingPathComponent(target)
    }
}
