@preconcurrency import Network
import Foundation
import OSLog

nonisolated final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    nonisolated func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

actor WebSocketConnectionActor {
    enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case cancelled
    }

    private let endpoint: NWEndpoint
    private let connection: NWConnection
    private let codec = ProtocolCodec()
    private let logger = Logger(subsystem: "cn.terrydev.NearLink", category: "connection")
    private var currentState: State = .idle
    private var heartbeatTask: Task<Void, Never>?

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        connection = NWConnection(to: endpoint, using: parameters)
    }

    init(acceptedConnection: NWConnection) {
        endpoint = acceptedConnection.endpoint
        connection = acceptedConnection
    }

    func connect() async throws {
        guard case .idle = currentState else { return }
        logger.debug("Opening outbound control connection to \(String(describing: self.endpoint), privacy: .public)")
        currentState = .connecting
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    Task { await self?.log("Outbound control connection ready") }
                    Task { await self?.setConnected() }
                    continuation.resume()
                case let .failed(error):
                    guard gate.claim() else { return }
                    Task { await self?.log("Outbound control connection failed: \(error.localizedDescription)") }
                    Task { await self?.setFailed(error.localizedDescription) }
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

    func accept() async throws {
        guard case .idle = currentState else { return }
        logger.debug("Accepting inbound control connection")
        currentState = .connecting
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    Task { await self?.log("Inbound control connection ready") }
                    Task { await self?.setConnected() }
                    continuation.resume()
                case let .failed(error):
                    guard gate.claim() else { return }
                    Task { await self?.log("Inbound control connection failed: \(error.localizedDescription)") }
                    Task { await self?.setFailed(error.localizedDescription) }
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

    func send<Payload>(_ envelope: NearLinkEnvelope<Payload>) throws where Payload: Codable & Sendable {
        guard currentState == .connected else { throw NearLinkError.connectionFailed("Not connected") }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: envelope.messageID.uuidString, metadata: [metadata])
        connection.send(content: try codec.encode(envelope), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func cancel() {
        logger.debug("Cancelling control connection")
        heartbeatTask?.cancel()
        heartbeatTask = nil
        currentState = .cancelled
        connection.cancel()
    }

    func startHeartbeat(every interval: Duration = .seconds(12)) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                try? await self.send(NearLinkEnvelope(type: .heartbeat, payload: EmptyPayload()))
            }
        }
    }

    func receiveMessages() -> AsyncStream<Data> {
        AsyncStream { continuation in
            receiveNext(into: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.cancel() }
            }
        }
    }

    func state() -> State { currentState }
    func isConnected() -> Bool { currentState == .connected }
    func targetDescription() -> String { String(describing: endpoint) }

    func remoteHost() -> NWEndpoint.Host? {
        guard let remoteEndpoint = connection.currentPath?.remoteEndpoint,
              case let .hostPort(host, _) = remoteEndpoint else { return nil }
        return host
    }

    private func setConnected() { currentState = .connected }
    private func setFailed(_ reason: String) { currentState = .failed(reason) }

    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    private func receiveNext(into continuation: AsyncStream<Data>.Continuation) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            if let data { continuation.yield(data) }
            if let error {
                Task { await self?.log("Control connection receive ended: \(error.localizedDescription)") }
                Task { await self?.markDisconnected("Receive failed: \(error.localizedDescription)") }
                continuation.finish()
                return
            }
            if !isComplete {
                Task { await self?.markDisconnected("Peer closed the control connection") }
                continuation.finish()
                return
            }
            Task { await self?.receiveNext(into: continuation) }
        }
    }

    private func markDisconnected(_ reason: String) {
        guard currentState != .cancelled else { return }
        logger.debug("Control connection is no longer usable: \(reason, privacy: .public)")
        heartbeatTask?.cancel()
        heartbeatTask = nil
        currentState = .failed(reason)
        connection.cancel()
    }
}
