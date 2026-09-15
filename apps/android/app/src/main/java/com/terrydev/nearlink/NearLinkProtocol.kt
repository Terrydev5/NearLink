package com.terrydev.nearlink

import org.json.JSONObject
import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

object NearLinkProtocol {
    // Version 2 requires a one-time data-stream token on every file offer.
    const val VERSION = 2
    const val SERVICE_TYPE = "_nearlink._tcp."
    const val PORT = 41820
    const val CHUNK_SIZE = 256 * 1024
}

data class NearbyDevice(
    val id: UUID,
    val name: String,
    val platform: String,
    val host: String,
    val port: Int,
    val protocolVersion: Int = NearLinkProtocol.VERSION
)

object Envelope {
    fun hello(device: NearbyDevice): String = JSONObject()
        .put("version", NearLinkProtocol.VERSION)
        .put("type", "hello")
        .put("messageID", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put("payload", JSONObject().put("device", JSONObject()
            .put("id", device.id.toString())
            .put("name", device.name)
            .put("platform", device.platform)
            .put("protocolVersion", device.protocolVersion)))
        .toString()

    fun text(text: String, senderID: UUID): String = JSONObject()
        .put("version", NearLinkProtocol.VERSION)
        .put("type", "text_message")
        .put("messageID", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put("payload", JSONObject()
            .put("text", text)
            .put("senderID", senderID.toString()))
        .toString()

    fun heartbeatAck(): String = JSONObject()
        .put("version", NearLinkProtocol.VERSION)
        .put("type", "heartbeat_ack")
        .put("messageID", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put("payload", JSONObject())
        .toString()

    fun fileOffer(
        transferID: UUID,
        fileName: String,
        fileSize: Long,
        checksum: String,
        mimeType: String?,
        streamPort: Int,
        streamToken: String,
        streamTokenExpiresAt: Long
    ): String = JSONObject()
        .put("version", NearLinkProtocol.VERSION)
        .put("type", "file_offer")
        .put("messageID", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put("payload", JSONObject().put("transfer", JSONObject()
            .put("id", transferID.toString())
            .put("fileName", fileName)
            .put("fileSize", fileSize)
            .put("checksum", checksum)
            .put("mimeType", mimeType ?: JSONObject.NULL)
            .put("streamPort", streamPort)
            .put("streamToken", streamToken)
            .put("streamTokenExpiresAt", streamTokenExpiresAt)))
        .toString()

    fun fileAccept(transferID: UUID, receivedBytes: Long = 0): String = JSONObject()
        .put("version", NearLinkProtocol.VERSION)
        .put("type", "file_accept")
        .put("messageID", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put("payload", JSONObject()
            .put("transferID", transferID.toString())
            .put("receivedBytes", receivedBytes))
        .toString()

    fun fileReject(transferID: UUID): String = JSONObject()
        .put("version", NearLinkProtocol.VERSION)
        .put("type", "file_reject")
        .put("messageID", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put("payload", JSONObject()
            .put("transferID", transferID.toString())
            .put("receivedBytes", 0))
        .toString()

    fun fileComplete(transferID: UUID, receivedBytes: Long): String = JSONObject()
        .put("version", NearLinkProtocol.VERSION)
        .put("type", "transfer_complete")
        .put("messageID", UUID.randomUUID().toString())
        .put("timestamp", System.currentTimeMillis())
        .put("payload", JSONObject()
            .put("transferID", transferID.toString())
            .put("receivedBytes", receivedBytes))
        .toString()

    fun type(json: String): String? = JSONObject(json).optString("type", null)
    fun version(json: String): Int = JSONObject(json).optInt("version", -1)
    fun textPayload(json: String): String? = JSONObject(json)
        .optJSONObject("payload")?.optString("text", null)

    /** Lets receivers identify a message even if its preceding hello frame raced. */
    fun textSenderID(json: String): UUID? = JSONObject(json)
        .optJSONObject("payload")
        ?.optString("senderID", null)
        ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
}

/** Generates and validates a one-time 256-bit credential for a file stream. */
object TransferToken {
    private const val BYTE_COUNT = 32
    private val secureRandom = SecureRandom()

    fun generate(): String {
        val bytes = ByteArray(BYTE_COUNT)
        secureRandom.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    fun isValid(token: String): Boolean =
        token.length == 43 && token.all { it.isLetterOrDigit() || it == '-' || it == '_' }

    fun matches(received: String, expected: String): Boolean =
        isValid(received) && isValid(expected) &&
            MessageDigest.isEqual(received.toByteArray(Charsets.US_ASCII), expected.toByteArray(Charsets.US_ASCII))
}
