import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }
}

public enum ShellError: LocalizedError {
    case toolNotFound(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): "Couldn't find \(tool) on your PATH."
        case .timedOut(let tool): "\(tool) didn't finish in time."
        }
    }
}

/// Runs developer tools the way Terminal would find them.
///
/// Apps launched from Finder get a bare PATH (/usr/bin:/bin:...), so `npm` from nvm or
/// `brew` from /opt/homebrew aren't visible. We ask the user's login shell for its PATH once.
public final class Shell: @unchecked Sendable {
    public static let shared = Shell()

    private let lock = NSLock()
    private var cachedPath: String?
    private var lastFailedLookup: Date?

    /// The login shell's PATH. Resolved outside the lock so a slow ~/.zshrc can't block
    /// other callers; a failed lookup falls back for now and is retried after a while.
    public var path: String {
        let shouldResolve: Bool = lock.withLock {
            if cachedPath != nil { return false }
            if let failed = lastFailedLookup, Date().timeIntervalSince(failed) < 600 { return false }
            return true
        }
        if shouldResolve {
            let resolved = Self.loginShellPath()
            lock.withLock {
                if let resolved { cachedPath = resolved } else { lastFailedLookup = Date() }
            }
        }
        return lock.withLock { cachedPath } ?? Self.fallbackPath
    }

    static let fallbackPath = [
        "/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.cargo/bin",
        "\(NSHomeDirectory())/.bun/bin", "\(NSHomeDirectory())/.local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")

    /// Interactive login shell, so ~/.zshrc (where nvm usually lives) runs too.
    /// Markers fence the PATH from anything the rc files print.
    static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = try? run(
            executable: shell, arguments: ["-ilc", "printf '__HEADROOM__%s__HEADROOM__' \"$PATH\""],
            environment: ["HOME": NSHomeDirectory(), "TERM": "dumb"], timeout: 10)
        guard let output = result?.output,
              let start = output.range(of: "__HEADROOM__"),
              let end = output.range(of: "__HEADROOM__", range: start.upperBound..<output.endIndex)
        else { return nil }
        let path = String(output[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    public func locate(_ tool: String) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func run(tool: String, arguments: [String], timeout: TimeInterval = 600) throws -> CommandResult {
        guard let executable = locate(tool) else { throw ShellError.toolNotFound(tool) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return try Self.run(executable: executable, arguments: arguments, environment: env, timeout: timeout)
    }

    static func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        // Some tools (Yarn 2+) refuse to run from "/", which is where a GUI app starts.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = pipe.fileHandleForReading

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        // Our copy of the write end must close, or reads never see EOF.
        try? pipe.fileHandleForWriting.close()

        // One thread owns the read end: it drains as output arrives (so a chatty tool can't
        // fill the pipe and block) and stops at EOF or once told the process is gone.
        let buffer = OutputBuffer()
        let stop = StopFlag()
        let drained = DispatchSemaphore(value: 0)
        let fd = reader.fileDescriptor
        Thread.detachNewThread {
            drain(fd: fd, into: buffer, stop: stop)
            drained.signal()
        }

        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            // zsh -i ignores SIGTERM, so follow up with SIGKILL.
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
        }

        // Don't wait for EOF: a background child the tool started may hold the pipe open
        // indefinitely. Take what's already there, then close our end so such a child gets
        // EPIPE instead of blocking on a full pipe.
        stop.set()
        drained.wait()
        try? reader.close()

        if timedOut { throw ShellError.timedOut((executable as NSString).lastPathComponent) }
        return CommandResult(status: process.terminationStatus, output: buffer.string)
    }
}

/// Reads `fd` until EOF, or until `stop` is set and nothing more is immediately readable.
/// Gives up one second after `stop` regardless, in case a leftover child keeps writing.
private func drain(fd: Int32, into buffer: OutputBuffer, stop: StopFlag) {
    var chunk = [UInt8](repeating: 0, count: 65_536)
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        if let stoppedAt = stop.setAt, Date().timeIntervalSince(stoppedAt) > 1 { return }
        let ready = poll(&pfd, 1, 100)
        if ready > 0 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(Data(chunk[0..<n]))
        } else if ready == 0 {
            if stop.setAt != nil { return }
        } else if errno != EINTR {
            return
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?
    func set() { lock.withLock { date = Date() } }
    var setAt: Date? { lock.withLock { date } }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
