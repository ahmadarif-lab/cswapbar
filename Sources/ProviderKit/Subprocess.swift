import Foundation

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum SubprocessError: Error {
    case timedOut
    case launchFailed(Error)
}

/// Blocking `subprocess.run(..., capture_output=True, timeout=...)`, shared
/// by every provider engine that shells out to `/usr/bin/security` or
/// `/usr/bin/sqlite3` (a copy of `SwapEngine`'s own helper -- that target
/// can't be depended on since its declarations aren't `public`, and it must
/// stay a untouched byte-compatible port of upstream `claude-swap`).
public enum Subprocess {
    /// A child that exits before reading its stdin would otherwise deliver
    /// SIGPIPE to this process, whose default action is to terminate it.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    public static func run(
        _ executable: String,
        _ args: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) throws -> SubprocessResult {
        _ = ignoreSigpipe
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = stdin != nil ? inPipe : FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            throw SubprocessError.launchFailed(error)
        }

        // Drain both pipes while the child runs so a large write can never
        // block it on a full pipe buffer.
        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        DispatchQueue.global().async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }

        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 1)
            throw SubprocessError.timedOut
        }
        group.wait()
        return SubprocessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
