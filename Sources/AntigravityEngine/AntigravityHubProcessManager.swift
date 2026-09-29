import Darwin
import Foundation
import ProviderKit

private let logTag = "antigravity"

/// Manages a local background `agy --hub` process spawned by CSwapBar when no
/// external hub (e.g. from the Antigravity VS Code extension or an active
/// terminal session) is currently running.
///
/// This allows CSwapBar to retrieve live Antigravity quota completely
/// independently, without requiring VS Code to be open or requiring a paid
/// Google Cloud Gemini Code Assist license.
final class AntigravityHubProcessManager: @unchecked Sendable {
    static let shared = AntigravityHubProcessManager()

    private let lock = NSLock()
    private var process: Process?
    private var managedEndpoint: AntigravityHubEndpoint?

    private init() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.terminate()
        }
    }

    deinit {
        terminate()
    }

    /// Whether the `agy` CLI binary is installed and executable on this system.
    static var isAgyAvailable: Bool {
        findAgyBinary() != nil
    }

    /// Finds the path to the `agy` executable on disk.
    static func findAgyBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "\(home)/.gemini/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("agy").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        if let result = try? Subprocess.run("/usr/bin/which", ["agy"], timeout: 2), result.status == 0 {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private var isProcessRunning: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    private var activeManagedEndpoint: AntigravityHubEndpoint? {
        lock.withLock {
            if let proc = process, proc.isRunning {
                return managedEndpoint
            }
            return nil
        }
    }

    private func setManagedProcess(process: Process, endpoint: AntigravityHubEndpoint) {
        lock.withLock {
            self.process = process
            self.managedEndpoint = endpoint
        }
    }

    /// Ensures an active, responsive `agy --hub` endpoint is available.
    ///
    /// Checks in order:
    /// 1. An already-running external hub (e.g. from VS Code or a CLI session).
    /// 2. Our own previously spawned managed hub process (if still running and healthy).
    /// 3. Spawns a new managed `agy --hub` process and waits for it to respond.
    func ensureRunningHub() async -> AntigravityHubEndpoint? {
        // 1. External hub already running
        if let external = AntigravityHubLocator.findRunningHub() {
            if (try? await AntigravityHubClient.retrieveQuotaSummaryJSON(endpoint: external)) != nil {
                return external
            }
        }

        // 2. Existing managed hub
        if let ep = activeManagedEndpoint {
            if (try? await AntigravityHubClient.retrieveQuotaSummaryJSON(endpoint: ep)) != nil {
                return ep
            }
            // Failed health check -- tear down and recreate
            terminate()
        }

        // 3. Spawn a new background hub
        guard let agyBinary = Self.findAgyBinary() else {
            DiagnosticLog.log(logTag, "cannot auto-spawn hub: agy binary not found")
            return nil
        }

        guard let port = Self.findAvailablePort() else {
            DiagnosticLog.log(logTag, "cannot auto-spawn hub: failed to find available port")
            return nil
        }

        let csrfToken = UUID().uuidString
        let endpoint = AntigravityHubEndpoint(port: port, csrfToken: csrfToken)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agyBinary)
        proc.arguments = [
            "--hub",
            "--hub-port=\(port)",
            "--app_data_dir=antigravity",
            "--csrf_token=\(csrfToken)"
        ]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            DiagnosticLog.log(logTag, "failed to spawn agy hub: \(error)")
            return nil
        }

        setManagedProcess(process: proc, endpoint: endpoint)
        DiagnosticLog.log(logTag, "spawned background agy hub (pid \(proc.processIdentifier), port \(port))")

        let ready = await waitForReadiness(endpoint: endpoint, timeout: 6.0)
        if !ready {
            DiagnosticLog.log(logTag, "spawned agy hub did not respond within timeout")
            terminate()
            return nil
        }

        return endpoint
    }

    /// Stops our managed `agy --hub` process if one was spawned.
    func terminate() {
        let procToKill: Process? = lock.withLock {
            let proc = process
            process = nil
            managedEndpoint = nil
            return proc
        }

        guard let proc = procToKill, proc.isRunning else { return }
        proc.terminate()
        for _ in 0..<10 {
            if !proc.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    private func waitForReadiness(endpoint: AntigravityHubEndpoint, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessRunning { return false }

            if (try? await AntigravityHubClient.retrieveQuotaSummaryJSON(endpoint: endpoint)) != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        }
        return false
    }

    private static func findAvailablePort() -> Int? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var bindAddr = addr
        guard withUnsafePointer(to: &bindAddr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else { return nil }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }) == 0 else { return nil }

        let port = Int(UInt16(bigEndian: addr.sin_port))
        return port > 0 ? port : nil
    }
}
