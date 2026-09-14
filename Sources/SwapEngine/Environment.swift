import Foundation

/// Everything the engine touches outside its own memory. `live()` is the
/// real machine; tests swap in a sandbox home, a throwaway keychain file and a
/// fake network.
struct EngineEnvironment {
    var homeDir: String
    var env: [String: String]
    /// A keychain file every `security` call is pointed at; nil means the
    /// user's default keychain search list, exactly like cswap.
    var keychainFile: String?
    var http: HTTPClient
    var now: () -> Date

    static func live() -> EngineEnvironment {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return EngineEnvironment(
            homeDir: home,
            env: env,
            keychainFile: nil,
            http: URLSessionHTTPClient(),
            now: Date.init
        )
    }

    func envValue(_ key: String) -> String? { env[key] }

    /// `os.environ.get(key)` that treats "" as unset, for the call sites that
    /// test truthiness.
    func nonEmptyEnv(_ key: String) -> String? {
        guard let v = env[key], !v.isEmpty else { return nil }
        return v
    }

    var epoch: Double { now().timeIntervalSince1970 }
}

/// `paths.py`: the files Claude Code and cswap read and write.
struct Paths {
    let env: EngineEnvironment

    var home: URL { URL(fileURLWithPath: env.homeDir, isDirectory: true) }

    func claudeConfigHome() -> URL {
        if let v = env.nonEmptyEnv("CLAUDE_CONFIG_DIR") { return URL(fileURLWithPath: v) }
        return home.appendingPathComponent(".claude")
    }

    func globalConfigPath() -> URL {
        let legacy = claudeConfigHome().appendingPathComponent(".config.json")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        let base = env.nonEmptyEnv("CLAUDE_CONFIG_DIR").map { URL(fileURLWithPath: $0) } ?? home
        return base.appendingPathComponent(".claude.json")
    }

    func defaultClaudeConfigHome() -> URL { home.appendingPathComponent(".claude") }

    func credentialsPath() -> URL { claudeConfigHome().appendingPathComponent(".credentials.json") }

    /// macOS keeps the legacy (pre-XDG) location.
    func backupRoot() -> URL { home.appendingPathComponent(".claude-swap-backup") }
}

enum FS {
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func mkdirs(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func chmod(_ url: URL, _ mode: mode_t) throws {
        if Darwin.chmod(url.path, mode) != 0 { throw posixError(url) }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        return s
    }

    /// `Path.write_text`: truncate-and-write in place (not atomic).
    static func writeText(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    static func unlinkIfPresent(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT { throw posixError(url) }
    }

    static func rename(_ from: URL, _ to: URL) throws {
        if Darwin.rename(from.path, to.path) != 0 { throw posixError(from) }
    }

    /// `tempfile.mkstemp(dir=..., suffix=...)` + write + `os.replace` +
    /// chmod 0600: the atomic writer every cswap store shares.
    static func atomicWrite(_ data: Data, to target: URL, suffix: String = ".tmp", prefix: String = "tmp") throws {
        let dir = target.deletingLastPathComponent()
        try mkdirs(dir)
        var template = Array((dir.path + "/" + prefix + "XXXXXXXX" + suffix).utf8CString)
        let fd = mkstemps(&template, Int32(suffix.utf8.count))
        guard fd >= 0 else { throw posixError(dir) }
        let tmpPath = String(cString: template)
        var ok = false
        defer {
            if !ok { unlink(tmpPath) }
        }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var off = 0
            while off < buf.count {
                let n = write(fd, base.advanced(by: off), buf.count - off)
                if n <= 0 { return -1 }
                off += n
            }
            return off
        }
        close(fd)
        guard written == data.count else { throw posixError(dir) }
        if Darwin.rename(tmpPath, target.path) != 0 { throw posixError(target) }
        ok = true
        try chmod(target, 0o600)
    }

    static func mtime(_ url: URL) -> Double? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    static func posixError(_ url: URL) -> Error {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(String(cString: strerror(code))): \(url.path)",
        ])
    }
}
