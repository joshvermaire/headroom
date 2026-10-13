import Foundation

/// The size of one category on disk.
public struct SizeReading: Codable, Equatable, Sendable {
    /// Allocated bytes we could read. Sparse files (Docker.raw) count only blocks in use.
    public var bytes: Int64
    /// False when some of the tree couldn't be read, usually for lack of Full Disk Access.
    /// An incomplete measurement is a lower bound, never a zero.
    public var complete: Bool
    /// True when none of the category's paths exist.
    public var missing: Bool

    public init(bytes: Int64, complete: Bool, missing: Bool) {
        self.bytes = bytes
        self.complete = complete
        self.missing = missing
    }
}

public enum Measure {
    /// Total allocated size of `paths`, counting each hard-linked file once and never following symlinks.
    ///
    /// APFS clones share blocks that this can't see, so the total is what the files occupy,
    /// not a promise of how much deleting them frees.
    public static func allocatedSize(of paths: [String], isCancelled: () -> Bool = { false }) -> SizeReading {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .linkCountKey, .fileResourceIdentifierKey,
        ]
        var total: Int64 = 0
        var complete = true
        var anyExists = false
        var seenHardLinks = Set<AnyHashableBox>()

        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            anyExists = true
            let root = URL(fileURLWithPath: path)

            guard isDir.boolValue else {
                if let values = try? root.resourceValues(forKeys: Set(keys)) {
                    total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                } else {
                    complete = false
                }
                continue
            }

            // A directory we can stat but not list (TCC) shows up as an unreadable root.
            if (try? fm.contentsOfDirectory(atPath: path)) == nil {
                complete = false
                continue
            }

            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [],
                errorHandler: { _, _ in
                    complete = false
                    return true
                })
            while let url = enumerator?.nextObject() as? URL {
                if isCancelled() { return SizeReading(bytes: total, complete: false, missing: false) }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    complete = false
                    continue
                }
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }
                if let links = values.linkCount, links > 1, let id = values.fileResourceIdentifier {
                    guard seenHardLinks.insert(AnyHashableBox(id)).inserted else { continue }
                }
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return SizeReading(bytes: total, complete: complete, missing: !anyExists)
    }
}

/// `fileResourceIdentifier` is `(NSCopying & NSSecureCoding & NSObjectProtocol)`; box it for Set.
private struct AnyHashableBox: Hashable {
    let object: NSObject
    init(_ value: Any) { object = value as! NSObject }
    static func == (a: Self, b: Self) -> Bool { a.object.isEqual(b.object) }
    func hash(into hasher: inout Hasher) { hasher.combine(object.hash) }
}
