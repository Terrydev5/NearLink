import CryptoKit
import Foundation

nonisolated enum IncomingFilePolicy {
    static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let minimumFreeBytes: Int64 = 512 * 1024 * 1024
    static let lowStorageBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumConcurrentReceives = 10

    static func validateOffer(byteCount: Int64, checksum: String) throws {
        guard byteCount >= 0, byteCount <= maximumFileBytes else {
            throw failure("Cannot receive this file. The maximum file size is 2 GiB.")
        }
        guard checksum.utf8.count == 64, checksum.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else {
            throw failure("The sender provided an invalid SHA-256 checksum.")
        }
    }

    static func checkCapacity(requiredBytes: Int64, availableBytes: Int64, reservedBytes: Int64 = 0) throws -> String? {
        let usable = max(0, availableBytes - reservedBytes)
        guard requiredBytes >= 0, usable >= minimumFreeBytes,
              requiredBytes <= usable - minimumFreeBytes else {
            throw failure("Not enough storage to receive this file. \(format(usable)) available; \(format(requiredBytes + minimumFreeBytes)) needed, including 512 MiB kept free. Free up space and ask the sender to retry.")
        }
        let remaining = usable - requiredBytes
        return remaining < lowStorageBytes
            ? "Storage is running low. About \(format(remaining)) will remain after the current files are received. NearLink keeps at least 512 MiB free and will stop if space runs out."
            : nil
    }

    static func availableBytes(at directory: URL) throws -> Int64 {
        // Actual free disk space, excluding purgeable space and physical RAM.
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber else {
            throw failure("Could not check available storage. Please try again.")
        }
        return bytes.int64Value
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "NearLink.IncomingFile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .binary)
    }
}

/// Owns a hidden, same-volume temporary file. Only verified content is published.
nonisolated final class VerifiedIncomingFile {
    private let destination: URL
    private let temporary: URL
    private let expectedBytes: Int64
    private let expectedChecksum: String
    private let availableBytes: () throws -> Int64
    private var handle: FileHandle?
    private var digest = SHA256()
    private(set) var completedBytes: Int64 = 0

    init(destination: URL, expectedBytes: Int64, expectedChecksum: String,
         availableBytes: (() throws -> Int64)? = nil) throws {
        try IncomingFilePolicy.validateOffer(byteCount: expectedBytes, checksum: expectedChecksum)
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.expectedChecksum = expectedChecksum.lowercased()
        let directory = destination.deletingLastPathComponent()
        self.availableBytes = availableBytes ?? { try IncomingFilePolicy.availableBytes(at: directory) }
        temporary = directory.appendingPathComponent(".nearlink-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw IncomingFilePolicy.failure("Could not create the temporary download.")
        }
        do {
            handle = try FileHandle(forWritingTo: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func append(_ data: Data) throws {
        guard Int64(data.count) <= expectedBytes - completedBytes else {
            throw IncomingFilePolicy.failure("The sender sent more data than the advertised file size. Reception stopped.")
        }
        _ = try IncomingFilePolicy.checkCapacity(requiredBytes: Int64(data.count), availableBytes: availableBytes())
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
        digest.update(data: data)
        completedBytes += Int64(data.count)
    }

    func finish() throws -> URL {
        guard completedBytes == expectedBytes else {
            throw IncomingFilePolicy.failure("The file stream ended before all expected bytes arrived.")
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == expectedChecksum else { throw NearLinkError.checksumMismatch }
        try handle?.close()
        handle = nil
        var candidate = destination
        // moveItem never overwrites an existing file, including concurrent receives.
        for _ in 0..<3 {
            do {
                try FileManager.default.moveItem(at: temporary, to: candidate)
                return candidate
            } catch {
                guard FileManager.default.fileExists(atPath: candidate.path) else { throw error }
                let stem = destination.deletingPathExtension().lastPathComponent
                let ext = destination.pathExtension
                let name = "\(stem)-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
                candidate = destination.deletingLastPathComponent().appendingPathComponent(name)
            }
        }
        throw IncomingFilePolicy.failure("Could not choose a unique download name.")
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: temporary)
    }

    deinit { discard() }
}
