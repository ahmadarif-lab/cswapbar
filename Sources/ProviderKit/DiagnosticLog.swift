import Foundation

/// A small file-backed log shared by every provider engine and the app
/// itself. A failed refresh/auto-detect/quota-fetch otherwise only ever
/// surfaces as one line of `error.localizedDescription` in the UI, which is
/// easy to lose (a screenshot, a closed sheet) and often hides an earlier,
/// more telling failure (e.g. which of several OAuth clients was tried).
/// This keeps a timestamped history on disk so a user hitting an
/// intermittent or hard-to-repro failure can send the file instead of
/// re-triggering the bug live.
///
/// Only call `log` for failures or otherwise-invisible branch decisions --
/// not on every successful poll tick -- so the file stays useful instead of
/// drowning in routine noise. Never pass a secret (refresh token, API key,
/// client secret) in `message`; this file is meant to be attached to bug
/// reports.
public enum DiagnosticLog {
    public static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CSwapBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cswapbar.log")
    }()

    private static let queue = DispatchQueue(label: "dev.ahmadarif.cswapbar.diagnosticlog")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    /// Once the log crosses this size, it's trimmed back down to a third of
    /// it -- keeps it useful across long-running sessions without growing
    /// unbounded.
    private static let maxBytes = 2_000_000

    public static func log(_ tag: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)\n"
        queue.async { append(line) }
    }

    /// `error.localizedDescription` on a `LocalizedError` sometimes wraps
    /// its `errorDescription` in extra NSError boilerplate -- this goes
    /// straight to the source so the log stays as readable as what's
    /// already shown in the UI.
    public static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: fileURL) else { return }
        try? data.suffix(maxBytes / 3).write(to: fileURL, options: .atomic)
    }
}
