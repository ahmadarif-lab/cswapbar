import Foundation
import ProviderKit

private let logTag = "kiro"

public enum KiroEngineError: LocalizedError, Equatable {
    case notInstalled
    case notSignedIn
    case process(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The kiro-cli CLI wasn't found -- install Kiro CLI to read its monthly credits."
        case .notSignedIn:
            return "kiro-cli isn't signed in. Run `kiro-cli login` in a terminal."
        case .process(let message):
            return "kiro-cli failed: \(message)"
        case .decoding(let message):
            return "Could not read kiro-cli's usage report: \(message)"
        }
    }
}

/// Public façade for Kiro's monthly credit pool, mirroring `OpenCodeGoEngine`
/// -- but where OpenCode Go reads a credential file, this reads the CLI's own
/// `/usage` report, so a Kiro install already signed in shows up on its own
/// with nothing to paste.
///
/// There is no warm-up: Kiro's credits refill on a monthly date rather than
/// on a rolling 5-hour window, so there's nothing a throwaway message could
/// start.
public final class KiroEngine: @unchecked Sendable {
    public static let shared = KiroEngine()

    /// The resolved `kiro-cli` executable, for the Settings page's status
    /// line. Re-resolved on every call, so installing the CLI while CSwapBar
    /// is open is picked up without a relaunch.
    public var binaryPath: String? { KiroCLI.findBinary() }
    public var isInstalled: Bool { binaryPath != nil }

    public func currentUsage() async throws -> KiroUsageSummary {
        try await Task.detached(priority: .utility) { [self] in
            try currentUsageSync()
        }.value
    }

    /// Blocking -- the caller runs it off the main actor.
    func currentUsageSync() throws -> KiroUsageSummary {
        guard let binary = binaryPath else { throw KiroEngineError.notInstalled }
        do {
            let report = try KiroCLI.usageReport(binary: binary)
            // Clean up before parsing: the session exists either way, and a
            // report we can't read shouldn't also leave litter behind.
            if let sessionID = report.sessionID { KiroCLI.deleteSession(sessionID, binary: binary) }
            try ensureSignedIn(report.text)
            return try KiroUsageParsing.summarize(report.text)
        } catch let error as KiroEngineError {
            DiagnosticLog.log(logTag, "usage fetch failed: \(DiagnosticLog.describe(error))")
            throw error
        } catch {
            let message = DiagnosticLog.describe(error)
            DiagnosticLog.log(logTag, "usage fetch failed: \(message)")
            throw KiroEngineError.process(message)
        }
    }

    /// A signed-out `/usage` is answered with prose rather than a report, so
    /// that case is named here instead of surfacing as a parse failure.
    private func ensureSignedIn(_ text: String) throws {
        let lower = text.lowercased()
        let hints = ["not logged in", "not signed in", "please log in", "please login", "kiro-cli login", "run `kiro-cli login`"]
        if hints.contains(where: { lower.contains($0) }) { throw KiroEngineError.notSignedIn }
    }
}
