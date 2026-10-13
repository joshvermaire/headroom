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

    public var path: String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPath { return cachedPath }
        let resolved = Self.loginShellPath() ?? Self.fallbackPath
        cachedPath = resolved
        return resolved
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
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Drain the pipe as we go so a chatty tool can't fill it and block.
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ShellError.timedOut((executable as NSString).lastPathComponent)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return CommandResult(status: process.terminationStatus, output: buffer.string)
    }
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
