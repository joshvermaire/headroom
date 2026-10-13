import Foundation

public enum CleanError: LocalizedError {
    case notAllowed(String)
    case commandFailed(tool: String, output: String)
    case partial(failures: [String])

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let path):
            "Refused to delete \(path): it isn't a known cache folder."
        case .commandFailed(let tool, let output):
            "\(tool) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))"
        case .partial(let failures):
            "Some items couldn't be removed: \(failures.prefix(3).joined(separator: ", "))"
                + (failures.count > 3 ? " and \(failures.count - 3) more" : "")
        }
    }
}

/// Carries out clean actions. Deletion is limited to paths named in the catalog or to
/// folders literally called `node_modules`; nothing else can be removed through here.
public enum Cleaner {
    public static func clean(_ category: StorageCategory, shell: Shell = .shared, home: String = NSHomeDirectory()) throws {
        switch category.action {
        case .reveal:
            return
        case .command(let tool, let arguments):
            let result = try shell.run(tool: tool, arguments: arguments)
            guard result.succeeded else { throw CleanError.commandFailed(tool: tool, output: result.output) }
        case .deleteContents(let paths):
            try deleteContents(of: paths.map { Paths.expand($0, home: home) }, allowed: allowedPaths(home: home))
        }
    }

    public static func deleteNodeModules(at path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "node_modules", url.path.split(separator: "/").count >= 3 else {
            throw CleanError.notAllowed(path)
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CleanError.notAllowed(path) }
        try FileManager.default.removeItem(at: url)
    }

    static func allowedPaths(home: String) -> Set<String> {
        var allowed = Set<String>()
        for category in Catalog.all {
            if case .deleteContents(let paths) = category.action {
                paths.forEach { allowed.insert(Paths.expand($0, home: home)) }
            }
        }
        return allowed
    }

    /// Removes every child of each directory. Symlinks inside are removed, never followed.
    static func deleteContents(of directories: [String], allowed: Set<String>) throws {
        let fm = FileManager.default
        var failures: [String] = []
        for dir in directories {
            guard allowed.contains(dir) else { throw CleanError.notAllowed(dir) }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let children: [String]
            do {
                children = try fm.contentsOfDirectory(atPath: dir)
            } catch {
                failures.append(dir)
                continue
            }
            for child in children {
                let path = (dir as NSString).appendingPathComponent(child)
                do {
                    try fm.removeItem(atPath: path)
                } catch {
                    failures.append(path)
                }
            }
        }
        if !failures.isEmpty { throw CleanError.partial(failures: failures) }
    }
}
