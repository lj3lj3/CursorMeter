import CommonCrypto
import Foundation
import Security
import SQLite3

/// Holds the safeStorage key for the process lifetime so the Keychain is read
/// at most once. NSLock-guarded: refreshes can decrypt off the MainActor.
private final class SafeStorageKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func store(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        cached = value
    }
}

/// Credential synthesized from the Cursor IDE's own auth state (#54).
struct IDECredential: Sendable, Equatable {
    let cookieHeader: String   // "WorkosCursorSessionToken=<id>%3A%3A<jwt>"
    let expiresAt: Date
}

/// Why the IDE credential chain produced nothing.
///
/// Surfaced in the UI: without it a dead chain is invisible — the popover keeps
/// rendering the last good numbers, which look plausible right up until they
/// are days out of date.
enum IDECredentialFailure: String, Sendable, CaseIterable {
    case dbMissing
    case notSignedIn
    case undecryptable
    case expired

    var message: String {
        switch self {
        case .dbMissing:
            "Cursor's sign-in data was not found — is Cursor installed?"
        case .notSignedIn:
            "Cursor is not signed in — sign in inside the Cursor app."
        case .undecryptable:
            "Cursor's saved session is encrypted and could not be read. Allow Keychain access, or sign in to Cursor again."
        case .expired:
            "Cursor's session has expired — sign in to Cursor again."
        }
    }
}

/// Last failure recorded by `read()`. `read()` runs off the MainActor.
private final class CredentialFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: IDECredentialFailure?

    var value: IDECredentialFailure? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: IDECredentialFailure?) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }
}

/// Reads the Cursor IDE's access token from its local state DB and synthesizes
/// the dashboard cookie header (CodexBar's production-proven pattern). The IDE
/// refreshes this token itself, so re-reading per refresh yields a credential
/// that tracks the IDE's live session. Read-only; never touches refreshToken.
///
/// Concurrency: no stored sqlite3 handle — open/query/close within a single
/// read() call, so plain Sendable holds. busy_timeout can block ~250ms;
/// callers invoke off the MainActor.
struct CursorAppAuthReader: Sendable {
    let dbPath: String

    init(dbPath: String = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb") {
        self.dbPath = dbPath
    }

    func read(now: Date = Date()) -> IDECredential? {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            Self.recordFailure(.dbMissing)
            return nil
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            Self.recordFailure(.dbMissing)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
            -1, &stmt, nil) == SQLITE_OK
        else {
            Self.recordFailure(.dbMissing)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0)
        else {
            Self.recordFailure(.notSignedIn)
            return nil
        }
        // Value may be stored as a bare string or JSON-quoted.
        let stored = String(cString: cString).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        // Recent Cursor builds encrypt this with Electron safeStorage, so the
        // column is no longer a JWT. Decrypt before parsing; older builds
        // stored it in the clear and pass through untouched.
        guard let jwt = Self.decryptIfNeeded(stored) else {
            Self.recordFailure(.undecryptable)
            return nil
        }

        guard let claims = Self.parseJWTClaims(jwt) else {
            Self.recordFailure(.undecryptable)
            return nil
        }
        guard claims.exp > now.addingTimeInterval(60),
              let userID = Self.userID(fromSub: claims.sub)
        else {
            Self.recordFailure(.expired)
            return nil
        }

        Self.recordFailure(nil)
        return IDECredential(
            cookieHeader: Self.makeCookieHeader(userID: userID, jwt: jwt),
            expiresAt: claims.exp
        )
    }

    // MARK: - Failure reporting

    /// Why the most recent `read()` failed; nil once one succeeds.
    nonisolated static var lastFailure: IDECredentialFailure? { failureBox.value }

    private static let failureBox = CredentialFailureBox()

    nonisolated static func recordFailure(_ failure: IDECredentialFailure?) {
        failureBox.store(failure)
    }

    // MARK: - Electron safeStorage

    /// Marker Cursor puts on state values encrypted with Electron safeStorage.
    nonisolated static let safeStoragePrefix = "cursor-safe-storage:v1:"

    /// Passes a plaintext value through untouched; decrypts a safeStorage blob.
    nonisolated static func decryptIfNeeded(_ value: String) -> String? {
        value.hasPrefix(safeStoragePrefix) ? decryptSafeStorage(value) : value
    }

    /// Decrypts an Electron safeStorage value, which is Chromium's OSCrypt
    /// format: a `"v10"` prefix followed by AES-128-CBC ciphertext, with a
    /// fixed all-space IV and a PBKDF2-SHA1 key derived from the
    /// "Cursor Safe Storage" Keychain item.
    ///
    /// The trap worth writing down: the Keychain item holds the key as a
    /// base64 **string**, and PBKDF2 consumes the bytes of that string — not
    /// the decoded bytes. Feeding the decoded 16 bytes yields output of the
    /// right length that is nevertheless garbage, so the mistake is silent
    /// rather than loud.
    nonisolated static func decryptSafeStorage(_ value: String) -> String? {
        guard let blob = Data(base64Encoded: String(value.dropFirst(safeStoragePrefix.count))),
              blob.count > 3,
              blob.prefix(3) == Data("v10".utf8),
              let keychainText = safeStorageKey()
        else { return nil }

        let password = Array(keychainText.utf8).map { CChar(bitPattern: $0) }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        guard CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key, key.count
        ) == kCCSuccess else { return nil }

        let ciphertext = blob.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)   // Chromium's fixed IV
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = ciphertext.withUnsafeBytes { body in
            // PKCS7 on decrypt strips the padding block. Leaving it at 0 keeps
            // trailing padding bytes glued to the JWT — the token still parses
            // (the claims segment is intact), but the cookie is rejected with
            // 403 on every request, which reads as an auth problem.
            CCCrypt(CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    key, key.count,
                    iv,
                    body.baseAddress, body.count,
                    &out, out.count,
                    &moved)
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: out.prefix(moved), encoding: .utf8)
    }

    /// The base64 string Electron keeps in the Keychain. Returned as text, not
    /// decoded bytes — see `decryptSafeStorage`.
    ///
    /// Cached after the first read: the Keychain item is owned by Cursor, so
    /// our access can raise an authorization prompt. Paying that once per
    /// launch keeps background refreshes silent — a measured read took 25s
    /// while the prompt was pending.
    nonisolated static func safeStorageKey() -> String? {
        if let cached = keyCache.value { return cached }
        guard let text = readSafeStorageKey() else { return nil }
        keyCache.store(text)
        return text
    }

    private static let keyCache = SafeStorageKeyCache()

    private nonisolated static func readSafeStorageKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecAttrAccount as String: "Cursor Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pure helpers

    nonisolated static func parseJWTClaims(_ jwt: String) -> (sub: String, exp: Date)? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let exp = json["exp"] as? TimeInterval
        else { return nil }
        return (sub, Date(timeIntervalSince1970: exp))
    }

    /// WorkOS subs look like "auth0|user_xxx" — the dashboard cookie wants the
    /// part after the last pipe.
    nonisolated static func userID(fromSub sub: String) -> String? {
        guard let idx = sub.lastIndex(of: "|"), idx < sub.index(before: sub.endIndex)
        else { return nil }
        return String(sub[sub.index(after: idx)...])
    }

    nonisolated static func makeCookieHeader(userID: String, jwt: String) -> String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(jwt)"
    }
}
