package com.terrydev.nearlink

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class WindowsInteropTest {
    @Test fun windowsFramesMatchAndroidContract() {
        val fixtures = JSONObject(File(requireNotNull(System.getenv("NEARLINK_WINDOWS_FIXTURES"))).readText())
        for (key in fixtures.keys()) {
            val frame = fixtures.getJSONObject(key)
            assertEquals(NearLinkProtocol.VERSION, Envelope.version(frame.toString()))
            assertTrue(frame.getDouble("timestamp") > 0)
            UUID.fromString(frame.getString("messageID"))
        }
        val text = fixtures.getJSONObject("text").toString()
        assertEquals("你好 Windows 👋", Envelope.textPayload(text))
        assertNotNull(Envelope.textSenderID(text))
        val transfer = fixtures.getJSONObject("offer").getJSONObject("payload").getJSONObject("transfer")
        IncomingFilePolicy.validateOffer(transfer.getLong("fileSize"), transfer.getString("checksum"))
        assertEquals(2L * 1024 * 1024 * 1024, transfer.getLong("fileSize"))
        assertTrue(TransferToken.isValid(transfer.getString("streamToken")))
        assertTrue(transfer.getInt("streamPort") in 1..65535)
        assertTrue(transfer.getDouble("streamTokenExpiresAt") > 0)
        for (key in listOf("accept", "reject", "complete", "cancel")) {
            val payload = fixtures.getJSONObject(key).getJSONObject("payload")
            UUID.fromString(payload.getString("transferID"))
            assertTrue(payload.getLong("receivedBytes") >= 0)
        }
        val id = UUID.randomUUID()
        val output = JSONObject()
            .put("ack", JSONObject(Envelope.acknowledgement(id.toString())))
            .put("hello", JSONObject(Envelope.hello(NearbyDevice(id, "Android fixture", "android", "127.0.0.1", 41820))))
            .put("text", JSONObject(Envelope.text("来自 Android", id)))
            .put("offer", JSONObject(Envelope.fileOffer(id, "Android fixture.mp4", transfer.getLong("fileSize"),
                transfer.getString("checksum"), "video/mp4", 41821, transfer.getString("streamToken"),
                System.currentTimeMillis() + 120_000)))
        File(requireNotNull(System.getenv("NEARLINK_ANDROID_FIXTURES"))).writeText(output.toString())
    }
}
