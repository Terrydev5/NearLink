import Foundation

/// Exercises the production model and store without starting discovery or touching
/// the user's chat history. Run with scripts/test-device-history.sh on macOS.
@main
struct DeviceHistoryTests {
    @MainActor
    static func main() throws {
        try testLegacyHistory()
        try testPresenceAndRelaunch()
        try testReconnectAndRename()
        try testOfflineSending()
        try testIdentityMigration()
        try testIncomingConnectionWithoutDiscovery()
        try testSameNameDevices()
        print("All 7 device history regression tests passed.")
    }

    @MainActor
    static func withStore(_ test: (ConversationHistoryStore, UserDefaults) throws -> Void) rethrows {
        let suite = "NearLink.DeviceHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(ConversationHistoryStore(defaults: defaults), defaults)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor
    static func testLegacyHistory() throws {
        try withStore { store, defaults in
            let peerID = UUID()
            let transferID = UUID()
            let items = [
                ConversationItem(peerID: peerID, kind: .text("Peer: hello"), isIncoming: true),
                ConversationItem(peerID: peerID, kind: .transfer(transferID), isIncoming: false)
            ]
            struct LegacyHistory: Encodable {
                let items: [ConversationItem]
                let unreadCounts: [String: Int]
            }
            defaults.set(try JSONEncoder().encode(LegacyHistory(items: items, unreadCounts: [peerID.uuidString: 2])),
                         forKey: "NearLink.conversationHistory.v1")
            let model = NearLinkAppModel(conversationStore: store)
            expect(model.devices.count == 1, "Old history needs an offline device row")
            expect(model.devices[0].platform == .unknown, "Do not invent a platform for legacy history")
            let legacyID = model.devices[0].id
            expect(!model.isDeviceOnline(legacyID), "Restoring history must not restore online status")
            expect(model.conversationItems.map(\.id) == items.map(\.id), "Preserve old messages and file entries")
            expect(model.conversationItems.allSatisfy { $0.peerID == legacyID }, "Group unknown legacy IDs into one history entry")
            expect(model.transferPeerID(for: transferID) == legacyID, "Restore file-to-device associations")
            expect(model.unreadMessageCounts[legacyID] == 2, "Keep unread counts during migration")
            model.selectedDeviceID = legacyID
            expect(model.conversationPreview(for: legacyID)?.unreadCount == 0, "Offline conversations can be read")
            let restored = NearLinkAppModel(conversationStore: store)
            expect(restored.conversationItems.map(\.id) == items.map(\.id), "Migration must survive another launch")
            print("PASS legacy history, file associations and unread counts")
        }
    }

    @MainActor
    static func testPresenceAndRelaunch() throws {
        withStore { store, _ in
            let saved = NearbyDevice(name: "Saved Mac", platform: .macOS, endpointDescription: "temporary endpoint")
            let transient = NearbyDevice(name: "Passing iPhone", platform: .iOS)
            let model = NearLinkAppModel(conversationStore: store)
            model.updateNearbyDevices([saved, transient])
            expect(model.devices.count == 2, "Show newly discovered devices")
            model.rememberDevice(saved)
            model.selectedDeviceID = saved.id
            model.updateNearbyDevices([])
            expect(model.devices.map(\.id) == [saved.id], "Keep connected peers, remove unconnected passersby")
            expect(model.selectedDeviceID == saved.id, "Keep the conversation selected when its peer leaves")
            expect(!model.isDeviceOnline(saved.id), "Peer leaving discovery becomes offline")
            let restored = NearLinkAppModel(conversationStore: store)
            expect(restored.devices.map(\.id) == [saved.id], "Connected peers without messages survive relaunch")
            expect(restored.onlineDeviceIDs.isEmpty, "Presence is never persisted")
            expect(store.load().devices[0].endpointDescription == nil, "Do not persist network endpoints")
            print("PASS disconnect, connected-only history and relaunch")
        }
    }

    @MainActor
    static func testReconnectAndRename() throws {
        withStore { store, _ in
            let peerID = UUID()
            let saved = NearbyDevice(id: peerID, name: "Old MacBook name", platform: .macOS)
            let item = ConversationItem(peerID: peerID, kind: .text("You: saved text"), isIncoming: false)
            store.save(items: [item], unreadCounts: [:], devices: [saved])
            let model = NearLinkAppModel(conversationStore: store)
            let online = NearbyDevice(id: peerID, name: "Renamed MacBook", platform: .macOS)
            model.updateNearbyDevices([online, online])
            expect(model.devices.count == 1, "A returning device must not duplicate its historical row")
            expect(model.isDeviceOnline(peerID), "Returning device becomes online")
            expect(model.devices[0].name == online.name, "Discovery repairs old missing metadata")
            model.updateNearbyDevices([])
            let restored = NearLinkAppModel(conversationStore: store)
            expect(restored.devices[0].name == online.name, "Persist updated device names")
            expect(restored.conversationItems == [item], "Reconnection must preserve the timeline")
            restored.deleteConversationItem(item.id)
            expect(restored.devices.count == 1, "Deleting the last message must not forget a known peer")
            print("PASS reconnect, metadata repair, deduplication and last-message deletion")
        }
    }

    @MainActor
    static func testOfflineSending() throws {
        withStore { store, _ in
            let device = NearbyDevice(name: "Offline iPhone", platform: .iOS)
            store.save(items: [], unreadCounts: [:], devices: [device])
            let model = NearLinkAppModel(conversationStore: store)
            model.selectedDeviceID = device.id
            model.messageText = "Keep this draft"
            model.sendMessage()
            expect(model.messageText == "Keep this draft", "Offline sends must retain the draft")
            expect(model.messages.first?.contains("offline") == true, "Explain a rejected offline send")
            model.stageFile(URL(fileURLWithPath: "/nonexistent/offline-test.txt"))
            expect(model.transfers.isEmpty, "Offline attachments must not start transfers")
            expect(model.messages.first?.contains("offline") == true, "Reject offline attachments before file access")
            print("PASS offline send guards and draft retention")
        }
    }

    @MainActor
    static func testIdentityMigration() throws {
        withStore { store, _ in
            let temporary = NearbyDevice(name: "MacBook", platform: .macOS)
            let stable = NearbyDevice(name: "MacBook", platform: .macOS)
            let transferID = UUID()
            let items = [
                ConversationItem(peerID: temporary.id, kind: .text("Peer: old"), isIncoming: true),
                ConversationItem(peerID: temporary.id, kind: .transfer(transferID), isIncoming: true),
                ConversationItem(peerID: stable.id, kind: .text("You: earlier"), isIncoming: false)
            ]
            store.save(items: items, unreadCounts: [temporary.id: 1], devices: [temporary, stable])
            let model = NearLinkAppModel(conversationStore: store)
            model.updateNearbyDevices([temporary])
            model.reconcileDeviceIdentity(discoveredID: temporary.id, verifiedDevice: stable)
            expect(model.devices.map(\.id) == [stable.id], "Merge temporary and stable device rows")
            expect(model.isDeviceOnline(stable.id), "Move presence to the stable ID")
            expect(model.conversationItems.allSatisfy { $0.peerID == stable.id }, "Move text and file entries together")
            expect(model.transferPeerID(for: transferID) == stable.id, "Migrate file associations")
            expect(model.unreadMessageCounts[stable.id] == 1, "Migrate unread state")
            let restored = NearLinkAppModel(conversationStore: store)
            expect(restored.devices.map(\.id) == [stable.id], "Do not resurrect the temporary identity")
            expect(restored.transferPeerID(for: transferID) == stable.id, "Persist migrated file associations")
            print("PASS stable identity migration and persisted timeline")
        }
    }

    @MainActor
    static func testIncomingConnectionWithoutDiscovery() throws {
        withStore { store, _ in
            let peer = NearbyDevice(name: "Incoming peer", platform: .android)
            let model = NearLinkAppModel(conversationStore: store)
            model.reconcileDeviceIdentity(discoveredID: nil, verifiedDevice: peer)
            let restored = NearLinkAppModel(conversationStore: store)
            expect(restored.devices.map(\.id) == [peer.id], "Remember an inbound hello even without a Bonjour row")
            print("PASS inbound-only connected device persistence")
        }
    }

    @MainActor
    static func testSameNameDevices() throws {
        withStore { store, _ in
            let saved = NearbyDevice(name: "iPhone", platform: .iOS)
            let stranger = NearbyDevice(name: "iPhone", platform: .iOS)
            store.save(items: [], unreadCounts: [:], devices: [saved])
            let model = NearLinkAppModel(conversationStore: store)
            model.updateNearbyDevices([stranger])
            expect(model.devices.count == 2, "Do not merge different IDs just because names match")
            expect(!model.isDeviceOnline(saved.id), "An unrelated same-name device must not mark history online")
            expect(model.devices.first?.id == stranger.id, "Online devices sort before offline history")
            print("PASS same-name device separation and online-first ordering")
        }
    }
}
