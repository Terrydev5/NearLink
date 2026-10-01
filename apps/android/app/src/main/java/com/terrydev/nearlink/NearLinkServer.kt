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
        NearLinkDiagnostics.event("Creating Ktor control server on port ${NearLinkProtocol.PORT}")
        engine = embeddedServer(CIO, host = "0.0.0.0", port = NearLinkProtocol.PORT) {
            nearLinkModule(messageHandler)
        }.start(wait = false)
        NearLinkDiagnostics.event("Ktor control server start returned")
    }

    fun stop() {
        NearLinkDiagnostics.event("Stopping Ktor control server")
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
            // remoteHost triggers a blocking reverse-DNS lookup in CIO 2.3.x.
            // Keep the numeric peer address so slow/missing PTR records cannot delay messages.
            val peerAddress = call.request.local.remoteAddress
            incoming.consumeAsFlow().collect { frame ->
                if (frame is Frame.Text) {
                    val raw = frame.readText()
                    val sendControl: suspend (String) -> Unit = { response ->
                        send(Frame.Text(response))
                    }
                    messageHandler(raw, sendControl, peerAddress)
                    when (Envelope.type(raw)) {
                        "heartbeat" -> send(Frame.Text(Envelope.heartbeatAck()))
                    }
                    val type = Envelope.type(raw)
                    if (type != null && type != "ack" && type != "heartbeat" && type != "heartbeat_ack") {
                        val messageID = JSONObject(raw).optString("messageID")
                        send(Frame.Text(Envelope.acknowledgement(messageID)))
                    }
                }
            }
        }
    }
}
