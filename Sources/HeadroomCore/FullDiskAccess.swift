import Darwin

public enum FullDiskAccess {
    /// Whether this process has Full Disk Access, checked without triggering a prompt.
    /// The TCC database is readable only with Full Disk Access, and a denied open()
    /// on it fails quietly instead of asking the user.
    public static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}
