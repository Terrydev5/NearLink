import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum DevicePlatform: String, Codable, Sendable {
    case macOS
    case iOS
    case android
    case windows
}

nonisolated struct NearbyDevice: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let platform: DevicePlatform
    let protocolVersion: Int
    var endpointDescription: String?

    nonisolated init(
        id: UUID = UUID(),
        name: String,
        platform: DevicePlatform,
        protocolVersion: Int = NearLinkProtocol.version,
        endpointDescription: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.protocolVersion = protocolVersion
        self.endpointDescription = endpointDescription
    }

    @MainActor static var local: NearbyDevice {
        let defaults = UserDefaults.standard
        let key = "NearLink.localDeviceID"
        let deviceID: UUID
        if let storedID = defaults.string(forKey: key), let id = UUID(uuidString: storedID) {
            deviceID = id
        } else {
            deviceID = UUID()
            defaults.set(deviceID.uuidString, forKey: key)
        }
        #if os(macOS)
        return NearbyDevice(
            id: deviceID,
            name: Host.current().localizedName ?? "NearLink Mac",
            platform: .macOS
        )
        #else
        return NearbyDevice(id: deviceID, name: UIDevice.current.name, platform: .iOS)
        #endif
    }
}

nonisolated struct TransferDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let checksum: String
    let mimeType: String?
    var streamPort: UInt16?
    /// A random, one-time credential required before a peer may read the TCP stream.
    /// Optional only so transfer history written by protocol v1 can still decode.
    let streamToken: String?
    /// UTC expiry for the token; absent only in protocol-v1 transfer history.
    let streamTokenExpiresAt: Date?

    nonisolated init(
        id: UUID = UUID(),
        fileName: String,
        fileSize: Int64,
        checksum: String,
        mimeType: String? = nil,
        streamPort: UInt16? = nil,
        streamToken: String? = nil,
        streamTokenExpiresAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.mimeType = mimeType
        self.streamPort = streamPort
        self.streamToken = streamToken
        self.streamTokenExpiresAt = streamTokenExpiresAt
    }
}

nonisolated enum TransferState: String, Codable, Sendable {
    case idle
    case preparing
    case waitingForAcceptance
    case transferring
    case paused
    case completed
    case failed
    case cancelled

    func canTransition(to next: TransferState) -> Bool {
        switch (self, next) {
        case (.idle, .preparing),
             (.preparing, .waitingForAcceptance),
             (.preparing, .failed),
             (.waitingForAcceptance, .transferring),
             (.waitingForAcceptance, .cancelled),
             (.waitingForAcceptance, .failed),
             (.transferring, .paused),
             (.transferring, .completed),
             (.transferring, .failed),
             (.transferring, .cancelled),
             (.paused, .transferring),
             (.paused, .cancelled),
             (.paused, .failed):
            return true
        default:
            return false
        }
    }
}

nonisolated struct TransferSnapshot: Identifiable, Codable, Hashable, Sendable {
    var descriptor: TransferDescriptor
    var state: TransferState
    var completedBytes: Int64
    var errorDescription: String?

    var id: UUID { descriptor.id }
    var progress: Double {
        guard descriptor.fileSize > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(descriptor.fileSize))
    }
}

/// A single chronological item in a device conversation.
/// Text and file transfers share this timeline so the UI can render them in the
/// same order in which they were created.
nonisolated struct ConversationItem: Identifiable, Codable, Hashable, Sendable {
    nonisolated enum Kind: Codable, Hashable, Sendable {
        case text(String)
        case transfer(UUID)
    }

    let id: UUID
    let peerID: UUID
    let timestamp: Date
    let kind: Kind
    let isIncoming: Bool

    nonisolated init(id: UUID = UUID(), peerID: UUID, timestamp: Date = Date(), kind: Kind, isIncoming: Bool) {
        self.id = id
        self.peerID = peerID
        self.timestamp = timestamp
        self.kind = kind
        self.isIncoming = isIncoming
    }
}

nonisolated struct ConversationPreview: Sendable {
    let text: String
    let timestamp: Date
    let unreadCount: Int
}

nonisolated enum NearLinkError: LocalizedError, Sendable {
    case invalidTransition(from: TransferState, to: TransferState)
    case checksumMismatch
    case unsupportedProtocol(Int)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, to): "Invalid transfer transition: \(from.rawValue) → \(to.rawValue)."
        case .checksumMismatch: "The received file did not pass SHA-256 verification."
        case let .unsupportedProtocol(version): "Protocol version \(version) is not supported."
        case let .connectionFailed(reason): "Connection failed: \(reason)"
        }
    }
}
