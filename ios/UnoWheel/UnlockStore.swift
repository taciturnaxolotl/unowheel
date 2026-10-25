import Foundation
import OnewheelKit
import Security

/// Unlock responses per board, kept in the Keychain. A Hydrus board's
/// challenge never changes, so one response works for the life of the board.
struct UnlockEntry: Codable, Equatable {
    var challenge: String?
    var response: String
    var savedAt: Date
}

enum UnlockStore {
    private static let service = "sh.dunkirk.unowheel.unlock"

    static func entry(for board: String) -> UnlockEntry? {
        read(UnlockEntry.self, account: board)
    }

    static func response(for board: String, challenge: Challenge?) -> Data? {
        guard let entry = entry(for: board), let response = Handshake.parseHex(entry.response) else { return nil }
        if let challenge, let saved = entry.challenge, saved != challenge.hex { return nil }
        return response
    }

    static func save(_ response: Data, challenge: Challenge?, for board: String) {
        write(UnlockEntry(challenge: challenge?.hex, response: response.hexString, savedAt: .now), account: board)
    }

    static func remove(for board: String) {
        SecItemDelete(baseQuery(board) as CFDictionary)
    }

    /// Shared by every board, so it gets its own account.
    static var pushIdentity: PushIdentity? {
        get { read(PushIdentity.self, account: "~push-identity") }
        set { write(newValue, account: "~push-identity") }
    }

    private static func read<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Replaces the item; nil deletes it.
    private static func write<T: Encodable>(_ value: T?, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.lowercased(),
        ]
    }
}

/// Boards we've connected to before, so the app can reconnect without a scan.
enum KnownBoards {
    private static let key = "knownBoards"

    static var all: [String: UUID] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            return raw.compactMapValues(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue.mapValues(\.uuidString), forKey: key)
        }
    }

    /// Known board names, current one first, then alphabetical.
    static var names: [String] {
        let current = lastConnected
        return all.keys.sorted { a, b in
            if a == current { return true }
            if b == current { return false }
            return displayName(for: a).localizedCaseInsensitiveCompare(displayName(for: b)) == .orderedAscending
        }
    }

    static func forget(_ name: String) {
        var boards = all
        boards[name.lowercased()] = nil
        all = boards
        setNickname(nil, for: name)
        UserDefaults.standard.removeObject(forKey: "telemetry.\(name.lowercased())")
        UserDefaults.standard.removeObject(forKey: "range.\(name.lowercased())")
        UnlockStore.remove(for: name)
        if lastConnected == name.lowercased() { lastConnected = all.keys.sorted().first }
    }

    static func remember(_ name: String, id: UUID) {
        var boards = all
        boards[name.lowercased()] = id
        all = boards
    }

    /// Your own name for a board. Future Motion keeps its nickname in the
    /// official app and your account, not on the board, so we keep our own.
    static func nickname(for board: String) -> String? {
        let names = UserDefaults.standard.dictionary(forKey: "boardNicknames") as? [String: String]
        return names?[board.lowercased()]
    }

    static func setNickname(_ nickname: String?, for board: String) {
        var names = UserDefaults.standard.dictionary(forKey: "boardNicknames") as? [String: String] ?? [:]
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[board.lowercased()] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(names, forKey: "boardNicknames")
    }

    static func displayName(for board: String) -> String {
        nickname(for: board) ?? board
    }

    static var lastConnected: String? {
        get { UserDefaults.standard.string(forKey: "lastBoard") }
        set { UserDefaults.standard.set(newValue, forKey: "lastBoard") }
    }
}
