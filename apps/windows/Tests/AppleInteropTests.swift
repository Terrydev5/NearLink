import Foundation

@main
struct AppleInteropTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: apple-interop <windows-fixtures.json> <apple-fixtures.json>") }
        let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let codec = ProtocolCodec()
        func bytes(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: fixtures[key]!) }
        let hello = try codec.decode(NearLinkEnvelope<HelloPayload>.self, from: bytes("hello"))
        precondition(hello.version == 2 && hello.payload.device.platform == .windows)
        let text = try codec.decode(NearLinkEnvelope<TextMessagePayload>.self, from: bytes("text"))
        precondition(text.payload.text == "你好 Windows 👋" && text.payload.senderID != nil)
        let ack = try codec.decode(NearLinkEnvelope<AckPayload>.self, from: bytes("ack"))
        precondition(ack.messageID != ack.payload.messageID)
        let offer = try codec.decode(NearLinkEnvelope<FileOfferPayload>.self, from: bytes("offer"))
        precondition(offer.payload.transfer.fileSize == 2 * 1024 * 1024 * 1024)
        precondition(offer.payload.transfer.streamToken?.count == 43 && offer.payload.transfer.streamTokenExpiresAt != nil)
        for key in ["accept", "reject", "complete", "cancel"] {
            _ = try codec.decode(NearLinkEnvelope<TransferDecisionPayload>.self, from: bytes(key))
        }
        _ = try codec.decode(NearLinkEnvelope<TransferProgressPayload>.self, from: bytes("progress"))
        for key in ["heartbeat", "heartbeatAck"] {
            _ = try codec.decode(NearLinkEnvelope<EmptyPayload>.self, from: bytes(key))
        }
        // Encode with the production Apple codec, including a deliberately fractional Date.
        let descriptor = TransferDescriptor(fileName: "Apple fixture.mov", fileSize: 2 * 1024 * 1024 * 1024,
            checksum: String(repeating: "a", count: 64), mimeType: "video/quicktime", streamPort: 41821,
            streamToken: String(repeating: "b", count: 43),
            streamTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000.123456))
        let encoded: [String: Data] = [
            "ack": try codec.encode(NearLinkEnvelope(type: .ack, payload: AckPayload(messageID: UUID()))),
            "hello": try codec.encode(NearLinkEnvelope(type: .hello,
                payload: HelloPayload(device: NearbyDevice(name: "Apple fixture", platform: .iOS)))),
            "text": try codec.encode(NearLinkEnvelope(type: .textMessage,
                payload: TextMessagePayload(text: "来自 Apple", senderID: UUID()))),
            "offer": try codec.encode(NearLinkEnvelope(type: .fileOffer, payload: FileOfferPayload(transfer: descriptor)))
        ]
        let objects = try encoded.mapValues { try JSONSerialization.jsonObject(with: $0) }
        try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("PASS: Apple production decoder accepted 11 Windows message types; Apple fixtures exported.")
    }
}
