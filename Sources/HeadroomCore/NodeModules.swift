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
        ".git/index", ".git/HEAD", ".git/FETCH_HEAD",
        "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb",
    ]

    /// Finds top-level `node_modules` folders under `roots`, without descending into them
    /// or into hidden directories. Sizes are left at zero; measure the ones you show.
    public static func find(in roots: [String], maxDepth: Int = 5) -> [NodeModulesFolder] {
        var found: [NodeModulesFolder] = []
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
                    let project = url.deletingLastPathComponent()
                    found.append(NodeModulesFolder(
                        path: url.path, projectName: project.lastPathComponent,
                        lastActive: lastActive(project: project.path), bytes: 0))
                } else if url.pathComponents.count - rootDepth >= maxDepth {
                    enumerator.skipDescendants()
                }
            }
        }
        return found
    }

    static func lastActive(project: String) -> Date {
        let fm = FileManager.default
        let dates = activityMarkers.compactMap { marker -> Date? in
            let attrs = try? fm.attributesOfItem(atPath: (project as NSString).appendingPathComponent(marker))
            return attrs?[.modificationDate] as? Date
        }
        // No markers at all: fall back to the project folder itself.
        return dates.max()
            ?? ((try? fm.attributesOfItem(atPath: project))?[.modificationDate] as? Date)
            ?? .distantPast
    }
}
