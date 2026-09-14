import Foundation

/// cswap's `ClaudeSwitchError` hierarchy, flattened. The message is what the
/// CLI would have printed after "Error: ".
public enum SwapError: LocalizedError, Equatable {
    case credentialRead(String)
    case credentialWrite(String)
    case credential(String)
    case config(String)
    case switchFailed(String)
    case session(String)
    /// `LockError`, including Claude Code's lock timing out.
    case lock(String)
    case accountNotFound(String)
    case validation(String)

    public var errorDescription: String? {
        switch self {
        case .credentialRead(let m), .credentialWrite(let m), .credential(let m),
             .config(let m), .switchFailed(let m), .session(let m), .lock(let m),
             .accountNotFound(let m), .validation(let m):
            return m
        }
    }

    var isLockError: Bool {
        if case .lock = self { return true }
        return false
    }
}
