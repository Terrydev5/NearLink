//
//  ContentView.swift
//  NearLink
//
//  Created by Terry on 2026/9/14.
//

import SwiftUI
import Combine
import OSLog
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
import AVKit
import PhotosUI
import QuickLook
import UIKit
#else
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var model: NearLinkAppModel
    @State private var isImportingFile = false

    var body: some View {
        NavigationSplitView {
            nearbyColumn
        } detail: {
            if let selectedDevice {
                ConversationView(model: model, device: selectedDevice) {
                    isImportingFile = true
                }
            } else {
                DetailEmptyState(discoveryStatus: model.discoveryStatus)
            }
        }
        .task { model.start() }
        #if os(macOS)
        .onDisappear { model.stop() }
        #endif
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.data, .image, .movie],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            model.stageFiles(urls)
        }
    }

    private var nearbyColumn: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("My device")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                LocalDeviceCard()

                Divider()

                HStack {
                    Text("Nearby devices")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Searching nearby devices")
                }

                if model.devices.isEmpty {
                    NearbyEmptyState(status: model.discoveryStatus)
                } else {
                    ForEach(model.devices) { device in
                        DeviceRow(
                            device: device,
                            isOnline: model.isDeviceOnline(device.id),
                            preview: model.conversationPreview(for: device.id)
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedDeviceID = device.id
                            }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("NearLink")
        .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        #else
        List(selection: $model.selectedDeviceID) {
            Section {
                LocalDeviceCard()
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } header: {
                Text("My device")
            }

            Section {
                if model.devices.isEmpty {
                    NearbyEmptyState(status: model.discoveryStatus)
                        .listRowInsets(EdgeInsets(top: 20, leading: 12, bottom: 20, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(model.devices) { device in
                        DeviceRow(
                            device: device,
                            isOnline: model.isDeviceOnline(device.id),
                            preview: model.conversationPreview(for: device.id)
                        )
                            .tag(device.id)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            } header: {
                HStack {
                    Text("Nearby devices")
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Searching nearby devices")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("NearLink")
        #endif
    }

    private var selectedDevice: NearbyDevice? {
        guard let selectedDeviceID = model.selectedDeviceID else { return nil }
        return model.devices.first { $0.id == selectedDeviceID }
    }
}

private struct LocalDeviceCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: localDeviceSymbol)
                .font(.title2)
                .frame(width: 48, height: 48)
                .foregroundStyle(.blue)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(localDeviceName)
                    .font(.headline)
                Label("Ready to receive", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localDeviceName + ", ready to receive")
    }

    private var localDeviceName: String {
        #if os(macOS)
        "This Mac"
        #else
        "This iPhone"
        #endif
    }

    private var localDeviceSymbol: String {
        #if os(macOS)
        "laptopcomputer"
        #else
        "iphone"
        #endif
    }
}

private struct DeviceRow: View {
    let device: NearbyDevice
    let isOnline: Bool
    let preview: ConversationPreview?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.platform.symbolName)
                .font(.title2)
                .frame(width: 48, height: 48)
                .foregroundStyle(.blue)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                if let preview {
                    Text(preview.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(device.platform.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                DeviceStatusBadge(isOnline: isOnline)
                if let preview {
                    Text(preview.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if preview.unreadCount > 0 {
                        Text(preview.unreadCount > 99 ? "99+" : "\(preview.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .padding(.horizontal, 5)
                            .background(.red, in: Capsule())
                            .accessibilityLabel("\(preview.unreadCount) unread messages")
                    }
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let status = isOnline ? "online" : "offline"
        guard let preview else { return device.name + ", " + device.platform.displayName + ", " + status }
        let unread = preview.unreadCount == 0 ? "" : ", \(preview.unreadCount) unread messages"
        return device.name + ", " + status + ", " + preview.text + unread
    }
}

private struct DeviceStatusBadge: View {
    let isOnline: Bool

    private var color: Color { isOnline ? .green : .red }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(isOnline ? "Online" : "Offline")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOnline ? "Device online" : "Device offline")
    }
}

private struct NearbyEmptyState: View {
    let status: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("No nearby devices")
                .font(.headline)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private struct DetailEmptyState: View {
    let discoveryStatus: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.blue)
            Text("Choose a device")
                .font(.title3.weight(.semibold))
            Text("Select a device to view its history or send messages and files when it is online.\n\(discoveryStatus)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ConversationView: View {
    @ObservedObject var model: NearLinkAppModel
    let device: NearbyDevice
    let chooseFile: () -> Void
    @FocusState private var isComposerFocused: Bool
    @State private var previewTransfer: TransferPreview?
    private var isOnline: Bool { model.isDeviceOnline(device.id) }
    #if os(iOS)
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isChoosingPhoto = false
    @State private var isLoadingPhoto = false
    @State private var photoImportProgress = 0
    @State private var photoImportError: String?
    private let photoLogger = Logger(subsystem: "cn.terrydev.NearLink", category: "photo-import")
    #endif

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if peerConversationItems.isEmpty {
                        if peerTransfers.isEmpty {
                            ConversationEmptyState(deviceName: device.name, isOnline: isOnline)
                        } else {
                            ForEach(peerTransfers) { transfer in
                                TransferCard(
                                    transfer: transfer,
                                    isIncoming: false,
                                    localURL: model.fileURL(for: transfer.id),
                                    onOpen: {
                                        guard let url = model.fileURL(for: transfer.id) else { return }
                                        #if os(iOS)
                                        previewTransfer = TransferPreview(url: url)
                                        #else
                                        NSWorkspace.shared.open(url)
                                        #endif
                                    },
                                    onShowInFolder: {
                                        guard let url = model.fileURL(for: transfer.id) else { return }
                                        #if os(macOS)
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                        #endif
                                    },
                                    onAccept: { model.acceptIncomingTransfer(transfer.id) },
                                    onReject: { model.rejectIncomingTransfer(transfer.id) },
                                    onDelete: { model.deleteTransferRecord(transfer.id) }
                                )
                            }
                        }
                    } else {
                        ForEach(peerConversationItems) { item in
                            conversationItemView(item)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture {
                isComposerFocused = false
            }
            .onAppear {
                scrollProxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: peerConversationItems.count) { _ in
                withAnimation {
                    scrollProxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: peerTransfers.count) { _ in
                withAnimation {
                    scrollProxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !isOnline {
                    Text("Device is offline. You can still view your conversation and saved files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
                #if os(iOS)
                if isLoadingPhoto {
                    ProgressView("Loading photos… \(photoImportProgress)/\(selectedPhotos.count)")
                        .padding(8)
                }
                ComposerBar(
                    text: $model.messageText,
                    isFocused: $isComposerFocused,
                    canSend: isOnline,
                    chooseFile: chooseFile,
                    send: model.sendMessage,
                    choosePhoto: {
                        isComposerFocused = false
                        photoLogger.notice("Choose Photo tapped; requesting photo picker")
                        isChoosingPhoto = true
                    }
                )
                #else
                ComposerBar(
                    text: $model.messageText,
                    isFocused: $isComposerFocused,
                    canSend: isOnline,
                    chooseFile: chooseFile,
                    send: model.sendMessage
                )
                #endif
            }
        }
        .navigationTitle(device.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DeviceStatusBadge(isOnline: isOnline)
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isComposerFocused = false
                }
            }
        }
        #endif
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            guard isOnline, !urls.isEmpty else { return false }
            model.stageFiles(urls)
            return true
        }
        #endif
        #if os(iOS)
        // Keep the presenter outside Menu: its content disappears after a choice.
        .photosPicker(
            isPresented: $isChoosingPhoto,
            selection: $selectedPhotos,
            maxSelectionCount: 10,
            matching: .images
        )
        .task(id: selectedPhotos) {
            guard !selectedPhotos.isEmpty else { return }
            await importPhotos(selectedPhotos)
        }
        .alert("Could Not Load Photo", isPresented: Binding(
            get: { photoImportError != nil },
            set: { if !$0 { photoImportError = nil } }
        )) {
            Button("OK", role: .cancel) { photoImportError = nil }
        } message: {
            Text(photoImportError ?? "Please try selecting the photo again.")
        }
        .sheet(item: $previewTransfer) { preview in
            TransferPreviewSheet(url: preview.url)
        }
        #endif
    }

    #if os(iOS)
    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !Task.isCancelled else { return }
        isLoadingPhoto = true
        photoImportProgress = 0
        photoLogger.notice("\(items.count, privacy: .public) photo(s) selected; loading image data")
        defer {
            // A cancelled load must not clear a newer selection or its progress.
            if selectedPhotos == items {
                isLoadingPhoto = false
                photoImportProgress = 0
                selectedPhotos.removeAll()
            }
        }
        var failures = 0
        for (index, item) in items.enumerated() {
            guard !Task.isCancelled else { return }
            do {
                guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                let contentType = item.supportedContentTypes.first { $0.conforms(to: .image) }
                photoLogger.notice("Loaded photo \(index + 1, privacy: .public)/\(items.count, privacy: .public): \(data.count, privacy: .public) bytes")
                model.stagePhotoData(data, contentType: contentType)
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                photoLogger.error("Could not load selected photo: \(error.localizedDescription, privacy: .public)")
            }
            photoImportProgress = index + 1
        }
        if failures > 0 {
            photoImportError = failures == 1
                ? "One selected photo could not be loaded. Please try it again."
                : "\(failures) selected photos could not be loaded. Please try them again."
        }
    }
    #endif

    @ViewBuilder
    private func conversationItemView(_ item: ConversationItem) -> some View {
        switch item.kind {
        case let .text(message):
            MessageBubble(message: message)
                .contextMenu {
                    Button {
                        copyToPasteboard(copyableMessageText(message))
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button("Delete", role: .destructive) {
                        model.deleteConversationItem(item.id)
                    }
                }
        case let .transfer(transferID):
            if let transfer = model.transfers.first(where: { $0.id == transferID }) {
                TransferCard(
                    transfer: transfer,
                    isIncoming: item.isIncoming,
                    localURL: model.fileURL(for: transferID),
                    onOpen: {
                        guard let url = model.fileURL(for: transferID) else { return }
                        #if os(iOS)
                        previewTransfer = TransferPreview(url: url)
                        #else
                        NSWorkspace.shared.open(url)
                        #endif
                    },
                    onShowInFolder: {
                        guard let url = model.fileURL(for: transferID) else { return }
                        #if os(macOS)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        #endif
                    },
                    onAccept: { model.acceptIncomingTransfer(transferID) },
                    onReject: { model.rejectIncomingTransfer(transferID) },
                    onDelete: { model.deleteConversationItem(item.id) }
                )
            }
        }
    }

    private func copyableMessageText(_ message: String) -> String {
        if message.hasPrefix("You: ") { return String(message.dropFirst(5)) }
        if message.hasPrefix("Peer: ") { return String(message.dropFirst(6)) }
        return message
    }

    private func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private var peerConversationItems: [ConversationItem] {
        model.conversationItems.filter { $0.peerID == device.id }
    }

    private var peerTransfers: [TransferSnapshot] {
        model.transfers.filter { model.transferPeerID(for: $0.id) == device.id }
    }
}

private struct ConversationEmptyState: View {
    let deviceName: String
    let isOnline: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2)
                .foregroundStyle(.blue)
            Text(isOnline ? "Start a conversation" : "No messages yet")
                .font(.headline)
            Text(isOnline ? "Send a message or attach a file to \(deviceName)." : "You can send messages and files when \(deviceName) is online again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct MessageBubble: View {
    let message: String

    private var isOutgoing: Bool { message.hasPrefix("You: ") }
    private var isSystemMessage: Bool {
        ["Offered ", "Received file offer:", "Saved ", "Could not ", "Message failed:", "Select "]
            .contains { message.hasPrefix($0) }
    }
    private var displayText: String {
        if message.hasPrefix("You: ") { return String(message.dropFirst(5)) }
        if message.hasPrefix("Peer: ") { return String(message.dropFirst(6)) }
        return message
    }

    var body: some View {
        if isSystemMessage {
            Text(displayText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        } else {
            HStack {
                if isOutgoing { Spacer(minLength: 40) }
                Text(displayText)
                    .font(.body)
                    .foregroundStyle(isOutgoing ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isOutgoing ? Color.blue : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if !isOutgoing { Spacer(minLength: 40) }
            }
        }
    }
}

private struct ComposerBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let canSend: Bool
    let chooseFile: () -> Void
    let send: () -> Void
    #if os(iOS)
    let choosePhoto: () -> Void
    #endif

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                #if os(iOS)
                Button(action: choosePhoto) {
                    Label("Choose Photos (up to 10)", systemImage: "photo")
                }
                Divider()
                #endif
                Button(action: chooseFile) {
                    Label("Choose Files (up to 10)", systemImage: "doc")
                }
            } label: {
                Image(systemName: "paperclip")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Attach up to 10 photos or files")
            .disabled(!canSend)

            TextField(canSend ? "Write a message" : "Device is offline", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused(isFocused)
                .submitLabel(.done)
                .onSubmit {
                    isFocused.wrappedValue = false
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .disabled(!canSend)

            Button {
                send()
                isFocused.wrappedValue = false
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.blue : Color.secondary.opacity(0.35), in: Circle())
            }
            .disabled(!canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

private struct TransferPreview: Identifiable {
    let id = UUID()
    let url: URL
}

private struct TransferCard: View {
    let transfer: TransferSnapshot
    let isIncoming: Bool
    let localURL: URL?
    let onOpen: () -> Void
    let onShowInFolder: () -> Void
    let onAccept: () -> Void
    let onReject: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            if transfer.state == .completed, localURL != nil {
                Button(action: onOpen) {
                    cardContent
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to preview")
            } else {
                cardContent
            }
        }
        .contextMenu {
            #if os(macOS)
            if transfer.state == .completed, localURL != nil {
                Button("Open") {
                    onOpen()
                }
                Button("Show in Finder") {
                    onShowInFolder()
                }
            }
            Divider()
            #endif
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: fileSymbol)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.descriptor.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: transfer.descriptor.fileSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(stateTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: transfer.progress)
                .tint(statusColor)

            if isIncoming, transfer.state == .waitingForAcceptance {
                HStack(spacing: 10) {
                    Button("Decline", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                    Button("Accept", action: onAccept)
                        .buttonStyle(.borderedProminent)
                }
            }

            if transfer.state == .completed, localURL != nil {
                Label("Tap to preview", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    private var fileSymbol: String {
        guard let mimeType = transfer.descriptor.mimeType,
              let type = UTType(mimeType: mimeType) else { return "doc.fill" }
        if type.conforms(to: .image) { return "photo.fill" }
        if type.conforms(to: .movie) { return "film.fill" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext.fill" }
        return "doc.fill"
    }

    private var stateTitle: String {
        switch transfer.state {
        case .idle: "Ready"
        case .preparing: isIncoming ? "Preparing to receive" : "Preparing"
        case .waitingForAcceptance: isIncoming ? "Accept?" : "Waiting…"
        case .transferring: isIncoming ? "Receiving…" : "Sending…"
        case .paused: "Paused"
        case .completed: isIncoming ? "Saved" : "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var statusColor: Color {
        switch transfer.state {
        case .completed: .green
        case .failed, .cancelled: .red
        case .transferring: .blue
        default: .secondary
        }
    }
}

#if os(iOS)
private struct TransferPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var videoPlayer: AVPlayer
    @StateObject private var audioPlayer: AudioPlaybackModel

    init(url: URL) {
        self.url = url
        _videoPlayer = State(initialValue: AVPlayer(url: url))
        _audioPlayer = StateObject(wrappedValue: AudioPlaybackModel(url: url))
    }

    var body: some View {
        NavigationStack {
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isImage ? Color.black : Color(uiColor: .systemBackground))
                .navigationTitle(url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(isImage ? .dark : .light, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if isImage, let image = UIImage(contentsOfFile: url.path) {
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .background(Color.black)
        } else if isMovie {
            VideoPlayer(player: videoPlayer)
                .onDisappear { videoPlayer.pause() }
        } else if isAudio {
            AudioPreview(player: audioPlayer, fileName: url.lastPathComponent)
        } else {
            QuickLookPreview(url: url)
        }
    }

    private var contentType: UTType? {
        UTType(filenameExtension: url.pathExtension)
    }

    private var isImage: Bool { contentType?.conforms(to: .image) == true }
    private var isMovie: Bool { contentType?.conforms(to: .movie) == true }
    private var isAudio: Bool { contentType?.conforms(to: .audio) == true }
}

private struct AudioPreview: View {
    @ObservedObject var player: AudioPlaybackModel
    let fileName: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
            Text(fileName)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button {
                player.toggle()
            } label: {
                Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private final class AudioPlaybackModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer?
    @Published private(set) var isPlaying = false

    init(url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        super.init()
        player?.delegate = self
        player?.prepareToPlay()
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

private extension DevicePlatform {
    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .android: "Android"
        case .windows: "Windows"
        case .unknown: "Saved device"
        }
    }

    var symbolName: String {
        switch self {
        case .macOS: "laptopcomputer"
        case .iOS: "iphone"
        case .android: "apps.iphone"
        case .windows: "desktopcomputer"
        case .unknown: "network"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(NearLinkAppModel())
}

#Preview("Device presence") {
    VStack(spacing: 12) {
        DeviceRow(
            device: NearbyDevice(name: "MacBook Pro", platform: .macOS),
            isOnline: true,
            preview: ConversationPreview(text: "Sent file", timestamp: .distantPast, unreadCount: 0)
        )
        DeviceRow(
            device: NearbyDevice(name: "iPhone", platform: .iOS),
            isOnline: false,
            preview: ConversationPreview(text: "See you tomorrow", timestamp: .distantPast, unreadCount: 2)
        )
    }
    .padding()
    .frame(width: 370)
}
