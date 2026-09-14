import Foundation

enum ShellError: LocalizedError {
    case binaryNotFound(String)
    case nonZeroExit(command: String, code: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "\(name) not found"
        case .nonZeroExit(let command, let code, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) failed (\(code))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        }
    }
}

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Reads a pipe to EOF on a background thread; `data` is complete once
/// `group` has been notified.
private final class PipeDrain: @unchecked Sendable {
    private(set) var data = Data()

    init(_ pipe: Pipe, group: DispatchGroup) {
        DispatchQueue.global().async(group: group) {
            self.data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
    }
}

/// Runs the two external tools the app still uses: `claude` for the warm-up
/// flow and `brew` for self-updates.
actor Shell {
    static let shared = Shell()

    static let searchPath: String = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }()

    private func resolve(_ binary: String) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/\(binary)",
            "/opt/homebrew/bin/\(binary)",
            "/usr/local/bin/\(binary)",
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    @discardableResult
    private func run(_ binary: String, _ args: [String]) async throws -> ProcessResult {
        guard let path = resolve(binary) else { throw ShellError.binaryNotFound(binary) }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Self.searchPath
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let finished = DispatchGroup()
            finished.enter()
            process.terminationHandler = { _ in finished.leave() }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Drain both pipes while the process runs. Reading them only once
            // it exits deadlocks as soon as a command writes more than the
            // pipe buffer holds (~64 KB) -- which `brew update` can.
            let out = PipeDrain(outPipe, group: finished)
            let err = PipeDrain(errPipe, group: finished)
            finished.notify(queue: .global()) {
                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: out.data, encoding: .utf8) ?? "",
                    stderr: String(data: err.data, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    /// Fire-and-forget-ish `claude` invocation used only by the warm-up flow.
    @discardableResult
    func claude(_ args: [String]) async throws -> ProcessResult {
        try await run("claude", args)
    }

    /// Used only by the updater: the app ships as a Homebrew cask, so
    /// updating it is a plain `brew upgrade` of that cask.
    @discardableResult
    func brew(_ args: [String]) async throws -> ProcessResult {
        let result = try await run("brew", args)
        guard result.exitCode == 0 else {
            throw ShellError.nonZeroExit(command: "brew \(args.joined(separator: " "))", code: result.exitCode, output: result.combinedOutput)
        }
        return result
    }
}
