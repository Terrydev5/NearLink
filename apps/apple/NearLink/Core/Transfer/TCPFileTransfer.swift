@preconcurrency import Network
import Foundation
import OSLog

/// The data plane deliberately uses a plain TCP stream. WebSocket is reserved for
/// offers, decisions and progress so a multi-gigabyte file is never encoded as JSON.
actor OutboundFileServer {
    private let fileURL: URL
    private let streamToken: String
    private let tokenExpiresAt: Date
    private let logger = Logger(subsystem: "cn.terrydev.NearLink", category: "file-transfer")
    private let progressHandler: @Sendable (Int64) -> Void
    private var listener: NWListener?
    private var didServeAuthenticatedClient = false

    init(
        fileURL: URL,
        streamToken: String,
        tokenExpiresAt: Date,
        progressHandler: @escaping @Sendable (Int64) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.streamToken = streamToken
        self.tokenExpiresAt = tokenExpiresAt
        self.progressHandler = progressHandler
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim(), let port = listener.port else { return }
                    continuation.resume(returning: port.rawValue)
                case let .failed(error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: NearLinkError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.stream(to: connection) }
            }
            listener.start(queue: .main)
            Task { [weak self] in
                let remaining = max(0, self?.tokenExpiresAt.timeIntervalSinceNow ?? 0)
                try? await Task.sleep(for: .seconds(remaining))
                await self?.stopIfExpired()
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func stopIfExpired() {
        guard !didServeAuthenticatedClient, Date() >= tokenExpiresAt else { return }
        logger.notice("File stream authorization token expired before use")
        stop()
    }

    private func stream(to connection: NWConnection) async {
        do {
            try await waitUntilReady(connection)
            let receivedToken = try await receiveTransferToken(on: connection)
            guard Date() <= tokenExpiresAt,
                  TransferToken.matches(receivedToken, expected: streamToken),
                  !didServeAuthenticatedClient else {
                logger.warning("Rejected unauthenticated, expired, or duplicate data connection")
                connection.cancel()
                return
            }
            didServeAuthenticatedClient = true
            logger.debug("Accepted authenticated data connection")
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var completedBytes: Int64 = 0
            while true {
                let chunk = try handle.read(upToCount: NearLinkProtocol.chunkSize) ?? Data()
                guard !chunk.isEmpty else { break }
                try await send(chunk, on: connection, isComplete: false)
                completedBytes += Int64(chunk.count)
                progressHandler(completedBytes)
            }
            try await send(nil, on: connection, isComplete: true)
        } catch {
            connection.cancel()
        }
        connection.cancel()
        if didServeAuthenticatedClient { stop() }
    }
}

actor InboundFileReceiver {
    func receive(
        from host: NWEndpoint.Host,
        port: UInt16,
        into destinationURL: URL,
        streamToken: String,
        tokenExpiresAt: Date,
        resumeAt offset: Int64 = 0,
        progressHandler: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        guard TransferToken.isValid(streamToken) else {
            throw NearLinkError.connectionFailed("Missing transfer authorization token")
        }
        guard Date() <= tokenExpiresAt else {
            throw NearLinkError.connectionFailed("The transfer authorization token has expired")
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NearLinkError.connectionFailed("Invalid file stream port")
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(host: host, port: endpointPort, using: parameters)
        try await waitUntilReady(connection)
        try await send(Data((streamToken + "\n").utf8), on: connection, isComplete: false)

        let fileManager = FileManager.default
        if offset == 0, fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        if !fileManager.fileExists(atPath: destinationURL.path) {
            _ = fileManager.createFile(atPath: destinationURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? handle.close()
            connection.cancel()
        }
        try handle.seek(toOffset: UInt64(offset))
        var completedBytes = offset

        while true {
            let received = try await receiveChunk(on: connection)
            if let data = received.data, !data.isEmpty {
                try handle.write(contentsOf: data)
                completedBytes += Int64(data.count)
                progressHandler(completedBytes)
            }
            if received.isComplete { return destinationURL }
        }
    }
}

private func waitUntilReady(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let gate = ResumeGate()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard gate.claim() else { return }
                continuation.resume()
            case let .failed(error):
                guard gate.claim() else { return }
                continuation.resume(throwing: NearLinkError.connectionFailed(error.localizedDescription))
            case .cancelled:
                guard gate.claim() else { return }
                continuation.resume(throwing: CancellationError())
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}

private func send(_ data: Data?, on connection: NWConnection, isComplete: Bool) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, contentContext: .defaultMessage, isComplete: isComplete, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: NearLinkError.connectionFailed(error.localizedDescription))
            } else {
                continuation.resume()
            }
        })
    }
}

private func receiveChunk(on connection: NWConnection) async throws -> (data: Data?, isComplete: Bool) {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: NearLinkProtocol.chunkSize) { data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: NearLinkError.connectionFailed(error.localizedDescription))
            } else {
                continuation.resume(returning: (data, isComplete))
            }
        }
    }
}

private func receiveTransferToken(on connection: NWConnection) async throws -> String {
    let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 44, maximumLength: 44) { data, _, _, error in
            if let error {
                continuation.resume(throwing: NearLinkError.connectionFailed(error.localizedDescription))
            } else if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: NearLinkError.connectionFailed("Missing transfer authorization token"))
            }
        }
    }
    guard data.count == 44, data.last == 0x0A else {
        throw NearLinkError.connectionFailed("Invalid transfer authorization token")
    }
    let token = String(decoding: data.dropLast(), as: UTF8.self)
    guard TransferToken.isValid(token) else {
        throw NearLinkError.connectionFailed("Invalid transfer authorization token")
    }
    return token
}
