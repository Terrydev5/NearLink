import Foundation

actor TransferActor {
    private var transfers: [UUID: TransferSnapshot] = [:]
    private let historyKey = "NearLink.transferHistory.v1"

    func prepare(fileURL: URL, mimeType: String? = nil) throws -> TransferSnapshot {
        let digest = try FileHasher.sha256AndByteCount(of: fileURL)
        let descriptor = TransferDescriptor(
            fileName: fileURL.lastPathComponent,
            fileSize: digest.byteCount,
            checksum: digest.checksum,
            mimeType: mimeType,
            streamToken: try TransferToken.generate(),
            streamTokenExpiresAt: Date().addingTimeInterval(120)
        )
        let snapshot = TransferSnapshot(descriptor: descriptor, state: .preparing, completedBytes: 0)
        transfers[descriptor.id] = snapshot
        return snapshot
    }

    func registerIncoming(_ descriptor: TransferDescriptor, receivedBytes: Int64 = 0) -> TransferSnapshot {
        let snapshot = TransferSnapshot(descriptor: descriptor, state: .waitingForAcceptance, completedBytes: receivedBytes)
        transfers[descriptor.id] = snapshot
        return snapshot
    }

    func transition(_ transferID: UUID, to nextState: TransferState, errorDescription: String? = nil) throws -> TransferSnapshot {
        guard var snapshot = transfers[transferID] else { throw CocoaError(.fileNoSuchFile) }
        guard snapshot.state.canTransition(to: nextState) else {
            throw NearLinkError.invalidTransition(from: snapshot.state, to: nextState)
        }
        snapshot.state = nextState
        snapshot.errorDescription = errorDescription
        transfers[transferID] = snapshot
        persistTerminalHistory()
        return snapshot
    }

    func setStreamPort(_ transferID: UUID, port: UInt16) throws -> TransferSnapshot {
        guard var snapshot = transfers[transferID] else { throw CocoaError(.fileNoSuchFile) }
        snapshot.descriptor.streamPort = port
        transfers[transferID] = snapshot
        return snapshot
    }

    func updateProgress(_ transferID: UUID, completedBytes: Int64) -> TransferSnapshot? {
        guard var snapshot = transfers[transferID] else { return nil }
        snapshot.completedBytes = min(max(0, completedBytes), snapshot.descriptor.fileSize)
        transfers[transferID] = snapshot
        return snapshot
    }

    func remove(_ transferID: UUID) {
        transfers.removeValue(forKey: transferID)
        persistTerminalHistory()
    }

    func snapshot(for transferID: UUID) -> TransferSnapshot? { transfers[transferID] }
    func allSnapshots() -> [TransferSnapshot] { transfers.values.sorted { $0.descriptor.fileName < $1.descriptor.fileName } }

    func restoreHistory() -> [TransferSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let snapshots = try? JSONDecoder().decode([TransferSnapshot].self, from: data) else {
            return allSnapshots()
        }
        for snapshot in snapshots {
            transfers[snapshot.id] = snapshot
        }
        return allSnapshots()
    }

    private func persistTerminalHistory() {
        let terminalStates: Set<TransferState> = [.completed, .failed, .cancelled]
        let history = transfers.values
            .filter { terminalStates.contains($0.state) }
            .sorted { $0.descriptor.fileName < $1.descriptor.fileName }
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }
}
