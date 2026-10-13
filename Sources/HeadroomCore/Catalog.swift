import Foundation

/// Whether a category can be cleared without thinking about it.
public enum Safety: String, Codable, Sendable {
    /// Caches that tools rebuild or re-download on demand.
    case safe
    /// Data that may matter (containers, simulators, backups). Always confirm, sometimes reveal-only.
    case review
}

/// What "Clean" does for a category.
public enum CleanAction: Equatable, Sendable {
    /// Run the owning tool's own cleanup command, e.g. `brew cleanup --prune=all`.
    /// `tool` is resolved against the user's login-shell PATH.
    case command(tool: String, arguments: [String])
    /// Remove everything inside these directories, keeping the directories themselves.
    case deleteContents([String])
    /// Nothing automatic. Show the folder in Finder so the user decides.
    case reveal

    public var isDestructive: Bool {
        if case .reveal = self { return false }
        return true
    }
}

public struct CleanPreview: Equatable, Sendable {
    public let tool: String
    public let arguments: [String]
    public let heading: String
}

public struct StorageCategory: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// One plain sentence shown under the name: what this is and what cleaning does.
    public let detail: String
    /// Paths measured for this category. A leading `~` means the home directory.
    public let paths: [String]
    public let safety: Safety
    public let action: CleanAction
    /// Short button verb, e.g. "Clean", "Prune", "Show".
    public let actionTitle: String
    /// Command whose output lists what the action will remove, shown in the confirmation.
    public let preview: CleanPreview?
    /// Lives somewhere macOS privacy protects (another app's container, Downloads, Trash).
    /// Touching it without Full Disk Access either fails or pops a consent prompt that
    /// blocks the scan, so these are skipped until access is granted.
    public let requiresFullDiskAccess: Bool
    /// Whether the action removes everything measured. Prune-style commands keep what's
    /// still in use, so the UI must not promise the full size back.
    public let clearsEverything: Bool

    public init(
        id: String, name: String, detail: String, paths: [String],
        safety: Safety, action: CleanAction, actionTitle: String? = nil, preview: CleanPreview? = nil,
        requiresFullDiskAccess: Bool = false, clearsEverything: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.paths = paths
        self.safety = safety
        self.action = action
        self.actionTitle = actionTitle ?? (action.isDestructive ? "Clean" : "Show")
        self.preview = preview
        self.requiresFullDiskAccess = requiresFullDiskAccess
        if let clearsEverything {
            self.clearsEverything = clearsEverything
        } else if case .deleteContents = action {
            self.clearsEverything = true
        } else {
            self.clearsEverything = false
        }
    }

    public func expandedPaths(home: String = NSHomeDirectory()) -> [String] {
        paths.map { Paths.expand($0, home: home) }
    }
}

public enum Paths {
    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

public enum Catalog {
    public static let all: [StorageCategory] = [
        // MARK: Safe: rebuilt on demand
        StorageCategory(
            id: "xcode-derived-data", name: "Xcode DerivedData",
            detail: "Build products and indexes. Xcode rebuilds them on the next build.",
            paths: ["~/Library/Developer/Xcode/DerivedData"],
            safety: .safe, action: .deleteContents(["~/Library/Developer/Xcode/DerivedData"])),
        StorageCategory(
            id: "xcode-device-support", name: "Xcode device support",
            detail: "Symbol files for devices you've connected. Re-copied when a device connects.",
            paths: [
                "~/Library/Developer/Xcode/iOS DeviceSupport",
                "~/Library/Developer/Xcode/watchOS DeviceSupport",
                "~/Library/Developer/Xcode/tvOS DeviceSupport",
                "~/Library/Developer/Xcode/visionOS DeviceSupport",
            ],
            safety: .safe, action: .deleteContents([
                "~/Library/Developer/Xcode/iOS DeviceSupport",
                "~/Library/Developer/Xcode/watchOS DeviceSupport",
                "~/Library/Developer/Xcode/tvOS DeviceSupport",
                "~/Library/Developer/Xcode/visionOS DeviceSupport",
            ])),
        StorageCategory(
            id: "simulator-caches", name: "Simulator caches",
            detail: "Dyld and runtime caches. Regenerated when a simulator boots.",
            paths: ["~/Library/Developer/CoreSimulator/Caches"],
            safety: .safe, action: .deleteContents(["~/Library/Developer/CoreSimulator/Caches"])),
        StorageCategory(
            id: "npm", name: "npm cache",
            detail: "Downloaded package tarballs. npm re-downloads what it needs.",
            paths: ["~/.npm/_cacache"],
            safety: .safe, action: .command(tool: "npm", arguments: ["cache", "clean", "--force"]),
            clearsEverything: true),
        StorageCategory(
            id: "pnpm", name: "pnpm store",
            detail: "Shared package store. Prune removes packages no project references.",
            paths: ["~/Library/pnpm/store"],
            safety: .safe, action: .command(tool: "pnpm", arguments: ["store", "prune"]),
            actionTitle: "Prune"),
        StorageCategory(
            id: "bun", name: "Bun cache",
            detail: "Downloaded packages. Bun re-downloads what it needs.",
            paths: ["~/.bun/install/cache"],
            safety: .safe, action: .command(tool: "bun", arguments: ["pm", "cache", "rm"]),
            clearsEverything: true),
        StorageCategory(
            id: "yarn", name: "Yarn cache",
            detail: "Downloaded packages. Yarn re-downloads what it needs.",
            paths: ["~/Library/Caches/Yarn"],
            safety: .safe, action: .command(tool: "yarn", arguments: ["cache", "clean"]),
            clearsEverything: true),
        StorageCategory(
            id: "uv", name: "uv cache",
            detail: "Python wheels and builds. Existing virtualenvs keep working.",
            paths: ["~/.cache/uv"],
            safety: .safe, action: .command(tool: "uv", arguments: ["cache", "clean"]),
            clearsEverything: true),
        StorageCategory(
            id: "pip", name: "pip cache",
            detail: "Downloaded Python wheels. pip re-downloads what it needs.",
            paths: ["~/Library/Caches/pip"],
            safety: .safe, action: .command(tool: "pip3", arguments: ["cache", "purge"]),
            clearsEverything: true),
        StorageCategory(
            id: "gradle", name: "Gradle caches",
            detail: "Dependencies and build caches. The next Gradle build re-downloads them.",
            paths: ["~/.gradle/caches"],
            safety: .safe, action: .deleteContents(["~/.gradle/caches"])),
        StorageCategory(
            id: "cargo", name: "Cargo registry",
            detail: "Downloaded crates and sources. Cargo re-downloads what it needs.",
            paths: ["~/.cargo/registry/cache", "~/.cargo/registry/src"],
            safety: .safe, action: .deleteContents(["~/.cargo/registry/cache", "~/.cargo/registry/src"])),
        StorageCategory(
            id: "go", name: "Go module cache",
            detail: "Downloaded modules. Go re-downloads what it needs.",
            paths: ["~/go/pkg/mod"],
            safety: .safe, action: .command(tool: "go", arguments: ["clean", "-modcache"]),
            clearsEverything: true),
        StorageCategory(
            id: "homebrew", name: "Homebrew cache",
            detail: "Downloads and outdated versions of installed packages. Current and pinned versions stay.",
            paths: ["~/Library/Caches/Homebrew"],
            safety: .safe, action: .command(tool: "brew", arguments: ["cleanup", "--prune=all"])),
        StorageCategory(
            id: "cocoapods", name: "CocoaPods cache",
            detail: "Downloaded pods. Re-downloaded on the next pod install.",
            paths: ["~/Library/Caches/CocoaPods"],
            safety: .safe, action: .deleteContents(["~/Library/Caches/CocoaPods"])),

        // MARK: Review first
        StorageCategory(
            id: "docker", name: "Docker",
            detail: "Docker Desktop's disk image. Prune removes stopped containers, unused networks, dangling images, and build cache. Volumes are kept.",
            paths: ["~/Library/Containers/com.docker.docker/Data/vms"],
            safety: .review, action: .command(tool: "docker", arguments: ["system", "prune", "--force"]),
            actionTitle: "Prune",
            preview: CleanPreview(
                tool: "docker",
                arguments: ["ps", "--all", "--filter", "status=exited", "--filter", "status=created", "--format", "{{.Names}}  ({{.Image}})"],
                heading: "Stopped containers that will be deleted:"),
            requiresFullDiskAccess: true),
        StorageCategory(
            id: "simulators", name: "iOS Simulators",
            detail: "Simulator devices and their app data. Clean deletes only simulators for runtimes that are no longer installed.",
            paths: ["~/Library/Developer/CoreSimulator/Devices"],
            safety: .review, action: .command(tool: "xcrun", arguments: ["simctl", "delete", "unavailable"]),
            preview: CleanPreview(
                tool: "xcrun", arguments: ["simctl", "list", "devices", "unavailable"],
                heading: "Unavailable simulators that will be deleted:")),
        StorageCategory(
            id: "xcode-archives", name: "Xcode archives",
            detail: "App archives and their dSYMs. You may need them to symbolicate crashes.",
            paths: ["~/Library/Developer/Xcode/Archives"],
            safety: .review, action: .reveal),
        StorageCategory(
            id: "ios-backups", name: "iPhone and iPad backups",
            detail: "Local device backups. Manage them in Finder under the device.",
            paths: ["~/Library/Application Support/MobileSync/Backup"],
            safety: .review, action: .reveal, requiresFullDiskAccess: true),
        StorageCategory(
            id: "agent-data", name: "Coding agent data",
            detail: "Sessions, logs, and worktrees from Codex, Claude Code, and T3.",
            paths: ["~/.codex", "~/.claude", "~/.t3"],
            safety: .review, action: .reveal),
        StorageCategory(
            id: "trash", name: "Trash",
            detail: "Files you've already deleted. Emptying the Trash can't be undone.",
            paths: ["~/.Trash"],
            safety: .review, action: .deleteContents(["~/.Trash"]), actionTitle: "Empty",
            requiresFullDiskAccess: true),
        StorageCategory(
            id: "downloads", name: "Downloads",
            detail: "Your Downloads folder. Sort by size in Finder to find old installers.",
            paths: ["~/Downloads"],
            safety: .review, action: .reveal, requiresFullDiskAccess: true),
    ]

    public static func category(id: String) -> StorageCategory? {
        all.first { $0.id == id }
    }
}
