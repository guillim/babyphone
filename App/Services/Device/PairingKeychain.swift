import BabyphoneCore
import Foundation
import Security

/// Stores the pairing keys in the Keychain of this device only.
///
/// A parent unit holds one key. A baby unit holds one per paired parent unit.
enum PairingKeychain {
    private static var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "nid.pairing",
            kSecAttrAccount: "pairing-keys",
        ]
    }

    static func load() -> [PairingKey] {
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return []
        }
        // The keys are stored end to end, each the same length.
        return stride(from: 0, to: data.count, by: PairingKey.byteCount).compactMap { offset in
            PairingKey(rawValue: data.subdata(in: offset..<min(data.count, offset + PairingKey.byteCount)))
        }
    }

    @discardableResult
    static func save(_ keys: [PairingKey]) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !keys.isEmpty else { return true }
        let item = query.merging([
            kSecValueData: keys.reduce(into: Data()) { $0.append($1.rawValue) },
            // Readable while the device is locked, which monitoring needs, and never synced or restored elsewhere.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
