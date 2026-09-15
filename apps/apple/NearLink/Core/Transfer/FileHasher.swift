import CryptoKit
import Foundation
import Security

nonisolated enum FileHasher {
    nonisolated static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: NearLinkProtocol.chunkSize) ?? Data()
            guard !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A 256-bit, URL-safe token used once to authorize a file stream.
nonisolated enum TransferToken {
    private static let byteCount = 32

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NearLinkError.connectionFailed("Could not create a secure transfer token")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isValid(_ token: String) -> Bool {
        token.utf8.count == 43 && token.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    /// Avoid short-circuit comparison when validating a bearer token.
    static func matches(_ received: String, expected: String) -> Bool {
        let left = Array(received.utf8)
        let right = Array(expected.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(left, right) { difference |= lhs ^ rhs }
        return difference == 0
    }
}
