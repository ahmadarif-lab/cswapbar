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

    /// Claude Code 2.1.299's choice between `.config.json` and `.claude.json`:
    /// the legacy file wins only as a regular file that is non-empty, or
    /// empty and writable with no `.claude.json` beside it.
    static func pickGlobalConfig(legacy: URL, global: URL) -> URL {
        var st = stat()
        guard stat(legacy.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return global }
        if st.st_size > 0 { return legacy }
        let writable = st.st_mode & 0o222 != 0
        return writable && !FileManager.default.fileExists(atPath: global.path) ? legacy : global
    }

    func globalConfigPath() -> URL {
        let legacy = claudeConfigHome().appendingPathComponent(".config.json")
        let base = env.nonEmptyEnv("CLAUDE_CONFIG_DIR").map { URL(fileURLWithPath: $0) } ?? home
        return Self.pickGlobalConfig(legacy: legacy, global: base.appendingPathComponent(".claude.json"))
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

    /// Where a publish to `url` lands: itself, or the end of its symlink
    /// chain. A rename swaps a directory entry and never follows links, so
    /// renaming onto a symlinked `~/.claude.json` would detach the link.
    static func publishTarget(_ url: URL) -> URL {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return url }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil { return URL(fileURLWithPath: String(cString: buf)) }
        // Dangling link: write where it points.
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return url }
        return dest.hasPrefix("/")
            ? URL(fileURLWithPath: dest)
            : url.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL
    }

    /// `fsutil.atomic_write_bytes`: `mkstemps` beside the target (0600 from
    /// creation), write, `mode` on the descriptor, fsync, rename. A reader
    /// sees the old file or the new one, never a torn one; a failure before
    /// the rename leaves the destination untouched and removes the temp.
    static func atomicWrite(
        _ data: Data, to destination: URL, suffix: String = ".tmp", prefix: String = "tmp",
        mode: mode_t = 0o600, followSymlinks: Bool = true
    ) throws {
        let target = followSymlinks ? publishTarget(destination) : destination
        let dir = target.deletingLastPathComponent()
        try mkdirs(dir)
        var template = Array((dir.path + "/" + String(prefix.prefix(40)) + "XXXXXXXX" + suffix).utf8CString)
        let fd = mkstemps(&template, Int32(suffix.utf8.count))
        guard fd >= 0 else { throw posixError(dir) }
        let tmpPath = String(cString: template)
        var ok = false
        var open = true
        defer {
            if open { close(fd) }
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
        guard written == data.count else { throw posixError(dir) }
        guard fchmod(fd, mode) == 0 else { throw posixError(target) }
        // Filesystems without fsync answer one of these; anything else (EIO) is real.
        if fsync(fd) != 0, ![EINVAL, ENOTSUP, ENOSYS].contains(errno) { throw posixError(target) }
        close(fd)
        open = false
        if Darwin.rename(tmpPath, target.path) != 0 { throw posixError(target) }
        ok = true
    }

    static func atomicWrite(_ text: String, to destination: URL, followSymlinks: Bool = true) throws {
        try atomicWrite(Data(text.utf8), to: destination, followSymlinks: followSymlinks)
    }

    static func samefile(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        return stat(a, &x) == 0 && stat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
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
