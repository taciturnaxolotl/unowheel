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
        var query = baseQuery(board)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(UnlockEntry.self, from: data)
    }

    static func response(for board: String, challenge: Challenge?) -> Data? {
        guard let entry = entry(for: board), let response = Handshake.parseHex(entry.response) else { return nil }
        if let challenge, let saved = entry.challenge, saved != challenge.hex { return nil }
        return response
    }

    static func save(_ response: Data, challenge: Challenge?, for board: String) {
        let entry = UnlockEntry(challenge: challenge?.hex, response: response.hexString, savedAt: .now)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        SecItemDelete(baseQuery(board) as CFDictionary)
        var add = baseQuery(board)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove(for board: String) {
        SecItemDelete(baseQuery(board) as CFDictionary)
    }

    private static func baseQuery(_ board: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: board.lowercased(),
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
