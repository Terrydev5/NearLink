package com.terrydev.nearlink

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.DataInputStream
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.UUID

private const val TAG = "NearLinkViewModel"
private const val TRANSFER_TOKEN_TTL_MILLIS = 120_000L

private fun persistentDeviceID(app: Application): UUID {
    val preferences = app.getSharedPreferences("nearlink", android.content.Context.MODE_PRIVATE)
    val key = "local_device_id"
    preferences.getString(key, null)
        ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
        ?.let { return it }
    return UUID.randomUUID().also { preferences.edit().putString(key, it.toString()).apply() }
}

class NearLinkViewModel(app: Application) : AndroidViewModel(app) {
    val devices = mutableStateListOf<NearbyDevice>()
    val timeline = mutableStateListOf<ConversationItem>()
    val transfers = mutableStateMapOf<UUID, TransferItem>()
    val unreadMessageCounts = mutableStateMapOf<UUID, Int>()
    val selectedDevice = mutableStateOf<NearbyDevice?>(null)
    val draft = mutableStateOf("")
    val discoveryStatus = mutableStateOf("Starting discovery…")

    val localDeviceName: String
        get() = local.name

    private val local = NearbyDevice(
        id = persistentDeviceID(app),
        name = "Android-${android.os.Build.MODEL}",
        platform = "android",
        host = "127.0.0.1",
        port = NearLinkProtocol.PORT
    )
    private val discovery = NearbyDiscovery(app, local)
    private val storage = NearLinkFileStorage(app)
    private val conversationStore = NearLinkConversationStore(app)
    private val transport = NearLinkTransport(
        localDevice = local,
        messageHandler = { peerID, raw -> handleControlMessage(raw, null, "", peerID) },
        errorHandler = { message -> appendSystemMessage(message) }
    )
    private val server = NearLinkServer { raw, sendControl, remoteHost ->
        handleControlMessage(raw, sendControl, remoteHost)
    }
    private val outgoingTransfers = mutableMapOf<UUID, OutgoingTransfer>()
    private val incomingTransfers = mutableMapOf<UUID, IncomingTransfer>()
    private val sessionPeerIDs = mutableMapOf<String, UUID>()
    private var started = false

    init {
        restoreConversationHistory()
    }

    fun start() {
        if (started) return
        started = true
        Log.i(TAG, "Starting Nearby discovery as ${local.name} (${local.id})")
        server.start()
        discovery.start(
            onChanged = { found ->
                devices.clear()
                devices.addAll(found.filter { it.id != local.id && it.name != local.name })
            },
            onStatus = { status -> discoveryStatus.value = status }
        )
    }

    fun stageFile(uri: Uri) {
        val target = selectedDevice.value ?: run {
            appendSystemMessage("Select a nearby device before choosing a file")
            return
        }
        val resolver = getApplication<Application>().contentResolver
        runCatching {
            resolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        viewModelScope.launch(Dispatchers.IO) {
            var transferID: UUID? = null
            var serverSocket: ServerSocket? = null
            try {
                val metadata = queryFile(uri)
                val checksum = sha256(uri)
                val streamToken = TransferToken.generate()
                val streamTokenExpiresAt = System.currentTimeMillis() + TRANSFER_TOKEN_TTL_MILLIS
                transferID = UUID.randomUUID()
                val socket = ServerSocket(0)
                socket.soTimeout = 1_000
                serverSocket = socket
                synchronized(outgoingTransfers) {
                    outgoingTransfers[transferID!!] = OutgoingTransfer(
                        transferID!!, uri, metadata.name, metadata.size, checksum, metadata.mimeType,
                        streamToken, streamTokenExpiresAt, socket
                    )
                }
                withContext(Dispatchers.Main) {
                    upsertTransfer(
                        TransferItem(
                            id = transferID!!,
                            peerID = target.id,
                            fileName = metadata.name,
                            fileSize = metadata.size,
                            mimeType = metadata.mimeType,
                            completedBytes = 0,
                            status = TransferStatus.WAITING,
                            incoming = false,
                            localUri = uri
                        )
                    )
                    timeline.add(ConversationItem.Transfer(UUID.randomUUID(), target.id, transferID!!))
                    persistConversationHistory()
                }
                Log.d(TAG, "Offering ${metadata.name} (${metadata.size} bytes) to ${target.name} on port ${socket.localPort}")
                transport.sendRaw(
                    target,
                    Envelope.fileOffer(
                        transferID!!,
                        metadata.name,
                        metadata.size,
                        checksum,
                        metadata.mimeType,
                        socket.localPort,
                        streamToken,
                        streamTokenExpiresAt
                    )
                )
            } catch (error: Exception) {
                Log.w(TAG, "Could not prepare outgoing file", error)
                serverSocket?.close()
                transferID?.let { id ->
                    synchronized(outgoingTransfers) { outgoingTransfers.remove(id) }
                    markTransferFailed(id, error.localizedMessage ?: "unknown error")
                }
                withContext(Dispatchers.Main) {
                    appendSystemMessage("Could not prepare file: ${error.localizedMessage ?: "unknown error"}")
                }
            }
        }
    }

    private fun queryFile(uri: Uri): FileMetadata {
        val resolver = getApplication<Application>().contentResolver
        var name = "Selected file"
        var size = 0L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        .takeIf { it >= 0 }
                        ?.let { name = cursor.getString(it) }
                    cursor.getColumnIndex(OpenableColumns.SIZE)
                        .takeIf { it >= 0 && !cursor.isNull(it) }
                        ?.let { size = cursor.getLong(it) }
                }
            }
        return FileMetadata(name, size, resolver.getType(uri))
    }

    private fun sha256(uri: Uri): String {
        val digest = MessageDigest.getInstance("SHA-256")
        getApplication<Application>().contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Could not open selected file" }
            val buffer = ByteArray(NearLinkProtocol.CHUNK_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count <= 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun handleControlMessage(
        raw: String,
        sendControl: (suspend (String) -> Unit)?,
        remoteHost: String,
        transportPeerID: UUID? = null
    ) {
        if (Envelope.version(raw) != NearLinkProtocol.VERSION) {
            Log.w(TAG, "Rejected control frame with unsupported protocol version")
            return
        }
        Log.d(TAG, "Received ${Envelope.type(raw)} from ${remoteHost.ifBlank { transportPeerID?.toString() ?: "unknown peer" }}")
        when (Envelope.type(raw)) {
            "text_message" -> Envelope.textPayload(raw)?.let {
                val peerID = transportPeerID
                    ?: sessionPeerIDs[remoteHost]
                    ?: Envelope.textSenderID(raw)
                appendMessage(it, peerID = peerID, outgoing = false)
            }
            "file_offer" -> {
                val transfer = parseTransferOffer(raw) ?: return
                val sender = sendControl ?: return
                val peerID = transportPeerID ?: sessionPeerIDs[remoteHost]
                beginIncoming(transfer, peerID, remoteHost, sender)
            }
            "file_accept" -> {
                val transferID = transferIDFromPayload(raw) ?: return
                startOutgoing(transferID)
            }
            "transfer_complete" -> {
                val transferID = transferIDFromPayload(raw) ?: return
                viewModelScope.launch(Dispatchers.Main) {
                    transfers[transferID]?.let { current ->
                        upsertTransfer(current.copy(completedBytes = current.fileSize, status = TransferStatus.COMPLETED))
                        persistConversationHistory()
                    }
                }
            }
            "file_reject", "transfer_cancel" -> {
                val transferID = transferIDFromPayload(raw) ?: return
                markTransferCancelled(transferID)
                synchronized(outgoingTransfers) { outgoingTransfers.remove(transferID) }?.server?.close()
            }
            "hello" -> {
                val peer = parseHelloDevice(raw) ?: return
                if (remoteHost.isNotBlank()) sessionPeerIDs[remoteHost] = peer.id
                viewModelScope.launch(Dispatchers.Main) {
                    discovery.reconcileDeviceID(peer.id, remoteHost, peer.name)?.let { provisionalID ->
                        Log.d(TAG, "Reconciled discovered device $provisionalID to ${peer.id}")
                        reconcileDeviceIdentity(provisionalID, peer.id)
                    }
                }
            }
        }
    }

    private fun beginIncoming(
        transfer: TransferOffer,
        peerID: UUID?,
        remoteHost: String,
        sender: suspend (String) -> Unit
    ) {
        viewModelScope.launch(Dispatchers.Main) {
            if (transfers.containsKey(transfer.id)) return@launch
            upsertTransfer(
                TransferItem(
                    id = transfer.id,
                    peerID = peerID,
                    fileName = transfer.fileName,
                    fileSize = transfer.fileSize,
                    mimeType = transfer.mimeType,
                    completedBytes = 0,
                    status = TransferStatus.WAITING,
                    incoming = true,
                    localUri = null
                )
            )
            if (peerID != null) {
                timeline.add(ConversationItem.Transfer(UUID.randomUUID(), peerID, transfer.id))
                markConversationUnreadIfNeeded(peerID, incoming = true)
                persistConversationHistory()
            }
            incomingTransfers[transfer.id] = IncomingTransfer(transfer, remoteHost, sender)
            Log.i(TAG, "Awaiting user approval for incoming ${transfer.fileName} (${transfer.id})")
        }
    }

    fun acceptIncoming(transferID: UUID) {
        val incoming = incomingTransfers.remove(transferID) ?: return
        Log.i(TAG, "Accepted incoming ${incoming.transfer.fileName} ($transferID)")
        updateTransferProgress(transferID, 0, TransferStatus.RECEIVING)
        viewModelScope.launch(Dispatchers.IO) {
            try {
                incoming.sender(Envelope.fileAccept(transferID))
                receiveIncoming(incoming.transfer, incoming.remoteHost, incoming.sender)
            } catch (error: Exception) {
                Log.w(TAG, "Incoming transfer failed: $transferID", error)
                markTransferFailed(transferID, error.localizedMessage ?: "unknown error")
            }
        }
    }

    fun rejectIncoming(transferID: UUID) {
        val incoming = incomingTransfers.remove(transferID) ?: return
        Log.i(TAG, "Rejected incoming ${incoming.transfer.fileName} ($transferID)")
        markTransferCancelled(transferID)
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { incoming.sender(Envelope.fileReject(transferID)) }
                .onFailure { Log.w(TAG, "Could not send file rejection for $transferID", it) }
        }
    }

    private suspend fun receiveIncoming(
        transfer: TransferOffer,
        remoteHost: String,
        sendControl: suspend (String) -> Unit
    ) {
        require(remoteHost.isNotBlank()) { "The sender address is unavailable" }
        require(System.currentTimeMillis() <= transfer.streamTokenExpiresAt) {
            "The transfer authorization token has expired"
        }
        Socket(normalizeHost(remoteHost), transfer.streamPort).use { socket ->
            socket.getOutputStream().apply {
                write((transfer.streamToken + "\n").toByteArray(Charsets.US_ASCII))
                flush()
            }
            socket.getInputStream().use { input ->
                val saved = storage.saveReceivedFile(
                    transfer.fileName,
                    transfer.mimeType,
                    input,
                    transfer.fileSize
                ) { completedBytes ->
                    updateTransferProgress(transfer.id, completedBytes, TransferStatus.RECEIVING)
                }
                require(saved.checksum.equals(transfer.checksum, ignoreCase = true)) {
                    "The received file failed SHA-256 verification"
                }
                updateTransferProgress(transfer.id, transfer.fileSize, TransferStatus.COMPLETED, saved.uri)
                sendControl(Envelope.fileComplete(transfer.id, transfer.fileSize))
            }
        }
    }

    private fun startOutgoing(transferID: UUID) {
        val outgoing = synchronized(outgoingTransfers) { outgoingTransfers[transferID] } ?: return
        updateTransferProgress(transferID, 0, TransferStatus.SENDING)
        viewModelScope.launch(Dispatchers.IO) {
            try {
                acceptAuthorizedClient(outgoing).use { socket ->
                    getApplication<Application>().contentResolver.openInputStream(outgoing.uri).use { input ->
                        requireNotNull(input) { "Could not open selected file" }
                        val output = socket.getOutputStream()
                        val buffer = ByteArray(NearLinkProtocol.CHUNK_SIZE)
                        var completed = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count <= 0) break
                            output.write(buffer, 0, count)
                            completed += count
                            updateTransferProgress(transferID, completed, TransferStatus.SENDING)
                        }
                        output.flush()
                    }
                }
                markTransferCompleted(transferID)
            } catch (error: Exception) {
                markTransferFailed(transferID, error.localizedMessage ?: "unknown error")
            } finally {
                runCatching { outgoing.server.close() }
                synchronized(outgoingTransfers) { outgoingTransfers.remove(transferID) }
            }
        }
    }

    fun send() {
        val text = draft.value.trim()
        val target = selectedDevice.value ?: return
        if (text.isEmpty()) return
        draft.value = ""
        runCatching { transport.sendText(target, text) }
            .onSuccess { appendMessage(text, peerID = target.id, outgoing = true) }
            .onFailure { appendSystemMessage("Message failed: ${it.localizedMessage ?: "unknown error"}") }
    }

    fun transferUri(transferID: UUID): Uri? = transfers[transferID]?.localUri

    fun conversationPreview(peerID: UUID): ConversationPreview? {
        val item = timeline.lastOrNull { it.peerID == peerID } ?: return null
        return ConversationPreview(
            text = previewText(item),
            timestamp = item.timestamp,
            unreadCount = unreadMessageCounts[peerID] ?: 0
        )
    }

    fun selectDevice(device: NearbyDevice) {
        selectedDevice.value = device
        Log.d(TAG, "Opened conversation with ${device.name} (${device.id})")
        markConversationRead(device.id)
    }

    fun clearSelectedDevice() {
        selectedDevice.value = null
    }

    private fun appendMessage(text: String, peerID: UUID?, outgoing: Boolean) {
        viewModelScope.launch(Dispatchers.Main) {
            if (peerID != null) {
                timeline.add(ConversationItem.Message(UUID.randomUUID(), peerID, text, outgoing, false))
                markConversationUnreadIfNeeded(peerID, incoming = !outgoing)
                persistConversationHistory()
            }
        }
    }

    private fun appendSystemMessage(text: String, peerID: UUID? = selectedDevice.value?.id) {
        viewModelScope.launch(Dispatchers.Main) {
            if (peerID != null) {
                timeline.add(ConversationItem.Message(UUID.randomUUID(), peerID, text, false, true))
                persistConversationHistory()
            }
        }
    }

    private fun upsertTransfer(item: TransferItem) {
        transfers[item.id] = item
    }

    private fun updateTransferProgress(
        transferID: UUID,
        completedBytes: Long,
        status: TransferStatus,
        localUri: Uri? = null
    ) {
        viewModelScope.launch(Dispatchers.Main) {
            transfers[transferID]?.let { current ->
                upsertTransfer(
                    current.copy(
                        completedBytes = completedBytes.coerceAtMost(current.fileSize),
                        status = status,
                        localUri = localUri ?: current.localUri
                    )
                )
            }
        }
    }

    private fun markTransferCompleted(transferID: UUID) {
        viewModelScope.launch(Dispatchers.Main) {
            transfers[transferID]?.let { current ->
                upsertTransfer(current.copy(completedBytes = current.fileSize, status = TransferStatus.COMPLETED))
                persistConversationHistory()
            }
        }
    }

    private fun markTransferFailed(transferID: UUID, reason: String) {
        viewModelScope.launch(Dispatchers.Main) {
            transfers[transferID]?.let { current ->
                upsertTransfer(current.copy(status = TransferStatus.FAILED, error = reason))
                current.peerID?.let { peerID ->
                    timeline.add(ConversationItem.Message(UUID.randomUUID(), peerID, "File transfer failed: $reason", false, true))
                }
                persistConversationHistory()
            }
        }
    }

    private fun markTransferCancelled(transferID: UUID) {
        viewModelScope.launch(Dispatchers.Main) {
            transfers[transferID]?.let { current ->
                upsertTransfer(current.copy(status = TransferStatus.CANCELLED))
                persistConversationHistory()
            }
        }
    }

    private fun parseTransferOffer(raw: String): TransferOffer? {
        val transfer = JSONObject(raw).optJSONObject("payload")?.optJSONObject("transfer") ?: return null
        return runCatching {
            TransferOffer(
                id = UUID.fromString(transfer.getString("id")),
                fileName = transfer.optString("fileName", "Received file"),
                fileSize = transfer.optLong("fileSize", 0),
                checksum = transfer.optString("checksum"),
                mimeType = transfer.optString("mimeType").takeUnless { it.isBlank() || it == "null" },
                streamPort = transfer.getInt("streamPort"),
                streamToken = transfer.optString("streamToken").takeIf(TransferToken::isValid)
                    ?: throw IllegalArgumentException("Missing transfer authorization token"),
                streamTokenExpiresAt = transfer.optLong("streamTokenExpiresAt", 0)
                    .takeIf { it >= System.currentTimeMillis() }
                    ?: throw IllegalArgumentException("Expired transfer authorization token")
            )
        }.getOrNull()
    }

    private fun transferIDFromPayload(raw: String): UUID? {
        val payload = JSONObject(raw).optJSONObject("payload") ?: return null
        return runCatching { UUID.fromString(payload.optString("transferID")) }.getOrNull()
    }

    private fun parseHelloDevice(raw: String): HelloDevice? {
        val device = JSONObject(raw).optJSONObject("payload")?.optJSONObject("device") ?: return null
        val id = runCatching { UUID.fromString(device.optString("id")) }.getOrNull() ?: return null
        return HelloDevice(id, device.optString("name").takeUnless { it.isBlank() })
    }

    private fun normalizeHost(host: String): String {
        return host.removePrefix("[").removeSuffix("]").substringBefore('%')
    }

    private fun acceptAuthorizedClient(outgoing: OutgoingTransfer): Socket {
        while (true) {
            if (System.currentTimeMillis() > outgoing.streamTokenExpiresAt) {
                throw IOException("The transfer authorization token has expired")
            }
            val socket = try {
                outgoing.server.accept()
            } catch (_: SocketTimeoutException) {
                continue
            }
            try {
                socket.soTimeout = 5_000
                val bytes = ByteArray(outgoing.streamToken.length + 1)
                DataInputStream(socket.getInputStream()).readFully(bytes)
                val received = String(bytes, 0, bytes.size - 1, Charsets.US_ASCII)
                val isWellFramed = bytes.last() == '\n'.code.toByte()
                if (isWellFramed && TransferToken.matches(received, outgoing.streamToken)) {
                    socket.soTimeout = 0
                    Log.d(TAG, "Accepted authenticated data connection for ${outgoing.id}")
                    return socket
                }
                Log.w(TAG, "Rejected unauthenticated data connection for ${outgoing.id}")
            } catch (error: Exception) {
                Log.w(TAG, "Could not authenticate data connection for ${outgoing.id}", error)
            }
            runCatching { socket.close() }
        }
    }

    override fun onCleared() {
        discovery.stop()
        transport.close()
        server.stop()
        incomingTransfers.clear()
        synchronized(outgoingTransfers) {
            outgoingTransfers.values.forEach { runCatching { it.server.close() } }
            outgoingTransfers.clear()
        }
    }

    private fun restoreConversationHistory() {
        val history = conversationStore.load()
        timeline.addAll(history.timeline)
        var interruptedTransferCount = 0
        history.transfers.forEach { transfer ->
            val restored = if (transfer.status in setOf(
                    TransferStatus.WAITING,
                    TransferStatus.SENDING,
                    TransferStatus.RECEIVING
                )
            ) {
                interruptedTransferCount += 1
                transfer.copy(
                    status = TransferStatus.FAILED,
                    error = "Transfer interrupted because NearLink restarted"
                )
            } else {
                transfer
            }
            transfers[restored.id] = restored
        }
        unreadMessageCounts.putAll(history.unreadCounts)
        if (timeline.isNotEmpty() || transfers.isNotEmpty()) {
            Log.d(TAG, "Restored ${timeline.size} conversation item(s), ${transfers.size} transfer(s), and ${unreadMessageCounts.size} unread conversation(s)")
        }
        if (interruptedTransferCount > 0) persistConversationHistory()
    }

    private fun persistConversationHistory() {
        conversationStore.save(timeline, transfers.values, unreadMessageCounts)
        Log.d(TAG, "Persisted ${timeline.size} conversation item(s), ${transfers.size} transfer(s)")
    }

    private fun markConversationUnreadIfNeeded(peerID: UUID, incoming: Boolean) {
        if (incoming && selectedDevice.value?.id != peerID) {
            val count = (unreadMessageCounts[peerID] ?: 0) + 1
            unreadMessageCounts[peerID] = count
            Log.d(TAG, "Marked message from $peerID unread (count=$count)")
        }
    }

    private fun markConversationRead(peerID: UUID) {
        if (unreadMessageCounts.remove(peerID) != null) {
            Log.d(TAG, "Cleared unread count for $peerID")
            persistConversationHistory()
        }
    }

    private fun reconcileDeviceIdentity(provisionalID: UUID, verifiedID: UUID) {
        if (provisionalID == verifiedID) return
        timeline.indices.forEach { index ->
            timeline[index] = when (val item = timeline[index]) {
                is ConversationItem.Message -> if (item.peerID == provisionalID) item.copy(peerID = verifiedID) else item
                is ConversationItem.Transfer -> if (item.peerID == provisionalID) item.copy(peerID = verifiedID) else item
            }
        }
        transfers.entries.toList().forEach { (transferID, transfer) ->
            if (transfer.peerID == provisionalID) transfers[transferID] = transfer.copy(peerID = verifiedID)
        }
        unreadMessageCounts.remove(provisionalID)?.let { provisionalUnread ->
            unreadMessageCounts[verifiedID] = (unreadMessageCounts[verifiedID] ?: 0) + provisionalUnread
        }
        selectedDevice.value?.takeIf { it.id == provisionalID }?.let { selected ->
            selectedDevice.value = selected.copy(id = verifiedID)
        }
        persistConversationHistory()
    }

    private fun previewText(item: ConversationItem): String = when (item) {
        is ConversationItem.Message -> item.text
        is ConversationItem.Transfer -> {
            val mimeType = transfers[item.transferID]?.mimeType.orEmpty()
            val label = when {
                mimeType.startsWith("image/") -> "photo"
                mimeType.startsWith("video/") -> "video"
                else -> "file"
            }
            if (transfers[item.transferID]?.incoming == true) "Received $label" else "Sent $label"
        }
    }
}

private data class FileMetadata(val name: String, val size: Long, val mimeType: String?)

private data class OutgoingTransfer(
    val id: UUID,
    val uri: Uri,
    val fileName: String,
    val fileSize: Long,
    val checksum: String,
    val mimeType: String?,
    val streamToken: String,
    val streamTokenExpiresAt: Long,
    val server: ServerSocket
)

private data class TransferOffer(
    val id: UUID,
    val fileName: String,
    val fileSize: Long,
    val checksum: String,
    val mimeType: String?,
    val streamPort: Int,
    val streamToken: String,
    val streamTokenExpiresAt: Long
)

private data class IncomingTransfer(
    val transfer: TransferOffer,
    val remoteHost: String,
    val sender: suspend (String) -> Unit
)

private data class HelloDevice(val id: UUID, val name: String?)

enum class TransferStatus {
    WAITING,
    SENDING,
    RECEIVING,
    COMPLETED,
    FAILED,
    CANCELLED
}

data class TransferItem(
    val id: UUID,
    val peerID: UUID?,
    val fileName: String,
    val fileSize: Long,
    val mimeType: String?,
    val completedBytes: Long,
    val status: TransferStatus,
    val incoming: Boolean,
    val localUri: Uri?,
    val error: String? = null
) {
    val progress: Float
        get() = if (fileSize <= 0) 0f else (completedBytes.toDouble() / fileSize).coerceIn(0.0, 1.0).toFloat()
}

sealed interface ConversationItem {
    val id: UUID
    val peerID: UUID
    val timestamp: Long

    data class Message(
        override val id: UUID,
        override val peerID: UUID,
        val text: String,
        val outgoing: Boolean,
        val system: Boolean,
        override val timestamp: Long = System.currentTimeMillis()
    ) : ConversationItem

    data class Transfer(
        override val id: UUID,
        override val peerID: UUID,
        val transferID: UUID,
        override val timestamp: Long = System.currentTimeMillis()
    ) : ConversationItem
}

data class ConversationPreview(
    val text: String,
    val timestamp: Long,
    val unreadCount: Int
)
