import Foundation

/// `security` failed for a reason other than "not found" (locked, denied,
/// timed out, binary missing). cswap's `KEYCHAIN_ERRORS`.
struct KeychainError: Error, CustomStringConvertible {
    let description: String
}

/// `macos_keychain.py`: generic passwords through `/usr/bin/security`, never
/// Security.framework, so items stay readable without a prompt no matter which
/// binary (cswap, Claude Code, this app) wrote them — the ACL anchors to the
/// `security` binary, which never changes.
struct MacOSKeychain {
    static let securityPath = "/usr/bin/security"
    /// `security -i` reads stdin with a 4096-byte line buffer.
    static let stdinLineLimit = 4096 - 64
    static let notFoundStatus: Int32 = 44
    static let timeout: TimeInterval = 5

    let keychainFile: String?
    let env: EngineEnvironment

    /// `keychain_account_name`, mirroring Claude Code's `getUsername()`.
    func accountName() -> String {
        if let user = env.nonEmptyEnv("USER") { return user }
        if let pw = getpwuid(geteuid()), let name = pw.pointee.pw_name {
            return String(cString: name)
        }
        return "claude-code-user"
    }

    private var keychainArgs: [String] { keychainFile.map { [$0] } ?? [] }

    private func run(_ args: [String], stdin: Data? = nil) throws -> SubprocessResult {
        do {
            return try Subprocess.run(Self.securityPath, args, stdin: stdin, timeout: Self.timeout)
        } catch SubprocessError.timedOut {
            throw KeychainError(description: "security \(args.first ?? "") timed out after \(Int(Self.timeout))s")
        } catch {
            throw KeychainError(description: "security could not run: \(error)")
        }
    }

    /// The stored password, or nil when no such item exists (rc 44).
    func getPassword(service: String, account: String) throws -> String? {
        let result = try run(["find-generic-password", "-a", account, "-w", "-s", service] + keychainArgs)
        if result.status == 0 {
            var out = result.stdout
            if out.hasSuffix("\n") { out.removeLast() }
            return out
        }
        if result.status == Self.notFoundStatus { return nil }
        throw KeychainError(description: "security find-generic-password failed (rc=\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Attribute-only lookup: never decrypts, so it can never prompt. False for
    /// "absent" and "could not tell" alike.
    func itemExists(service: String, account: String) -> Bool {
        guard let result = try? run(["find-generic-password", "-a", account, "-s", service] + keychainArgs) else {
            return false
        }
        return result.status == 0
    }

    /// Create or update (`-U`). The hex-encoded secret goes through
    /// `security -i` on stdin so it never shows up in argv; argv only when the
    /// command would overflow the stdin line buffer.
    func setPassword(service: String, account: String, password: String) throws {
        let hex = Data(password.utf8).map { String(format: "%02x", $0) }.joined()
        var command = "add-generic-password -U -a \(Self.quote(account)) -s \(Self.quote(service)) -X \(hex)"
        if let keychainFile { command += " \(Self.quote(keychainFile))" }
        command += "\n"
        let result: SubprocessResult
        if command.utf8.count <= Self.stdinLineLimit {
            result = try run(["-i"], stdin: Data(command.utf8))
        } else {
            result = try run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex] + keychainArgs)
        }
        if result.status != 0 {
            throw KeychainError(description: "security add-generic-password failed (rc=\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// rc 44 (already absent) counts as success.
    func deletePassword(service: String, account: String) throws {
        let result = try run(["delete-generic-password", "-a", account, "-s", service] + keychainArgs)
        if result.status == 0 || result.status == Self.notFoundStatus { return }
        throw KeychainError(description: "security delete-generic-password failed (rc=\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// `security -i` re-parses each line shell-style.
    static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
