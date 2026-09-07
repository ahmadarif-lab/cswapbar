import Foundation

enum CswapError: LocalizedError {
    case binaryNotFound(String)
    case nonZeroExit(command: String, code: Int32, output: String)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "\(name) not found. Install with: uv tool install claude-swap"
        case .nonZeroExit(let command, let code, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) failed (\(code))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .decodingFailed(let error):
            return "Couldn't parse cswap output: \(error.localizedDescription)"
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

/// Shells out to the real `cswap` (and `claude`) executables. This app owns
/// no account-switching logic of its own -- every action below is a plain
/// invocation of the original CLI commands.
actor CswapCLI {
    static let shared = CswapCLI()

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
        guard let path = resolve(binary) else { throw CswapError.binaryNotFound(binary) }
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

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @discardableResult
    func cswap(_ args: [String]) async throws -> ProcessResult {
        let result = try await run("cswap", args)
        guard result.exitCode == 0 else {
            throw CswapError.nonZeroExit(command: "cswap \(args.joined(separator: " "))", code: result.exitCode, output: result.combinedOutput)
        }
        return result
    }

    /// Fire-and-forget-ish `claude` invocation used only by the warm-up flow.
    @discardableResult
    func claude(_ args: [String]) async throws -> ProcessResult {
        try await run("claude", args)
    }

    // MARK: - Data

    func list() async throws -> ListResponse {
        let result = try await cswap(["list", "--json"])
        do {
            return try JSONDecoder().decode(ListResponse.self, from: Data(result.stdout.utf8))
        } catch {
            throw CswapError.decodingFailed(error)
        }
    }

    // MARK: - Actions (all real `cswap` subcommands)

    func switchTo(_ target: String) async throws {
        try await cswap(["switch", target])
    }

    func disable(_ number: Int) async throws {
        try await cswap(["disable", String(number)])
    }

    func enable(_ number: Int) async throws {
        try await cswap(["enable", String(number)])
    }

    func remove(_ number: Int) async throws {
        try await cswap(["remove", String(number)])
    }

    /// "Add current login" also doubles as "refresh credentials" when the
    /// email already matches a managed slot -- same as the Python menu bar.
    func addCurrentLogin() async throws {
        try await cswap(["add"])
    }

    func addToken(_ token: String, email: String?) async throws {
        var args = ["add-token", token]
        if let email, !email.isEmpty { args += ["--email", email] }
        try await cswap(args)
    }
}
