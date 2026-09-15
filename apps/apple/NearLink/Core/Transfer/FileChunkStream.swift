import Foundation

/// Reads only one bounded chunk at a time. It is the file-data half of the protocol;
/// control messages remain on the WebSocket connection.
struct FileChunkStream: AsyncSequence, Sendable {
    typealias Element = Data

    let fileURL: URL
    let offset: Int64
    let chunkSize: Int

    init(fileURL: URL, offset: Int64 = 0, chunkSize: Int = NearLinkProtocol.chunkSize) {
        self.fileURL = fileURL
        self.offset = offset
        self.chunkSize = chunkSize
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(fileURL: fileURL, offset: offset, chunkSize: chunkSize)
    }

    final class Iterator: AsyncIteratorProtocol {
        private let handle: FileHandle
        private let chunkSize: Int
        private var finished = false

        init(fileURL: URL, offset: Int64, chunkSize: Int) {
            self.handle = try! FileHandle(forReadingFrom: fileURL)
            self.chunkSize = chunkSize
            try? handle.seek(toOffset: UInt64(offset))
        }

        deinit { try? handle.close() }

        func next() async throws -> Data? {
            guard !finished else { return nil }
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                finished = true
                return nil
            }
            return data
        }
    }
}
