import Foundation

public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Generic per-provider secret storage, routed through `/usr/bin/security`
/// rather than `Security.framework`'s `SecItem*` APIs: CSwapBar is
/// unsandboxed and ad-hoc signed on every build, so an ACL tied to the app's
/// own signature would force a re-prompt after each rebuild. Anchoring to
/// the `security` binary's stable identity avoids that -- the same reason
/// `SwapEngine`'s `MacOSKeychain` shells out instead of linking the
/// framework directly.
public struct ProviderKeychain: Sendable {
    private static let securityPath = "/usr/bin/security"
    /// `security -i` reads stdin with a 4096-byte line buffer.
    private static let stdinLineLimit = 4096 - 64
    private static let notFoundStatus: Int32 = 44
    private static let timeout: TimeInterval = 5

    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func accountName() -> String {
        ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }

    /// The stored secret, or nil when no such item exists.
    public func getPassword() throws -> String? {
        let result = try run(["find-generic-password", "-a", accountName(), "-w", "-s", service])
        if result.status == 0 {
            var out = result.stdout
            if out.hasSuffix("\n") { out.removeLast() }
            return out
        }
        if result.status == Self.notFoundStatus { return nil }
        throw KeychainError(
            description: "security find-generic-password failed (rc=\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
    }

    /// Create or update (`-U`). The hex-encoded secret goes through
    /// `security -i` on stdin so it never shows up in argv; argv only when
    /// the command would overflow the stdin line buffer.
    public func setPassword(_ password: String) throws {
        let hex = Data(password.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \(Self.quote(accountName())) -s \(Self.quote(service)) -X \(hex)\n"
        let result: SubprocessResult
        if command.utf8.count <= Self.stdinLineLimit {
            result = try run(["-i"], stdin: Data(command.utf8))
        } else {
            result = try run(["add-generic-password", "-U", "-a", accountName(), "-s", service, "-X", hex])
        }
        if result.status != 0 {
            throw KeychainError(
                description: "security add-generic-password failed (rc=\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    /// rc 44 (already absent) counts as success.
    public func deletePassword() throws {
        let result = try run(["delete-generic-password", "-a", accountName(), "-s", service])
        if result.status == 0 || result.status == Self.notFoundStatus { return }
        throw KeychainError(
            description: "security delete-generic-password failed (rc=\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
    }

    private func run(_ args: [String], stdin: Data? = nil) throws -> SubprocessResult {
        do {
            return try Subprocess.run(Self.securityPath, args, stdin: stdin, timeout: Self.timeout)
        } catch SubprocessError.timedOut {
            throw KeychainError(description: "security \(args.first ?? "") timed out after \(Int(Self.timeout))s")
        } catch {
            throw KeychainError(description: "security could not run: \(error)")
        }
    }

    /// `security -i` re-parses each line shell-style.
    private static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
