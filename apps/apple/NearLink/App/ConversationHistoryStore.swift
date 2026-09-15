import Foundation

/// Small local-only persistence layer for the Apple MVP. It deliberately stores
/// no network endpoints or credentials—only chat timeline metadata and unread
/// counts, both of which are reconstructed against currently nearby devices.
struct ConversationHistoryStore {
    private let defaults: UserDefaults
    private let key = "NearLink.conversationHistory.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> (items: [ConversationItem], unreadCounts: [UUID: Int]) {
        guard let data = defaults.data(forKey: key),
              let history = try? JSONDecoder().decode(PersistedConversationHistory.self, from: data) else {
            return ([], [:])
        }
        let unreadCounts = history.unreadCounts.reduce(into: [UUID: Int]()) { result, entry in
            guard let id = UUID(uuidString: entry.key), entry.value > 0 else { return }
            result[id] = entry.value
        }
        return (history.items, unreadCounts)
    }

    func save(items: [ConversationItem], unreadCounts: [UUID: Int]) {
        let counts = Dictionary(uniqueKeysWithValues: unreadCounts.map { ($0.key.uuidString, $0.value) })
        let history = PersistedConversationHistory(items: items, unreadCounts: counts)
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: key)
    }
}

private struct PersistedConversationHistory: Codable {
    let items: [ConversationItem]
    let unreadCounts: [String: Int]
}
