import Foundation
import Security

/// Credentials the sandbox cannot obtain for itself.
///
/// Claude Code on macOS keeps its live OAuth token in the Keychain, which a Linux guest
/// cannot read, and the `~/.claude/.credentials.json` left on disk is a stale artefact that
/// will be long expired. arena reads the Keychain on the host, where it is the logged-in
/// user, and writes a current token into the sandbox home.
///
/// This is the one place arena is better than a shell script rather than merely tidier:
/// `security find-generic-password -w` is a subprocess whose failure modes are a status
/// code and an empty string, where `SecItemCopyMatching` returns a typed status this can
/// report on. It is also the reason arena is Swift. See ADR-003.
enum Credentials {
    /// The Keychain service Claude Code stores its OAuth token under.
    static let claudeService = "Claude Code-credentials"

    static func keychainSecret(service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw ArenaError.missingCredentials(
                "no Keychain item for \(service): \(reason)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The host reaches GitHub through `gh auth git-credential` and the Keychain behind it,
    /// neither of which exists in the sandbox. A credentials file plus the store helper is
    /// what lets fetch and push work.
    static func githubToken() -> String? {
        guard let token = try? Shell.run("gh", ["auth", "token"]), !token.isEmpty else {
            return nil
        }
        return token
    }

    /// The public halves GitHub holds as *signing* keys, which are a separate list from
    /// authentication keys: a key registered for auth signs nothing that GitHub will verify.
    /// Nil when the question could not be asked, so a caller can tell "not registered" from
    /// "could not check".
    static func githubSigningKeys() -> [String]? {
        guard let json = try? Shell.run("gh", ["api", "user/ssh_signing_keys", "--jq", ".[].key"])
        else { return nil }
        return
            json
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func githubLogin() -> String {
        (try? Shell.run("gh", ["api", "user", "--jq", ".login"])) ?? "x-access-token"
    }
}
