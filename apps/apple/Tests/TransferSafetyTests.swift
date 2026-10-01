import CryptoKit
import Foundation

@main
struct TransferSafetyTests {
    static let ampleSpace: Int64 = 8 * 1024 * 1024 * 1024
    static let sample = Data("NearLink verified transfer".utf8)

    static func main() throws {
        try testPolicy()
        try testPublication()
        try testFailedTransfers()
        try testAcknowledgement()
        print("All 4 transfer safety test groups passed.")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func expectFailure(_ action: () throws -> Void) {
        do {
            try action()
            preconditionFailure("Expected rejection")
        } catch { }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NearLink-Safety-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    static func testPolicy() throws {
        let limit = IncomingFilePolicy.maximumFileBytes
        let reserve = IncomingFilePolicy.minimumFreeBytes
        try IncomingFilePolicy.validateOffer(byteCount: limit, checksum: hash(sample))
        try IncomingFilePolicy.validateOffer(byteCount: 0, checksum: hash(Data()))
        expectFailure { try IncomingFilePolicy.validateOffer(byteCount: limit + 1, checksum: hash(sample)) }
        expectFailure { try IncomingFilePolicy.validateOffer(byteCount: -1, checksum: hash(sample)) }
        expectFailure { try IncomingFilePolicy.validateOffer(byteCount: 1, checksum: "invalid") }
        expectFailure { _ = try IncomingFilePolicy.checkCapacity(requiredBytes: limit, availableBytes: limit + reserve - 1) }
        _ = try IncomingFilePolicy.checkCapacity(requiredBytes: limit, availableBytes: limit + reserve)
        expectFailure { _ = try IncomingFilePolicy.checkCapacity(requiredBytes: limit, availableBytes: limit + reserve, reservedBytes: 1) }
        let warning = try IncomingFilePolicy.checkCapacity(requiredBytes: 1, availableBytes: limit)
        expect(warning != nil, "Warn before storage falls below 2 GiB")
        let noWarning = try IncomingFilePolicy.checkCapacity(requiredBytes: limit, availableBytes: ampleSpace)
        expect(noWarning == nil, "No warning with ample space")
        print("PASS 2 GiB limits, malformed offers, free-space reserve, concurrent reservations and warnings")
    }

    static func testPublication() throws {
        try withDirectory { directory in
            let destination = directory.appendingPathComponent("sample.txt")
            let writer = try VerifiedIncomingFile(destination: destination, expectedBytes: Int64(sample.count),
                                                  expectedChecksum: hash(sample).uppercased(), availableBytes: { ampleSpace })
            defer { writer.discard() }
            try writer.append(sample.prefix(4))
            expect(!FileManager.default.fileExists(atPath: destination.path), "Partial data must not be published")
            try writer.append(sample.dropFirst(4))
            // Simulate another transfer publishing the same name before this one finishes.
            try Data("original".utf8).write(to: destination)
            let published = try writer.finish()
            expect(published != destination, "Do not overwrite an existing file")
            let actual = try Data(contentsOf: published)
            let original = try String(contentsOf: destination, encoding: .utf8)
            expect(actual == sample && original == "original", "Keep both verified content and the original")
            writer.discard()
            expect(FileManager.default.fileExists(atPath: published.path), "Cleanup must preserve committed data")
            let empty = try VerifiedIncomingFile(destination: directory.appendingPathComponent("empty"), expectedBytes: 0,
                                                 expectedChecksum: hash(Data()), availableBytes: { ampleSpace })
            let emptyURL = try empty.finish()
            let emptyData = try Data(contentsOf: emptyURL)
            expect(emptyData.isEmpty, "Allow a verified empty file")
        }
        print("PASS verified publication, empty files, case-insensitive digest and same-name safety")
    }

    static func testFailedTransfers() throws {
        for scenario in ["oversize", "truncated", "checksum", "disk-full", "disk-shrinks", "interrupted"] {
            try withDirectory { directory in
                let destination = directory.appendingPathComponent("sample.txt")
                var spaceChecks = 0
                let writer = try VerifiedIncomingFile(
                    destination: destination, expectedBytes: Int64(sample.count),
                    expectedChecksum: scenario == "checksum" ? hash(Data()) : hash(sample),
                    availableBytes: {
                        spaceChecks += 1
                        return scenario == "disk-full" || (scenario == "disk-shrinks" && spaceChecks > 1)
                            ? IncomingFilePolicy.minimumFreeBytes : ampleSpace
                    }
                )
                expectFailure {
                    switch scenario {
                    case "oversize": try writer.append(sample + Data([0]))
                    case "truncated": try writer.append(sample.prefix(2)); _ = try writer.finish()
                    case "checksum": try writer.append(sample); _ = try writer.finish()
                    case "disk-full": try writer.append(sample)
                    case "disk-shrinks":
                        try writer.append(sample.prefix(2))
                        try writer.append(sample.dropFirst(2))
                    default:
                        try writer.append(sample.prefix(2))
                        throw CocoaError(.fileReadUnknown)
                    }
                }
                writer.discard()
                let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                expect(remaining.isEmpty, "No partial or invalid file should survive \(scenario)")
            }
        }
        print("PASS oversized streams, truncation, checksum failures, disk exhaustion and interruption cleanup")
    }

    static func testAcknowledgement() throws {
        let id = UUID()
        var ack: [String: Any] = ["version": 2, "type": "ack", "messageID": UUID().uuidString,
                                  "payload": ["messageID": id.uuidString]]
        let codec = ProtocolCodec()
        expectFailure {
            _ = try codec.decode(NearLinkEnvelope<AckPayload>.self, from: JSONSerialization.data(withJSONObject: ack))
        }
        ack["timestamp"] = Date().timeIntervalSince1970 * 1000
        let generated = try JSONSerialization.data(withJSONObject: ack)
        let fixture = CommandLine.arguments.count > 1 ? try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) : generated
        let decoded = try codec.decode(NearLinkEnvelope<AckPayload>.self, from: fixture)
        expect(decoded.version == 2 && decoded.type == .ack, "ACK must match the current protocol")
        if CommandLine.arguments.count <= 1 { expect(decoded.payload.messageID == id, "Correlate ACK to sent message") }
        print("PASS ACK contract\(CommandLine.arguments.count > 1 ? " using Android-generated JSON" : "")")
    }
}
