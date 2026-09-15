import Foundation

nonisolated enum NearLinkProtocol {
    // Version 2 requires a single-use data-stream token for every file offer.
    nonisolated static let version = 2
    nonisolated static let serviceType = "_nearlink._tcp"
    nonisolated static let chunkSize = 256 * 1024
}

nonisolated enum NearLinkMessageType: String, Codable, Sendable {
    case hello
    case textMessage = "text_message"
    case fileOffer = "file_offer"
    case fileAccept = "file_accept"
    case fileReject = "file_reject"
    case transferStart = "transfer_start"
    case transferProgress = "transfer_progress"
    case transferComplete = "transfer_complete"
    case transferCancel = "transfer_cancel"
    case heartbeat
    case heartbeatAck = "heartbeat_ack"
    case ack
    case error
}

nonisolated struct NearLinkEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    let version: Int
    let type: NearLinkMessageType
    let messageID: UUID
    let timestamp: Date
    let payload: Payload

    init(type: NearLinkMessageType, payload: Payload) {
        self.version = NearLinkProtocol.version
        self.type = type
        self.messageID = UUID()
        self.timestamp = Date()
        self.payload = payload
    }
}

nonisolated struct EmptyPayload: Codable, Sendable {}

nonisolated struct HelloPayload: Codable, Sendable {
    let device: NearbyDevice
}

nonisolated struct TextMessagePayload: Codable, Sendable {
    let text: String
    /// Allows a receiver to route a message even when the initial hello frame
    /// is still being processed on a newly accepted WebSocket connection.
    let senderID: UUID?

    init(text: String, senderID: UUID? = nil) {
        self.text = text
        self.senderID = senderID
    }
}

nonisolated struct FileOfferPayload: Codable, Sendable {
    let transfer: TransferDescriptor
}

nonisolated struct TransferDecisionPayload: Codable, Sendable {
    let transferID: UUID
    let receivedBytes: Int64
}

nonisolated struct TransferProgressPayload: Codable, Sendable {
    let transferID: UUID
    let completedBytes: Int64
}

nonisolated struct AckPayload: Codable, Sendable {
    let messageID: UUID
}

nonisolated struct ProtocolCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    nonisolated init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func encode<Payload>(_ envelope: NearLinkEnvelope<Payload>) throws -> Data where Payload: Codable & Sendable {
        try encoder.encode(envelope)
    }

    func decode<Payload>(_ type: NearLinkEnvelope<Payload>.Type, from data: Data) throws -> NearLinkEnvelope<Payload> where Payload: Codable & Sendable {
        try decoder.decode(type, from: data)
    }
}
