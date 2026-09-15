package com.terrydev.nearlink

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private const val TAG = "NearLinkTransport"

class NearLinkTransport(
    private val localDevice: NearbyDevice,
    private val messageHandler: (UUID, String) -> Unit,
    private val errorHandler: (String) -> Unit = {}
) {
    private val client = OkHttpClient()
    private val sockets = ConcurrentHashMap<UUID, WebSocket>()

    fun sendText(device: NearbyDevice, text: String) {
        sendRaw(device, Envelope.text(text, localDevice.id))
    }

    fun sendRaw(device: NearbyDevice, message: String) {
        val existing = sockets[device.id]
        if (existing != null && existing.send(message)) {
            Log.d(TAG, "Queued ${Envelope.type(message)} for ${device.name} (${device.id})")
            return
        }
        if (existing != null) {
            Log.w(TAG, "Discarding unusable socket for ${device.name}; reconnecting")
            sockets.remove(device.id, existing)
            existing.cancel()
        }
        val socket = connect(device)
        if (!socket.send(message)) {
            sockets.remove(device.id, socket)
            socket.cancel()
            throw IOException("WebSocket is not accepting messages")
        }
        Log.d(TAG, "Queued ${Envelope.type(message)} after reconnect for ${device.name} (${device.id})")
    }

    private fun connect(device: NearbyDevice): WebSocket {
        val request = Request.Builder()
            // Network.framework's WebSocket listener accepts the root path.
            .url("ws://${formatHost(device.host)}:${device.port}/")
            .build()
        Log.d(TAG, "Opening WebSocket to ${device.name} at ${request.url}")
        val socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: okhttp3.Response) {
                Log.d(TAG, "WebSocket open for ${device.name} (${device.id})")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                Log.d(TAG, "Received ${Envelope.type(text)} from ${device.name} (${device.id})")
                messageHandler(device.id, text)
                runCatching { Envelope.type(text) }
                    .getOrNull()
                    ?.takeIf { it == "heartbeat" }
                    ?.let { webSocket.send(Envelope.heartbeatAck()) }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: okhttp3.Response?) {
                sockets.remove(device.id, webSocket)
                Log.w(TAG, "WebSocket failed for ${device.name} (${device.id})", t)
                errorHandler("Connection failed: ${t.localizedMessage ?: "unknown error"}")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                sockets.remove(device.id, webSocket)
                Log.d(TAG, "WebSocket closed for ${device.name} (${device.id}), code=$code reason=$reason")
            }
        })
        sockets[device.id] = socket
        if (!socket.send(Envelope.hello(localDevice))) {
            sockets.remove(device.id, socket)
            socket.cancel()
            throw IOException("Could not queue hello frame")
        }
        Log.d(TAG, "Queued hello for ${device.name} (${device.id})")
        return socket
    }

    fun close() {
        sockets.values.forEach { it.close(1000, "NearLink stopped") }
        sockets.clear()
        client.dispatcher.executorService.shutdown()
    }

    private fun formatHost(host: String): String {
        // Android may return an IPv6 link-local address with a zone suffix
        // (for example fe80::1234%wlan0). Keep the interface scope, but
        // percent-encode it because URLs use %25 for the zone separator.
        val raw = host.trim().removePrefix("[").removeSuffix("]")
        val zoneIndex = raw.indexOf('%')
        val normalized = if (zoneIndex >= 0 && !raw.substring(zoneIndex).startsWith("%25")) {
            raw.substring(0, zoneIndex) + "%25" + raw.substring(zoneIndex + 1)
        } else {
            raw
        }
        return if (normalized.contains(":") && !normalized.startsWith("[")) {
            "[$normalized]"
        } else {
            normalized
        }
    }
}
