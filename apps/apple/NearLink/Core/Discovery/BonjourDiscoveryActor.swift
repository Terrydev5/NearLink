@preconcurrency import Network
import Foundation
import OSLog

/// Owns the local Bonjour advertisement and discovery browser. UI reads the async stream,
/// so Network callbacks never mutate SwiftUI state directly.
actor BonjourDiscoveryActor {
    private let localDevice: NearbyDevice
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: AsyncStream<[NearbyDevice]>.Continuation?
    private var incomingConnectionContinuation: AsyncStream<NWConnection>.Continuation?
    private var knownDeviceIDs: [String: UUID] = [:]
    private var endpoints: [UUID: NWEndpoint] = [:]
    private let logger = Logger(subsystem: "cn.terrydev.NearLink", category: "bonjour")

    init(localDevice: NearbyDevice) {
        self.localDevice = localDevice
    }

    func deviceUpdates() -> AsyncStream<[NearbyDevice]> {
        AsyncStream { continuation in
            self.continuation = continuation
            startIfNeeded()
        }
    }

    func incomingConnections() -> AsyncStream<NWConnection> {
        AsyncStream { continuation in
            incomingConnectionContinuation = continuation
            startIfNeeded()
        }
    }

    func stop() {
        logger.info("Stopping Bonjour browser and listener")
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        continuation?.finish()
        continuation = nil
        incomingConnectionContinuation?.finish()
        incomingConnectionContinuation = nil
        endpoints.removeAll()
    }

    /// Restart without finishing the async streams owned by the app model.
    /// This is used after iOS returns from the background.
    func restart() {
        logger.info("Restarting Bonjour browser and listener")
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        endpoints.removeAll()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard browser == nil, listener == nil else { return }

        let listenerParameters = webSocketParameters()
        listenerParameters.includePeerToPeer = true
        do {
            let listener = try NWListener(using: listenerParameters)
            let txtRecord = NWTXTRecord([
                "deviceId": localDevice.id.uuidString,
                "platform": localDevice.platform.rawValue,
                "protocolVersion": String(localDevice.protocolVersion)
            ])
            listener.service = NWListener.Service(name: localDevice.name, type: NearLinkProtocol.serviceType, txtRecord: txtRecord)
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.publishIncoming(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.log(listenerState: state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            logger.error("Unable to start Bonjour listener")
            continuation?.finish()
            return
        }

        let browserParameters = webSocketParameters()
        browserParameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NearLinkProtocol.serviceType, domain: nil), using: browserParameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.publish(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        let devices = results.compactMap { result -> NearbyDevice? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            // When the legacy browser API omits TXT metadata, this is the only
            // stable pre-connection signal that the advertised service is ours.
            guard name != localDevice.name else { return nil }
            let record = result.endpoint.txtRecord?.dictionary ?? [:]
            let id = UUID(uuidString: record["deviceId"] ?? "") ?? knownDeviceIDs[name] ?? UUID()
            guard id != localDevice.id else { return nil }
            // Some Network.framework browse results omit TXT records even when the
            // service advertises one. Keep the device visible and verify it with hello.
            let platformValue = record["platform"] ?? inferredPlatform(for: name)
            let platform = DevicePlatform(rawValue: platformValue) ?? .iOS
            let protocolVersion = Int(record["protocolVersion"] ?? "") ?? NearLinkProtocol.version
            guard protocolVersion == NearLinkProtocol.version else { return nil }
            knownDeviceIDs[name] = id
            endpoints[id] = result.endpoint
            return NearbyDevice(
                id: id,
                name: name,
                platform: platform,
                protocolVersion: protocolVersion,
                endpointDescription: String(describing: result.endpoint)
            )
        }
        let sortedDevices = devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        logger.debug("Bonjour discovery updated: \(sortedDevices.count, privacy: .public) peer(s)")
        continuation?.yield(sortedDevices)
    }

    private func inferredPlatform(for name: String) -> String {
        let normalized = name.lowercased()
        if normalized.hasPrefix("android-") || normalized.contains("android") { return DevicePlatform.android.rawValue }
        if normalized.hasPrefix("windows-") || normalized.contains("windows") { return DevicePlatform.windows.rawValue }
        if normalized.hasPrefix("mac") || normalized.contains("macbook") { return DevicePlatform.macOS.rawValue }
        if normalized.hasPrefix("iphone") || normalized.contains("iphone") { return DevicePlatform.iOS.rawValue }
        return DevicePlatform.iOS.rawValue
    }

    func endpoint(for deviceID: UUID) -> NWEndpoint? {
        endpoints[deviceID]
    }

    /// Bonjour occasionally omits TXT metadata from a browse result. In that
    /// case the browser temporarily keys a peer by a generated UUID; `hello`
    /// later supplies the peer's persistent ID. Move the endpoint cache to the
    /// verified identity so connection lookup and the UI use the same key.
    func reconcileDeviceID(forServiceNamed serviceName: String, verifiedID: UUID) -> UUID? {
        let discoveredID = knownDeviceIDs[serviceName]
        knownDeviceIDs[serviceName] = verifiedID

        guard let discoveredID, discoveredID != verifiedID else { return discoveredID }
        if let endpoint = endpoints.removeValue(forKey: discoveredID) {
            endpoints[verifiedID] = endpoint
        }
        logger.debug("Reconciled Bonjour identity for \(serviceName, privacy: .public): \(discoveredID.uuidString, privacy: .public) → \(verifiedID.uuidString, privacy: .public)")
        return discoveredID
    }

    private func publishIncoming(_ connection: NWConnection) {
        logger.debug("Accepted incoming Bonjour connection")
        incomingConnectionContinuation?.yield(connection)
    }

    private func log(listenerState: NWListener.State) {
        logger.debug("Bonjour listener state: \(String(describing: listenerState), privacy: .public)")
    }

    private func webSocketParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        return parameters
    }
}
