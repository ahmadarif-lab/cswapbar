import Foundation

/// The `claude-swap` logger: appends to `<backup>/claude-swap.log` in
/// Python's `%(asctime)s - %(levelname)s - %(message)s` format and rotates at
/// 1 MB keeping three backups, so cswap's and this engine's lines interleave
/// in one file. DEBUG is dropped, like cswap's default level.
final class SwapLog {
    private let logFile: URL
    private let now: () -> Date
    private let lock = NSLock()
    static let maxBytes = 1024 * 1024
    static let backupCount = 3

    init(dir: URL, now: @escaping () -> Date) {
        logFile = dir.appendingPathComponent("claude-swap.log")
        self.now = now
    }

    func debug(_ message: @autoclosure () -> String) {}
    func info(_ message: String) { emit("INFO", message) }
    func warning(_ message: String) { emit("WARNING", message) }
    func error(_ message: String) { emit("ERROR", message) }

    private func emit(_ level: String, _ message: String) {
        let line = "\(TimeFormat.logTimestamp(now())) - \(level) - \(message)\n"
        let data = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        do {
            try FS.mkdirs(logFile.deletingLastPathComponent())
            rotateIfNeeded(adding: data.count)
            if !FS.exists(logFile) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFile)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never fail an operation.
        }
    }

    private func rotateIfNeeded(adding count: Int) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size + count >= Self.maxBytes else { return }
        let fm = FileManager.default
        for i in stride(from: Self.backupCount - 1, through: 1, by: -1) {
            let src = URL(fileURLWithPath: logFile.path + ".\(i)")
            let dst = URL(fileURLWithPath: logFile.path + ".\(i + 1)")
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
        }
        let first = URL(fileURLWithPath: logFile.path + ".1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: logFile, to: first)
    }
}
