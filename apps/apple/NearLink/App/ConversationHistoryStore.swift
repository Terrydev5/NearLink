import Foundation

/// Small local-only persistence layer for the Apple MVP. It deliberately stores
/// no network endpoints or credentials—only device profiles, chat timeline
/// metadata and unread counts. Presence always comes from live discovery.
struct ConversationHistoryStore {
    private let defaults: UserDefaults
    private let key = "NearLink.conversationHistory.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> (items: [ConversationItem], unreadCounts: [UUID: Int], devices: [NearbyDevice]) {
        guard let data = defaults.data(forKey: key),
              let history = try? JSONDecoder().decode(PersistedConversationHistory.self, from: data) else {
            return ([], [:], [])
        }
        let unreadCounts = history.unreadCounts.reduce(into: [UUID: Int]()) { result, entry in
            guard let id = UUID(uuidString: entry.key), entry.value > 0 else { return }
            result[id] = entry.value
        }
        return (history.items, unreadCounts, (history.devices ?? []).map(\.historyProfile))
    }

    func save(items: [ConversationItem], unreadCounts: [UUID: Int], devices: [NearbyDevice]) {
        let counts = Dictionary(uniqueKeysWithValues: unreadCounts.map { ($0.key.uuidString, $0.value) })
        let history = PersistedConversationHistory(
            items: items,
            unreadCounts: counts,
            devices: devices.map(\.historyProfile).sorted { $0.id.uuidString < $1.id.uuidString }
        )
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: key)
    }
}

private struct PersistedConversationHistory: Codable {
    let items: [ConversationItem]
    let unreadCounts: [String: Int]
    // Optional so existing v1 histories keep all their messages and transfers.
    let devices: [NearbyDevice]?
}
