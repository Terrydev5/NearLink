package com.terrydev.nearlink

import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.collect
import org.json.JSONObject

class NearLinkServer(
    private val messageHandler: suspend (raw: String, send: suspend (String) -> Unit, remoteHost: String) -> Unit
) {
    private var engine: ApplicationEngine? = null

    fun start() {
        if (engine != null) return
        engine = embeddedServer(CIO, host = "0.0.0.0", port = NearLinkProtocol.PORT) {
            nearLinkModule(messageHandler)
        }.start(wait = false)
    }

    fun stop() {
        engine?.stop(100, 500)
        engine = null
    }
}

private fun Application.nearLinkModule(
    messageHandler: suspend (raw: String, send: suspend (String) -> Unit, remoteHost: String) -> Unit
) {
    install(WebSockets)
    routing {
        webSocket("/") {
            incoming.consumeAsFlow().collect { frame ->
                if (frame is Frame.Text) {
                    val raw = frame.readText()
                    val sendControl: suspend (String) -> Unit = { response ->
                        send(Frame.Text(response))
                    }
                    messageHandler(raw, sendControl, call.request.local.remoteHost)
                    when (Envelope.type(raw)) {
                        "heartbeat" -> send(Frame.Text(Envelope.heartbeatAck()))
                    }
                    val type = Envelope.type(raw)
                    if (type != null && type != "ack" && type != "heartbeat" && type != "heartbeat_ack") {
                        val messageID = JSONObject(raw).optString("messageID")
                        send(Frame.Text(JSONObject()
                            .put("version", NearLinkProtocol.VERSION)
                            .put("type", "ack")
                            .put("messageID", messageID)
                            .put("payload", JSONObject().put("messageID", messageID))
                            .toString()))
                    }
                }
            }
        }
    }
}
