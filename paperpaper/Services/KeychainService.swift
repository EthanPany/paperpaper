import Foundation
import Security
import os

private let keychainLog = Logger(subsystem: "me.ethanpan.paperpaper", category: "keychain")

enum KeychainKey: String {
    case unsplashAccessKey = "unsplash.accessKey"
    case ollamaAuthHeader = "ollama.authHeader"
    case openAIAPIKey = "openai.apiKey"
}

@MainActor
final class KeychainService {
    static let shared = KeychainService()

    private let service = "me.ethanpan.paperpaper"

    /// The app-group entitlement doubles as a keychain access group on the
    /// data-protection keychain. This is the crux of making secrets persist in
    /// this **sandboxed** app:
    ///
    /// - The plain data-protection keychain needs a provisioning-profile-backed
    ///   access group, which an ad-hoc / locally-signed Blitz build (built with
    ///   `CODE_SIGNING_ALLOWED=NO`) doesn't have → `SecItemAdd` fails with
    ///   `errSecMissingEntitlement` (-34018). That's the original "keys won't
    ///   save."
    /// - The legacy file-based keychain *can* be written by a sandboxed app, but
    ///   only with the system default ACL — attaching a custom `SecAccess` to
    ///   suppress the access prompt makes `SecItemAdd` fail inside the sandbox,
    ///   and even when it works it re-prompts on every re-signed rebuild.
    ///
    /// An app group, by contrast, is a valid keychain access group for the
    /// data-protection keychain *regardless of signing* — the entitlement is
    /// embedded in the (ad-hoc) signature and validated locally. So this path
    /// persists, never prompts, and survives rebuilds, with no Team required.
    /// Properly-signed App Store / TestFlight builds use the exact same path.
    private let accessGroup = "group.me.ethanpan.paperpaper"

    /// Storage domains, tried in order. `dataProtectionGroup` is the correct one
    /// for this sandboxed app; the rest are defensive fallbacks so a secret still
    /// persists if some OS quirk rejects the preferred path. No domain uses a
    /// custom ACL, so none of them trigger the confidential-information prompt.
    private enum Domain: CustomStringConvertible {
        case dataProtectionGroup   // data-protection keychain, app-group access group ← preferred
        case dataProtectionPlain   // data-protection keychain, default access group
        case legacy                // legacy file-based keychain

        var description: String {
            switch self {
            case .dataProtectionGroup: return "dp-group"
            case .dataProtectionPlain: return "dp-plain"
            case .legacy: return "legacy"
            }
        }
    }
    private let domains: [Domain] = [.dataProtectionGroup, .dataProtectionPlain, .legacy]

    private func baseQuery(for key: KeychainKey, _ domain: Domain) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        switch domain {
        case .dataProtectionGroup:
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = accessGroup
        case .dataProtectionPlain:
            q[kSecUseDataProtectionKeychain as String] = true
        case .legacy:
            break
        }
        return q
    }

    func set(_ value: String, for key: KeychainKey, syncable: Bool = false) {
        let data = Data(value.utf8)
        var wroteTo: Domain?
        for domain in domains {
            if writeOnce(data, for: key, syncable: syncable, domain: domain) {
                wroteTo = domain
                break
            }
        }
        guard let wroteTo else {
            keychainLog.error("keychain: every write domain failed for \(key.rawValue, privacy: .public)")
            return
        }
        keychainLog.info("keychain: saved \(key.rawValue, privacy: .public) via \(wroteTo.description, privacy: .public)")
        // NOTE: deliberately NO cross-domain cleanup here. `dataProtectionGroup`
        // and `dataProtectionPlain` are the *same* data-protection keychain —
        // a delete that doesn't pin an access group matches across all of the
        // app's groups, so "cleaning up" the plain domain would delete the item
        // we just wrote under the app group. `get()` reads dataProtectionGroup
        // first anyway, so a stale value in another store can never shadow a
        // fresh one. Explicit `delete(_:)` still clears every domain.
    }

    @discardableResult
    private func writeOnce(_ data: Data, for key: KeychainKey, syncable: Bool, domain: Domain) -> Bool {
        var query = baseQuery(for: key, domain)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrSynchronizable as String] = syncable ? kCFBooleanTrue : kCFBooleanFalse
        // Available after first unlock; never migrates to a new device backup.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            keychainLog.error("keychain add failed (domain=\(domain.description, privacy: .public)) status=\(status, privacy: .public) for \(key.rawValue, privacy: .public)")
        }
        return status == errSecSuccess
    }

    func get(_ key: KeychainKey) -> String? {
        for domain in domains {
            if let v = readOnce(for: key, domain: domain) { return v }
        }
        return nil
    }

    private func readOnce(for key: KeychainKey, domain: Domain) -> String? {
        var query = baseQuery(for: key, domain)
        query[kSecReturnData as String] = true
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: KeychainKey) {
        for domain in domains { deleteOnce(for: key, domain: domain) }
    }

    private func deleteOnce(for key: KeychainKey, domain: Domain) {
        var query = baseQuery(for: key, domain)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
    }
}
