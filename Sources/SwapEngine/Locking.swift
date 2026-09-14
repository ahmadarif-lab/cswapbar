import Foundation

/// `locking.FileLock`: an exclusive `flock` on a lock file, polled every
/// 100 ms up to a timeout. Interoperates with cswap's own `fcntl.flock`, and —
/// like it — is not re-entrant: a second instance on the same path blocks
/// even inside one process.
final class FileLock {
    let path: URL
    let timeout: TimeInterval
    private var fd: Int32 = -1

    init(_ path: URL, timeout: TimeInterval = 10) {
        self.path = path
        self.timeout = timeout
    }

    deinit { release() }

    func acquire(timeout: TimeInterval? = nil) -> Bool {
        let limit = timeout ?? self.timeout
        try? FS.mkdirs(path.deletingLastPathComponent())
        fd = open(path.path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard fd >= 0 else { return false }
        let start = Date()
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            if Date().timeIntervalSince(start) > limit {
                close(fd)
                fd = -1
                return false
            }
            usleep(100_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// `with FileLock(...)`.
    func hold<T>(_ body: () throws -> T) throws -> T {
        guard acquire() else {
            throw SwapError.lock("Failed to acquire lock - another instance may be running")
        }
        defer { release() }
        return try body()
    }
}

/// `claude_locks.py`: Claude Code's `proper-lockfile` directory locks, so a
/// credential swap never lands inside Claude Code's own token refresh.
enum ClaudeLocks {
    static let credentialsStaleness: TimeInterval = 60
    static let configStaleness: TimeInterval = 10
    static let touchInterval: TimeInterval = 3
    static let defaultTimeout: TimeInterval = 9

    static func credentialsLockDir(_ paths: Paths) -> URL {
        let home = paths.claudeConfigHome()
        return home.deletingLastPathComponent().appendingPathComponent(home.lastPathComponent + ".lock")
    }

    static func oauthRefreshLockDir(_ paths: Paths) -> URL {
        paths.claudeConfigHome().appendingPathComponent(".oauth_refresh.lock")
    }

    static func configLockDir(_ paths: Paths) -> URL {
        let path = paths.globalConfigPath()
        return path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".lock")
    }

    /// `proper_lockfile`: `mkdir` is the mutex; a holder older than
    /// `staleness` is taken over; the directory mtime is touched while held.
    static func properLockfile<T>(
        _ lockDir: URL,
        timeout: TimeInterval = defaultTimeout,
        staleness: TimeInterval = configStaleness,
        log: SwapLog? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try? FS.mkdirs(lockDir.deletingLastPathComponent())
        let start = Date()
        while true {
            if mkdir(lockDir.path, 0o777) == 0 { break }
            guard errno == EEXIST else {
                throw SwapError.lock("Could not acquire \(lockDir.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            if Date().timeIntervalSince(start) > timeout {
                throw SwapError.lock(
                    "Could not acquire \(lockDir.lastPathComponent) — Claude Code appears to be refreshing credentials. Retry in a few seconds."
                )
            }
            guard let heldMtime = FS.mtime(lockDir) else { continue }
            if Date().timeIntervalSince1970 - heldMtime > staleness {
                if rmdir(lockDir.path) != 0 { usleep(50_000) }
                continue
            }
            usleep(UInt32(250_000 + Double.random(in: 0..<250_000)))
        }

        let toucher = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        toucher.schedule(deadline: .now() + touchInterval, repeating: touchInterval)
        toucher.setEventHandler {
            if utimes(lockDir.path, nil) != 0 { toucher.cancel() }
        }
        toucher.resume()
        defer {
            toucher.cancel()
            if rmdir(lockDir.path) != 0 {
                if errno == ENOENT {
                    log?.warning("Lock \(lockDir.path) vanished while held (taken over as stale?)")
                } else {
                    log?.warning("Failed to release lock \(lockDir.path): \(String(cString: strerror(errno)))")
                }
            }
        }
        return try body()
    }

    /// Claude Code's credential-refresh pair, in its own order: the primary
    /// `.oauth_refresh.lock`, then the legacy `~/.claude.lock`.
    static func credentialsLock<T>(_ paths: Paths, log: SwapLog?, _ body: () throws -> T) throws -> T {
        try properLockfile(oauthRefreshLockDir(paths), staleness: credentialsStaleness, log: log) {
            try properLockfile(credentialsLockDir(paths), staleness: credentialsStaleness, log: log) {
                try body()
            }
        }
    }

    /// Claude Code's global-config write lock (`~/.claude.json.lock`).
    static func configLock<T>(_ paths: Paths, log: SwapLog?, _ body: () throws -> T) throws -> T {
        try properLockfile(configLockDir(paths), staleness: configStaleness, log: log, body)
    }
}
