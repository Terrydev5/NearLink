import Combine
import Foundation
import OSLog
@preconcurrency import Network
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

@MainActor
final class NearLinkAppModel: ObservableObject {
    private static let maximumBatchTransferCount = 10
    private static let legacyHistoryDeviceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    @Published private(set) var devices: [NearbyDevice] = []
    @Published private(set) var onlineDeviceIDs: Set<UUID> = []
    @Published private(set) var transfers: [TransferSnapshot] = []
    @Published private(set) var conversationItems: [ConversationItem] = []
    @Published private(set) var discoveryStatus = "Starting discovery…"
    @Published private(set) var unreadMessageCounts: [UUID: Int] = [:]
    @Published var selectedDeviceID: UUID? {
        didSet {
            if let selectedDeviceID { markConversationRead(for: selectedDeviceID) }
        }
    }
    @Published var messageText = ""
    @Published private(set) var messages: [String] = []

    private let discovery = BonjourDiscoveryActor(localDevice: .local)
    private let transferActor = TransferActor()
    private let conversationStore: ConversationHistoryStore
    private var nearbyDevices: [NearbyDevice] = []
    private var knownDevices: [UUID: NearbyDevice] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var incomingConnectionTask: Task<Void, Never>?
    private var outboundConnections: [UUID: WebSocketConnectionActor] = [:]
    private var inboundConnections: [WebSocketConnectionActor] = []
    private var connectionPeerIDs: [ObjectIdentifier: UUID] = [:]
    private var pendingMessageAcknowledgements: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var outboundFileServers: [UUID: OutboundFileServer] = [:]
    private var outboundFileAccess: [UUID: OutgoingFileAccess] = [:]
    private var incomingOffers: [UUID: IncomingOffer] = [:]
    private var transferFileURLs: [UUID: URL] = [:]
    private var transferPeerIDs: [UUID: UUID] = [:]
    private let logger = Logger(subsystem: "cn.terrydev.NearLink", category: "lifecycle")
    private var appWasBackgrounded = false
    private var discoveryRestartTask: Task<Void, Never>?

    convenience init() {
        self.init(conversationStore: ConversationHistoryStore())
    }

    init(conversationStore: ConversationHistoryStore) {
        self.conversationStore = conversationStore
        restoreConversationHistory()
    }

    func isDeviceOnline(_ deviceID: UUID) -> Bool {
        onlineDeviceIDs.contains(deviceID)
    }

    func updateNearbyDevices(_ nearby: [NearbyDevice]) {
        nearbyDevices = nearby
        onlineDeviceIDs = Set(nearby.map(\.id))
        var profilesChanged = false
        for device in nearby where knownDevices[device.id] != nil {
            let profile = device.historyProfile
            if knownDevices[device.id] != profile {
                knownDevices[device.id] = profile
                profilesChanged = true
            }
        }
        rebuildDeviceList()
        discoveryStatus = nearby.isEmpty ? "Searching nearby devices" : "\(onlineDeviceIDs.count) nearby device\(onlineDeviceIDs.count == 1 ? "" : "s")"
        if profilesChanged { persistConversationHistory() }
    }

    /// Remember peers after connecting or exchanging content, not every passerby.
    func rememberDevice(_ device: NearbyDevice) {
        let profile = device.historyProfile
        guard knownDevices[device.id] != profile else { return }
        knownDevices[device.id] = profile
        rebuildDeviceList()
        persistConversationHistory()
    }

    private func rememberPeer(_ peerID: UUID) {
        let device = nearbyDevices.first { $0.id == peerID }
            ?? knownDevices[peerID]
            ?? .historicalPlaceholder(id: peerID)
        knownDevices[peerID] = device.historyProfile
        rebuildDeviceList()
    }

    private func rebuildDeviceList() {
        var visible = knownDevices
        for device in nearbyDevices { visible[device.id] = device }
        devices = visible.values.sorted { lhs, rhs in
            let lhsOnline = isDeviceOnline(lhs.id)
            let rhsOnline = isDeviceOnline(rhs.id)
            if lhsOnline != rhsOnline { return lhsOnline }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }

    func start() {
        guard discoveryTask == nil, discoveryRestartTask == nil else { return }
        logger.info("Starting local discovery and listener")
        Task {
            transfers = await transferActor.restoreHistory()
        }
        discoveryTask = Task { [weak self, discovery] in
            let updates = await discovery.deviceUpdates()
            for await devices in updates {
                guard !Task.isCancelled else { return }
                self?.updateNearbyDevices(devices)
            }
        }
        incomingConnectionTask = Task { [weak self, discovery] in
            let connections = await discovery.incomingConnections()
            for await connection in connections {
                guard !Task.isCancelled else { return }
                await self?.accept(connection)
            }
        }
    }

    /// iOS may suspend Bonjour while the app is in the background. Recreate the
    /// browser/listener when the scene becomes active again so peers can see us
    /// without requiring a force quit or reinstall.
    func resumeAfterBackground() {
        guard appWasBackgrounded else { return }
        appWasBackgrounded = false
        logger.info("Scene became active; rebuilding Bonjour discovery streams")
        discoveryRestartTask?.cancel()
        discoveryTask?.cancel()
        discoveryTask = nil
        incomingConnectionTask?.cancel()
        incomingConnectionTask = nil
        updateNearbyDevices([])
        discoveryRestartTask = Task { [weak self] in
            guard let self else { return }
            await discovery.stop()
            discoveryRestartTask = nil
            start()
        }
    }

    func appDidEnterBackground() {
        guard !appWasBackgrounded else { return }
        appWasBackgrounded = true
        logger.info("Scene entered background; invalidating control connections before iOS suspends networking")
        invalidateControlConnections(reason: "The app entered the background")
    }

    func stop() {
        logger.info("Stopping discovery and active connections")
        updateNearbyDevices([])
        discoveryTask?.cancel()
        discoveryTask = nil
        incomingConnectionTask?.cancel()
        incomingConnectionTask = nil
        invalidateControlConnections(reason: "The app stopped")
        outboundFileServers.values.forEach { server in
            Task { await server.stop() }
        }
        outboundFileServers.removeAll()
        outboundFileAccess.values.forEach { access in
            if access.needsSecurityScope { access.url.stopAccessingSecurityScopedResource() }
        }
        outboundFileAccess.removeAll()
        incomingOffers.removeAll()
        Task { await discovery.stop() }
    }

    func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let selectedDeviceID else {
            appendMessage("Select a nearby device before sending.")
            return
        }
        guard isDeviceOnline(selectedDeviceID) else {
            appendMessage("Could not send: device is offline. Your draft is kept.", peerID: selectedDeviceID)
            return
        }
        Task {
            do {
                let connection = try await connection(for: selectedDeviceID)
                let envelope = NearLinkEnvelope(type: .textMessage, payload: TextMessagePayload(text: text))
                try await sendMessageAndWaitForAcknowledgement(envelope, over: connection)
                messageText = ""
                appendMessage("You: \(text)", peerID: selectedDeviceID)
            } catch {
                appendMessage("Message failed: \(error.localizedDescription). Your draft is kept.", peerID: selectedDeviceID)
            }
        }
    }

    func stageFile(_ fileURL: URL) {
        guard let selectedDeviceID else {
            appendMessage("Select a nearby device before offering a file.")
            return
        }
        guard isDeviceOnline(selectedDeviceID) else {
            appendMessage("Could not send file: device is offline.", peerID: selectedDeviceID)
            return
        }
        let needsSecurityScope = fileURL.startAccessingSecurityScopedResource()
        Task { [weak self] in
            guard let self else { return }
            var transferID: UUID?
            var server: OutboundFileServer?
            do {
                let connection = try await connection(for: selectedDeviceID)
                let snapshot = try await transferActor.prepare(fileURL: fileURL, mimeType: UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType)
                transferID = snapshot.id
                logger.info("Prepared outgoing file \(fileURL.lastPathComponent, privacy: .public)")
                transferFileURLs[snapshot.id] = fileURL
                transfers = await transferActor.allSnapshots()
                transferPeerIDs[snapshot.id] = selectedDeviceID
                appendTransferItem(snapshot.id, peerID: selectedDeviceID, isIncoming: false)
                guard let streamToken = snapshot.descriptor.streamToken,
                      let tokenExpiresAt = snapshot.descriptor.streamTokenExpiresAt else {
                    throw NearLinkError.connectionFailed("Could not create a transfer authorization token")
                }
                let transferServer = OutboundFileServer(
                    fileURL: fileURL,
                    streamToken: streamToken,
                    tokenExpiresAt: tokenExpiresAt
                ) { [weak self] completedBytes in
                    Task { @MainActor in
                        await self?.updateTransferProgress(snapshot.id, completedBytes: completedBytes)
                        try? await connection.send(NearLinkEnvelope(
                            type: .transferProgress,
                            payload: TransferProgressPayload(transferID: snapshot.id, completedBytes: completedBytes)
                        ))
                    }
                }
                server = transferServer
                let port = try await transferServer.start()
                let offeredSnapshot = try await transferActor.setStreamPort(snapshot.id, port: port)
                logger.info("Offering \(fileURL.lastPathComponent, privacy: .public) with \(offeredSnapshot.descriptor.fileSize, privacy: .public) bytes on data port \(port, privacy: .public)")
                _ = try await transferActor.transition(snapshot.id, to: .waitingForAcceptance)
                try await connection.send(NearLinkEnvelope(type: .fileOffer, payload: FileOfferPayload(transfer: offeredSnapshot.descriptor)))
                outboundFileServers[snapshot.id] = transferServer
                outboundFileAccess[snapshot.id] = OutgoingFileAccess(url: fileURL, needsSecurityScope: needsSecurityScope)
                transfers = await transferActor.allSnapshots()
            } catch {
                logger.error("Could not prepare outgoing file: \(error.localizedDescription, privacy: .public)")
                if let server { await server.stop() }
                if let transferID {
                    _ = try? await transferActor.transition(transferID, to: .failed, errorDescription: error.localizedDescription)
                    transfers = await transferActor.allSnapshots()
                }
                if needsSecurityScope { fileURL.stopAccessingSecurityScopedResource() }
                appendMessage("Could not prepare \(fileURL.lastPathComponent): \(error.localizedDescription)", peerID: selectedDeviceID)
            }
        }
    }

    func stageFiles(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        guard fileURLs.count <= Self.maximumBatchTransferCount else {
            appendMessage("Choose up to \(Self.maximumBatchTransferCount) files at a time.", peerID: selectedDeviceID)
            return
        }
        fileURLs.forEach(stageFile)
    }

    func stagePhotoData(_ data: Data, contentType: UTType? = nil) {
        guard let selectedDeviceID else {
            appendMessage("Select a nearby device before offering a photo.")
            return
        }
        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NearLink-Staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let fileExtension = contentType?.preferredFilenameExtension ?? "jpg"
            let photoURL = stagingDirectory.appendingPathComponent("photo-\(UUID().uuidString).\(fileExtension)")
            try data.write(to: photoURL, options: .atomic)
            logger.notice("Staged selected photo: \(data.count, privacy: .public) bytes; preparing transfer")
            stageFile(photoURL)
        } catch {
            logger.error("Could not stage selected photo: \(error.localizedDescription, privacy: .public)")
            appendMessage("Could not stage selected photo: \(error.localizedDescription)", peerID: selectedDeviceID)
        }
    }

    func isIncoming(_ transferID: UUID) -> Bool { incomingOffers[transferID] != nil }

    func acceptIncomingTransfer(_ transferID: UUID) {
        guard let offer = incomingOffers[transferID] else { return }
        Task { [weak self] in
            guard let self else { return }
                guard let port = offer.descriptor.streamPort,
                      let streamToken = offer.descriptor.streamToken,
                      let tokenExpiresAt = offer.descriptor.streamTokenExpiresAt,
                      let host = await offer.connection.remoteHost() else {
                    await failIncomingTransfer(transferID, reason: "The sender did not provide an authorized file stream.")
                return
            }
            do {
                _ = try await transferActor.transition(transferID, to: .transferring)
                transfers = await transferActor.allSnapshots()
                try await offer.connection.send(NearLinkEnvelope(
                    type: .fileAccept,
                    payload: TransferDecisionPayload(transferID: transferID, receivedBytes: 0)
                ))
                let destination = try receivedFileURL(for: offer.descriptor.fileName)
                let receiver = InboundFileReceiver()
                let fileURL = try await receiver.receive(
                    from: host,
                    port: port,
                    into: destination,
                    streamToken: streamToken,
                    tokenExpiresAt: tokenExpiresAt
                ) { [weak self] completedBytes in
                    Task { @MainActor in
                        await self?.updateTransferProgress(transferID, completedBytes: completedBytes)
                    }
                }
                let checksum = try FileHasher.sha256(of: fileURL)
                guard checksum == offer.descriptor.checksum else {
                    throw NearLinkError.checksumMismatch
                }
                _ = await transferActor.updateProgress(transferID, completedBytes: offer.descriptor.fileSize)
                _ = try await transferActor.transition(transferID, to: .completed)
                transfers = await transferActor.allSnapshots()
                incomingOffers.removeValue(forKey: transferID)
                transferFileURLs[transferID] = fileURL
                transfers = await transferActor.allSnapshots()
                await saveMediaToPhotosIfNeeded(fileURL)
                logger.info("Incoming file saved successfully: \(fileURL.path, privacy: .public)")
                // The file is already verified and saved. A peer that closes the
                // control socket immediately after the data stream completes must
                // not turn a successful transfer into a visible failure.
                try? await offer.connection.send(NearLinkEnvelope(
                    type: .transferComplete,
                    payload: TransferDecisionPayload(transferID: transferID, receivedBytes: offer.descriptor.fileSize)
                ))
            } catch {
                await failIncomingTransfer(transferID, reason: error.localizedDescription)
            }
        }
    }

    func rejectIncomingTransfer(_ transferID: UUID) {
        guard let offer = incomingOffers.removeValue(forKey: transferID) else { return }
        Task {
            _ = try? await transferActor.transition(transferID, to: .cancelled)
            transfers = await transferActor.allSnapshots()
            try? await offer.connection.send(NearLinkEnvelope(type: .fileReject, payload: TransferDecisionPayload(transferID: transferID, receivedBytes: 0)))
        }
    }

    private func accept(_ incomingConnection: NWConnection) async {
        let connection = WebSocketConnectionActor(acceptedConnection: incomingConnection)
        do {
            try await connection.accept()
            inboundConnections.append(connection)
            try await connection.send(NearLinkEnvelope(type: .hello, payload: HelloPayload(device: .local)))
            await connection.startHeartbeat()
            observe(connection)
        } catch {
            // Bonjour/NWConnection can deliver a stale or refused socket while
            // another control connection is already healthy. This is not a
            // transfer error and should not pollute the conversation timeline.
        }
    }

    private func observe(_ connection: WebSocketConnectionActor) {
        Task { [weak self] in
            let messages = await connection.receiveMessages()
            for await data in messages {
                self?.handleControlMessage(data, from: connection)
            }
        }
    }

    private func handleControlMessage(_ data: Data, from connection: WebSocketConnectionActor) {
        guard let header = try? JSONDecoder().decode(ControlMessageHeader.self, from: data), header.version == NearLinkProtocol.version else { return }
        logger.debug("Received control frame: \(header.type.rawValue, privacy: .public), id=\(header.messageID.uuidString, privacy: .public)")
        if header.type != .ack, header.type != .heartbeatAck {
            sendAcknowledgement(for: header.messageID, over: connection)
        }
        switch header.type {
        case .textMessage:
            if let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<TextMessagePayload>.self, from: data) {
                let peerID = connectionPeerIDs[ObjectIdentifier(connection)] ?? envelope.payload.senderID
                if let peerID {
                    connectionPeerIDs[ObjectIdentifier(connection)] = peerID
                    logger.debug("Received text from peer \(peerID.uuidString, privacy: .public)")
                    appendMessage("Peer: \(envelope.payload.text)", peerID: peerID, isIncoming: true)
                } else {
                    logger.error("Dropped text because the peer identity is unavailable")
                }
            }
        case .fileOffer:
            guard let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<FileOfferPayload>.self, from: data) else { return }
            Task { @MainActor in
                _ = await transferActor.registerIncoming(envelope.payload.transfer)
                logger.info("Received file offer \(envelope.payload.transfer.fileName, privacy: .public)")
                transfers = await transferActor.allSnapshots()
                incomingOffers[envelope.payload.transfer.id] = IncomingOffer(descriptor: envelope.payload.transfer, connection: connection)
                if let peerID = connectionPeerIDs[ObjectIdentifier(connection)] {
                    transferPeerIDs[envelope.payload.transfer.id] = peerID
                    appendTransferItem(envelope.payload.transfer.id, peerID: peerID, isIncoming: true)
                }
                // The user already opened this device conversation, so accepting
                // the offer immediately keeps the transfer inside the chat flow.
                acceptIncomingTransfer(envelope.payload.transfer.id)
            }
        case .fileAccept:
            if let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<TransferDecisionPayload>.self, from: data) {
                Task {
                    _ = try? await transferActor.transition(envelope.payload.transferID, to: .transferring)
                    transfers = await transferActor.allSnapshots()
                }
            }
        case .fileReject, .transferCancel:
            if let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<TransferDecisionPayload>.self, from: data) {
                Task {
                    _ = try? await transferActor.transition(envelope.payload.transferID, to: .cancelled)
                    transfers = await transferActor.allSnapshots()
                    if let server = outboundFileServers.removeValue(forKey: envelope.payload.transferID) {
                        await server.stop()
                    }
                    releaseOutboundFileAccess(envelope.payload.transferID)
                }
            }
        case .transferProgress:
            if let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<TransferProgressPayload>.self, from: data) {
                Task { await updateTransferProgress(envelope.payload.transferID, completedBytes: envelope.payload.completedBytes) }
            }
        case .transferComplete:
            if let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<TransferDecisionPayload>.self, from: data) {
                Task {
                    _ = await transferActor.updateProgress(envelope.payload.transferID, completedBytes: envelope.payload.receivedBytes)
                    _ = try? await transferActor.transition(envelope.payload.transferID, to: .completed)
                    transfers = await transferActor.allSnapshots()
                    if let server = outboundFileServers.removeValue(forKey: envelope.payload.transferID) {
                        await server.stop()
                    }
                    releaseOutboundFileAccess(envelope.payload.transferID)
                }
            }
        case .heartbeat:
            Task { try? await connection.send(NearLinkEnvelope(type: .heartbeatAck, payload: EmptyPayload())) }
        case .hello:
            if let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<HelloPayload>.self, from: data) {
                let verifiedDevice = envelope.payload.device
                connectionPeerIDs[ObjectIdentifier(connection)] = verifiedDevice.id
                logger.debug("Mapped control connection to \(verifiedDevice.name, privacy: .public) / \(verifiedDevice.id.uuidString, privacy: .public)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let discoveredID = await discovery.reconcileDeviceID(
                        forServiceNamed: verifiedDevice.name,
                        verifiedID: verifiedDevice.id
                    )
                    reconcileDeviceIdentity(
                        discoveredID: discoveredID,
                        verifiedDevice: verifiedDevice
                    )
                }
            }
        case .ack:
            if let envelope = try? ProtocolCodec().decode(NearLinkEnvelope<AckPayload>.self, from: data) {
                resolveMessageAcknowledgement(envelope.payload.messageID)
            }
        case .heartbeatAck:
            break
        default:
            appendMessage("Received \(header.type.rawValue)", isIncoming: true)
        }
    }

    private func receivedFileURL(for fileName: String) throws -> URL {
        #if os(macOS)
        let root = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let base = root
        #else
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let base = root
            .appendingPathComponent("NearLink", isDirectory: true)
            .appendingPathComponent("Received", isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        let candidate = base.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let extensionPart = candidate.pathExtension
        let suffix = UUID().uuidString.prefix(6)
        let uniqueName = extensionPart.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(extensionPart)"
        return base.appendingPathComponent(uniqueName)
    }

    private func connection(for deviceID: UUID) async throws -> WebSocketConnectionActor {
        guard isDeviceOnline(deviceID) else {
            throw NearLinkError.connectionFailed("Device is offline")
        }
        if let connection = outboundConnections[deviceID] {
            if await connection.isConnected() { return connection }
            logger.debug("Replacing stale control connection for \(deviceID.uuidString, privacy: .public)")
            outboundConnections.removeValue(forKey: deviceID)
            connectionPeerIDs.removeValue(forKey: ObjectIdentifier(connection))
            await connection.cancel()
        }
        guard let endpoint = await discovery.endpoint(for: deviceID) else {
            throw NearLinkError.connectionFailed("Nearby device is no longer available")
        }
        let connection = WebSocketConnectionActor(endpoint: endpoint)
        try await connection.connect()
        outboundConnections[deviceID] = connection
        connectionPeerIDs[ObjectIdentifier(connection)] = deviceID
        logger.debug("Opened outbound control connection for \(deviceID.uuidString, privacy: .public)")
        try await connection.send(NearLinkEnvelope(type: .hello, payload: HelloPayload(device: .local)))
        if let device = nearbyDevices.first(where: { $0.id == deviceID }) {
            rememberDevice(device)
        }
        await connection.startHeartbeat()
        observe(connection)
        return connection
    }

    /// Keeps the Bonjour-visible device and every UI-facing reference aligned
    /// with the stable device ID supplied by the control hello.
    /// Without this migration, an incoming message can be stored under the
    /// hello ID while ConversationView filters on a temporary Bonjour UUID.
    func reconcileDeviceIdentity(discoveredID: UUID?, verifiedDevice: NearbyDevice) {
        let fallbackID = nearbyDevices.first(where: { $0.name == verifiedDevice.name })?.id
        let previousID = discoveredID ?? fallbackID

        if let previousID, let index = nearbyDevices.firstIndex(where: { $0.id == previousID }) {
            let current = nearbyDevices[index]
            nearbyDevices[index] = NearbyDevice(
                id: verifiedDevice.id,
                name: current.name,
                platform: verifiedDevice.platform,
                protocolVersion: verifiedDevice.protocolVersion,
                endpointDescription: current.endpointDescription
            )
        }

        if let previousID, previousID != verifiedDevice.id {
            knownDevices.removeValue(forKey: previousID)
        }
        knownDevices[verifiedDevice.id] = verifiedDevice.historyProfile
        onlineDeviceIDs = Set(nearbyDevices.map(\.id))
        rebuildDeviceList()
        guard let previousID, previousID != verifiedDevice.id else {
            persistConversationHistory()
            return
        }
        logger.notice("Migrating UI peer identity \(previousID.uuidString, privacy: .public) → \(verifiedDevice.id.uuidString, privacy: .public)")

        if selectedDeviceID == previousID {
            selectedDeviceID = verifiedDevice.id
        }
        if let connection = outboundConnections.removeValue(forKey: previousID), outboundConnections[verifiedDevice.id] == nil {
            outboundConnections[verifiedDevice.id] = connection
        }
        if let connection = outboundConnections[verifiedDevice.id] {
            connectionPeerIDs[ObjectIdentifier(connection)] = verifiedDevice.id
        }
        if let unreadCount = unreadMessageCounts.removeValue(forKey: previousID) {
            unreadMessageCounts[verifiedDevice.id, default: 0] += unreadCount
        }
        for (transferID, peerID) in transferPeerIDs where peerID == previousID {
            transferPeerIDs[transferID] = verifiedDevice.id
        }
        conversationItems = conversationItems.map { item in
            guard item.peerID == previousID else { return item }
            return ConversationItem(
                id: item.id,
                peerID: verifiedDevice.id,
                timestamp: item.timestamp,
                kind: item.kind,
                isIncoming: item.isIncoming
            )
        }
        persistConversationHistory()
    }

    private func failIncomingTransfer(_ transferID: UUID, reason: String) async {
        if let snapshot = await transferActor.snapshot(for: transferID), snapshot.state == .completed {
            incomingOffers.removeValue(forKey: transferID)
            return
        }
        _ = try? await transferActor.transition(transferID, to: .failed, errorDescription: reason)
        transfers = await transferActor.allSnapshots()
        incomingOffers.removeValue(forKey: transferID)
        logger.error("Incoming transfer failed: \(reason, privacy: .public)")
        appendMessage("File transfer failed: \(reason)", peerID: transferPeerIDs[transferID])
    }

    private func updateTransferProgress(_ transferID: UUID, completedBytes: Int64) async {
        _ = await transferActor.updateProgress(transferID, completedBytes: completedBytes)
        transfers = await transferActor.allSnapshots()
    }

    private func releaseOutboundFileAccess(_ transferID: UUID) {
        guard let access = outboundFileAccess.removeValue(forKey: transferID), access.needsSecurityScope else { return }
        access.url.stopAccessingSecurityScopedResource()
    }

    private func sendAcknowledgement(for messageID: UUID, over connection: WebSocketConnectionActor) {
        Task {
            try? await connection.send(NearLinkEnvelope(type: .ack, payload: AckPayload(messageID: messageID)))
        }
    }

    /// An NWConnection can stay marked ready after iOS has suspended the app.
    /// Clear these sockets on backgrounding so the next foreground send creates
    /// a fresh control channel instead of writing to a stale one.
    private func invalidateControlConnections(reason: String) {
        var seenConnections = Set<ObjectIdentifier>()
        let connections = Array(outboundConnections.values) + inboundConnections
        outboundConnections.removeAll()
        inboundConnections.removeAll()
        connectionPeerIDs.removeAll()
        failAllMessageAcknowledgements(reason: reason)

        for connection in connections where seenConnections.insert(ObjectIdentifier(connection)).inserted {
            Task { await connection.cancel() }
        }
    }

    /// A successful local `send` only means Network accepted the bytes. Wait
    /// for the peer's protocol ACK before adding the message to the history.
    private func sendMessageAndWaitForAcknowledgement(
        _ envelope: NearLinkEnvelope<TextMessagePayload>,
        over connection: WebSocketConnectionActor
    ) async throws {
        let messageID = envelope.messageID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingMessageAcknowledgements[messageID] = continuation
            Task { [weak self] in
                do {
                    try await connection.send(envelope)
                    try await Task.sleep(for: .seconds(6))
                    self?.failMessageAcknowledgement(
                        messageID,
                        reason: "The nearby device did not confirm delivery"
                    )
                } catch {
                    self?.failMessageAcknowledgement(messageID, reason: error.localizedDescription)
                }
            }
        }
    }

    private func resolveMessageAcknowledgement(_ messageID: UUID) {
        pendingMessageAcknowledgements.removeValue(forKey: messageID)?.resume(returning: ())
    }

    private func failMessageAcknowledgement(_ messageID: UUID, reason: String) {
        pendingMessageAcknowledgements.removeValue(forKey: messageID)?.resume(
            throwing: NearLinkError.connectionFailed(reason)
        )
    }

    private func failAllMessageAcknowledgements(reason: String) {
        let acknowledgements = pendingMessageAcknowledgements
        pendingMessageAcknowledgements.removeAll()
        for continuation in acknowledgements.values {
            continuation.resume(throwing: NearLinkError.connectionFailed(reason))
        }
    }

    func fileURL(for transferID: UUID) -> URL? {
        if let url = transferFileURLs[transferID], FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        guard let snapshot = transfers.first(where: { $0.id == transferID }),
              snapshot.state == .completed else { return nil }

        let fileManager = FileManager.default
        #if os(macOS)
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let roots = [
            downloads,
            downloads?.appendingPathComponent("NearLink", isDirectory: true)
                .appendingPathComponent("Received", isDirectory: true)
        ].compactMap { $0 }
        #else
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        let roots = [documents?.appendingPathComponent("NearLink", isDirectory: true)
            .appendingPathComponent("Received", isDirectory: true)].compactMap { $0 }
        #endif

        for root in roots {
            let candidate = root.appendingPathComponent(snapshot.descriptor.fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                transferFileURLs[transferID] = candidate
                return candidate
            }
        }
        return nil
    }

    func transferPeerID(for transferID: UUID) -> UUID? {
        transferPeerIDs[transferID]
    }

    /// Removes a single chat entry and its transfer record, but deliberately
    /// leaves any already-saved file in the user's chosen system location.
    func deleteConversationItem(_ itemID: UUID) {
        guard let item = conversationItems.first(where: { $0.id == itemID }) else { return }
        conversationItems.removeAll { $0.id == itemID }
        persistConversationHistory()

        guard case let .transfer(transferID) = item.kind else { return }
        incomingOffers.removeValue(forKey: transferID)
        transferPeerIDs.removeValue(forKey: transferID)
        transferFileURLs.removeValue(forKey: transferID)
        if let server = outboundFileServers.removeValue(forKey: transferID) {
            Task { await server.stop() }
        }
        if let access = outboundFileAccess.removeValue(forKey: transferID), access.needsSecurityScope {
            access.url.stopAccessingSecurityScopedResource()
        }
        Task { [weak self] in
            guard let self else { return }
            await transferActor.remove(transferID)
            transfers = await transferActor.allSnapshots()
        }
    }

    func deleteTransferRecord(_ transferID: UUID) {
        if let item = conversationItems.first(where: {
            if case let .transfer(id) = $0.kind { return id == transferID }
            return false
        }) {
            deleteConversationItem(item.id)
            return
        }
        transferPeerIDs.removeValue(forKey: transferID)
        transferFileURLs.removeValue(forKey: transferID)
        if let server = outboundFileServers.removeValue(forKey: transferID) {
            Task { await server.stop() }
        }
        if let access = outboundFileAccess.removeValue(forKey: transferID), access.needsSecurityScope {
            access.url.stopAccessingSecurityScopedResource()
        }
        Task { [weak self] in
            guard let self else { return }
            await transferActor.remove(transferID)
            transfers = await transferActor.allSnapshots()
        }
    }

    func conversationPreview(for peerID: UUID) -> ConversationPreview? {
        guard let item = conversationItems.last(where: { $0.peerID == peerID }) else { return nil }
        return ConversationPreview(
            text: previewText(for: item),
            timestamp: item.timestamp,
            unreadCount: unreadMessageCounts[peerID, default: 0]
        )
    }

    private func appendMessage(_ message: String, peerID: UUID? = nil, isIncoming: Bool = false) {
        messages.insert(message, at: 0)
        guard let peerID else { return }
        rememberPeer(peerID)
        conversationItems.append(
            ConversationItem(peerID: peerID, kind: .text(message), isIncoming: isIncoming)
        )
        markConversationUnreadIfNeeded(peerID, isIncoming: isIncoming)
        persistConversationHistory()
    }

    private func appendTransferItem(_ transferID: UUID, peerID: UUID, isIncoming: Bool) {
        rememberPeer(peerID)
        conversationItems.append(
            ConversationItem(peerID: peerID, kind: .transfer(transferID), isIncoming: isIncoming)
        )
        markConversationUnreadIfNeeded(peerID, isIncoming: isIncoming)
        persistConversationHistory()
    }

    private func restoreConversationHistory() {
        let history = conversationStore.load()
        conversationItems = history.items
        unreadMessageCounts = history.unreadCounts
        for device in history.devices { knownDevices[device.id] = device.historyProfile }
        let legacyPeerIDs = Set(history.items.map(\.peerID)).filter { peerID in
            guard let device = knownDevices[peerID] else { return true }
            // Earlier versions already wrote these synthetic placeholders to
            // disk. Treat them as legacy too so an upgrade fixes existing rows.
            return device.platform == .unknown && device.name.hasPrefix("Saved device ")
        }
        // v1 saved only peer UUIDs. They could be temporary Bonjour identities,
        // so render their histories together instead of inventing one device per UUID.
        if !legacyPeerIDs.isEmpty {
            let legacyID = Self.legacyHistoryDeviceID
            legacyPeerIDs.forEach { knownDevices.removeValue(forKey: $0) }
            knownDevices[legacyID] = NearbyDevice(id: legacyID, name: "Previous device records", platform: .unknown)
            conversationItems = conversationItems.map { item in
                guard legacyPeerIDs.contains(item.peerID) else { return item }
                return ConversationItem(id: item.id, peerID: legacyID, timestamp: item.timestamp, kind: item.kind, isIncoming: item.isIncoming)
            }
            let legacyUnread = legacyPeerIDs.reduce(0) { $0 + (unreadMessageCounts.removeValue(forKey: $1) ?? 0) }
            if legacyUnread > 0 { unreadMessageCounts[legacyID] = legacyUnread }
            for (transferID, peerID) in transferPeerIDs where legacyPeerIDs.contains(peerID) {
                transferPeerIDs[transferID] = legacyID
            }
            persistConversationHistory()
        }
        for item in conversationItems {
            if case let .transfer(transferID) = item.kind {
                transferPeerIDs[transferID] = item.peerID
            }
        }
        rebuildDeviceList()
    }

    private func persistConversationHistory() {
        conversationStore.save(items: conversationItems, unreadCounts: unreadMessageCounts, devices: Array(knownDevices.values))
    }

    private func markConversationUnreadIfNeeded(_ peerID: UUID, isIncoming: Bool) {
        guard isIncoming, selectedDeviceID != peerID else { return }
        unreadMessageCounts[peerID, default: 0] += 1
    }

    private func markConversationRead(for peerID: UUID) {
        guard unreadMessageCounts.removeValue(forKey: peerID) != nil else { return }
        persistConversationHistory()
    }

    private func previewText(for item: ConversationItem) -> String {
        switch item.kind {
        case let .text(message):
            return message
                .replacingOccurrences(of: "You: ", with: "")
                .replacingOccurrences(of: "Peer: ", with: "")
        case let .transfer(transferID):
            let mimeType = transfers.first(where: { $0.id == transferID })?.descriptor.mimeType
            let label: String
            if let mimeType, let type = UTType(mimeType: mimeType), type.conforms(to: .image) {
                label = "photo"
            } else if let mimeType, let type = UTType(mimeType: mimeType), type.conforms(to: .movie) {
                label = "video"
            } else {
                label = "file"
            }
            return item.isIncoming ? "Received \(label)" : "Sent \(label)"
        }
    }

    #if os(iOS)
    private func saveMediaToPhotosIfNeeded(_ fileURL: URL) async {
        guard let type = UTType(filenameExtension: fileURL.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) else { return }

        let authorization: PHAuthorizationStatus
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            authorization = .authorized
        case .notDetermined:
            authorization = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
        default:
            authorization = .denied
        }
        guard authorization == .authorized || authorization == .limited else { return }

        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                if type.conforms(to: .image) {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                } else if type.conforms(to: .movie) {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                }
            }) { _, _ in
                continuation.resume()
            }
        }
    }
    #else
    private func saveMediaToPhotosIfNeeded(_ fileURL: URL) async {}
    #endif
}

private struct ControlMessageHeader: Decodable {
    let version: Int
    let type: NearLinkMessageType
    let messageID: UUID
}

private struct IncomingOffer {
    let descriptor: TransferDescriptor
    let connection: WebSocketConnectionActor
}

private struct OutgoingFileAccess {
    let url: URL
    let needsSecurityScope: Bool
}
