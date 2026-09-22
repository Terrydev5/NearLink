package com.terrydev.nearlink

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Local-only conversation persistence for the Android MVP. */
class NearLinkConversationStore(context: Context) {
    private val preferences = context.applicationContext
        .getSharedPreferences("nearlink", Context.MODE_PRIVATE)
    private val key = "conversation_history_v1"

    fun load(): ConversationHistory {
        val raw = preferences.getString(key, null) ?: return ConversationHistory()
        return runCatching {
            val root = JSONObject(raw)
            ConversationHistory(
                timeline = decodeTimeline(root.optJSONArray("timeline") ?: JSONArray()),
                transfers = decodeTransfers(root.optJSONArray("transfers") ?: JSONArray()),
                unreadCounts = decodeUnreadCounts(root.optJSONObject("unreadCounts") ?: JSONObject()),
                devices = decodeDevices(root.optJSONArray("devices") ?: JSONArray())
            )
        }.getOrDefault(ConversationHistory())
    }

    fun save(
        timeline: List<ConversationItem>,
        transfers: Collection<TransferItem>,
        unreadCounts: Map<UUID, Int>,
        devices: Collection<NearbyDevice>
    ) {
        val root = JSONObject()
        root.put("timeline", JSONArray().apply {
            timeline.forEach { item ->
                put(when (item) {
                    is ConversationItem.Message -> JSONObject()
                        .put("kind", "message")
                        .put("id", item.id.toString())
                        .put("peerID", item.peerID.toString())
                        .put("timestamp", item.timestamp)
                        .put("text", item.text)
                        .put("outgoing", item.outgoing)
                        .put("system", item.system)
                    is ConversationItem.Transfer -> JSONObject()
                        .put("kind", "transfer")
                        .put("id", item.id.toString())
                        .put("peerID", item.peerID.toString())
                        .put("timestamp", item.timestamp)
                        .put("transferID", item.transferID.toString())
                })
            }
        })
        root.put("transfers", JSONArray().apply {
            transfers.forEach { transfer ->
                put(JSONObject()
                    .put("id", transfer.id.toString())
                    .put("peerID", transfer.peerID?.toString() ?: JSONObject.NULL)
                    .put("fileName", transfer.fileName)
                    .put("fileSize", transfer.fileSize)
                    .put("mimeType", transfer.mimeType ?: JSONObject.NULL)
                    .put("completedBytes", transfer.completedBytes)
                    .put("status", transfer.status.name)
                    .put("incoming", transfer.incoming)
                    .put("localUri", transfer.localUri?.toString() ?: JSONObject.NULL)
                    .put("error", transfer.error ?: JSONObject.NULL))
            }
        })
        root.put("unreadCounts", JSONObject().apply {
            unreadCounts.filterValues { it > 0 }.forEach { (peerID, count) -> put(peerID.toString(), count) }
        })
        root.put("devices", JSONArray().apply {
            devices.sortedBy { it.id.toString() }.forEach { device ->
                put(JSONObject()
                    .put("id", device.id.toString())
                    .put("name", device.name)
                    .put("platform", device.platform)
                    .put("protocolVersion", device.protocolVersion))
            }
        })
        preferences.edit().putString(key, root.toString()).apply()
    }

    private fun decodeTimeline(items: JSONArray): List<ConversationItem> = buildList {
        repeat(items.length()) { index ->
            val item = items.optJSONObject(index) ?: return@repeat
            val id = item.uuid("id") ?: return@repeat
            val peerID = item.uuid("peerID") ?: return@repeat
            val timestamp = item.optLong("timestamp", System.currentTimeMillis())
            when (item.optString("kind")) {
                "message" -> add(ConversationItem.Message(
                    id, peerID, item.optString("text"), item.optBoolean("outgoing"),
                    item.optBoolean("system"), timestamp
                ))
                "transfer" -> item.uuid("transferID")?.let { transferID ->
                    add(ConversationItem.Transfer(id, peerID, transferID, timestamp))
                }
            }
        }
    }

    private fun decodeTransfers(items: JSONArray): List<TransferItem> = buildList {
        repeat(items.length()) { index ->
            val item = items.optJSONObject(index) ?: return@repeat
            val id = item.uuid("id") ?: return@repeat
            val status = runCatching { TransferStatus.valueOf(item.optString("status")) }.getOrNull() ?: return@repeat
            val peerID = item.uuid("peerID")
            val localUri = item.optStringOrNull("localUri")?.let(Uri::parse)
            add(TransferItem(
                id = id,
                peerID = peerID,
                fileName = item.optString("fileName", "NearLink file"),
                fileSize = item.optLong("fileSize", 0),
                mimeType = item.optStringOrNull("mimeType"),
                completedBytes = item.optLong("completedBytes", 0),
                status = status,
                incoming = item.optBoolean("incoming"),
                localUri = localUri,
                error = item.optStringOrNull("error")
            ))
        }
    }

    private fun decodeUnreadCounts(counts: JSONObject): Map<UUID, Int> = buildMap {
        counts.keys().forEach { key ->
            val peerID = runCatching { UUID.fromString(key) }.getOrNull() ?: return@forEach
            val count = counts.optInt(key, 0)
            if (count > 0) put(peerID, count)
        }
    }

    private fun decodeDevices(items: JSONArray): List<NearbyDevice> = buildList {
        repeat(items.length()) { index ->
            val item = items.optJSONObject(index) ?: return@repeat
            val id = item.uuid("id") ?: return@repeat
            add(NearbyDevice(
                id = id,
                name = item.optString("name", "Saved device ${id.toString().take(6)}"),
                platform = item.optString("platform", "unknown"),
                host = "",
                port = 0,
                protocolVersion = item.optInt("protocolVersion", NearLinkProtocol.VERSION)
            ))
        }
    }

    private fun JSONObject.uuid(key: String): UUID? =
        optStringOrNull(key)?.let { runCatching { UUID.fromString(it) }.getOrNull() }

    private fun JSONObject.optStringOrNull(key: String): String? =
        optString(key).takeUnless { it.isBlank() || it == "null" }
}

data class ConversationHistory(
    val timeline: List<ConversationItem> = emptyList(),
    val transfers: List<TransferItem> = emptyList(),
    val unreadCounts: Map<UUID, Int> = emptyMap(),
    val devices: List<NearbyDevice> = emptyList()
)
