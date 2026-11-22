import BabyphoneCore
import Foundation
import Security

/// Stores the pairing key in the Keychain of this phone only.
enum PairingKeychain {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "nid.pairing",
        kSecAttrAccount: "pairing-key",
    ]

    static func load() -> PairingKey? {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return PairingKey(rawValue: data)
    }

    @discardableResult
    static func save(_ key: PairingKey) -> Bool {
        delete()
        let item = query.merging([
            kSecValueData: key.rawValue,
            // Readable while the phone is locked, which monitoring needs, and never synced or restored elsewhere.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
