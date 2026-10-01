package com.terrydev.nearlink

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID

class TransferSafetyTest {
    private val sample = "NearLink verified transfer".toByteArray()
    private val ampleSpace = 8L * 1024 * 1024 * 1024
    private fun hash(data: ByteArray) = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    @Test fun policyBoundariesAndReservations() {
        val limit = IncomingFilePolicy.MAXIMUM_FILE_BYTES
        val reserve = IncomingFilePolicy.MINIMUM_FREE_BYTES
        IncomingFilePolicy.validateOffer(limit, hash(sample))
        IncomingFilePolicy.validateOffer(0, hash(byteArrayOf()))
        assertThrows(IOException::class.java) { IncomingFilePolicy.validateOffer(limit + 1, hash(sample)) }
        assertThrows(IOException::class.java) { IncomingFilePolicy.validateOffer(-1, hash(sample)) }
        assertThrows(IOException::class.java) { IncomingFilePolicy.validateOffer(1, "invalid") }
        assertThrows(IOException::class.java) { IncomingFilePolicy.checkCapacity(limit, limit + reserve - 1) }
        IncomingFilePolicy.checkCapacity(limit, limit + reserve)
        assertThrows(IOException::class.java) { IncomingFilePolicy.checkCapacity(limit, limit + reserve, 1) }
        assertNotNull(IncomingFilePolicy.checkCapacity(1, limit))
        assertNull(IncomingFilePolicy.checkCapacity(limit, ampleSpace))
    }

    @Test fun rejectsOversizedDataBeforeWritingIt() {
        val output = ByteArrayOutputStream()
        assertThrows(IOException::class.java) {
            VerifiedFileCopy.copy(ByteArrayInputStream(sample + byteArrayOf(0)), output, sample.size.toLong(),
                hash(sample), { ampleSpace }, {})
        }
        assertEquals(0, output.size())
    }

    @Test fun failedTransfersLeaveNoFiles() {
        for (scenario in listOf("oversize", "truncated", "checksum", "disk-full", "disk-shrinks", "interrupted")) {
            val directory = Files.createTempDirectory("nearlink-safety").toFile()
            try {
                val data = when (scenario) {
                    "oversize" -> sample + byteArrayOf(0)
                    "truncated" -> sample.copyOf(2)
                    else -> sample
                }
                val input = object : ByteArrayInputStream(data) {
                    override fun read(buffer: ByteArray, off: Int, len: Int): Int {
                        if (scenario == "interrupted" && available() == 0) throw IOException("Connection lost")
                        return super.read(buffer, off, if (scenario == "disk-shrinks") minOf(len, 2) else len)
                    }
                }
                var spaceChecks = 0
                assertThrows(IOException::class.java) {
                    VerifiedFileCopy.saveToFile(directory, "sample.txt", input, sample.size.toLong(),
                        if (scenario == "checksum") hash(byteArrayOf()) else hash(sample),
                        {
                            spaceChecks++
                            if (scenario == "disk-full" || (scenario == "disk-shrinks" && spaceChecks > 1))
                                IncomingFilePolicy.MINIMUM_FREE_BYTES else ampleSpace
                        }, {})
                }
                assertTrue("No files should survive $scenario", directory.listFiles()!!.isEmpty())
            } finally { directory.deleteRecursively() }
        }
    }

    @Test fun verifiedPublicationPreservesSameNamedFiles() {
        val directory = Files.createTempDirectory("nearlink-safety").toFile()
        try {
            val original = File(directory, "sample.txt").apply { writeText("original") }
            val (saved, checksum) = VerifiedFileCopy.saveToFile(directory, "sample.txt", ByteArrayInputStream(sample),
                sample.size.toLong(), hash(sample).uppercase(), { ampleSpace }) {
                assertEquals("original", original.readText())
                assertEquals(1, directory.listFiles()!!.count { file -> !file.name.startsWith(".nearlink-") })
            }
            assertNotEquals(original, saved)
            assertArrayEquals(sample, saved.readBytes())
            assertEquals(hash(sample), checksum)
            assertEquals("original", original.readText())
            assertFalse(directory.listFiles()!!.any { it.name.endsWith(".partial") })
        } finally { directory.deleteRecursively() }
    }

    @Test fun emptyFileIsValid() {
        val output = ByteArrayOutputStream()
        val checksum = VerifiedFileCopy.copy(ByteArrayInputStream(byteArrayOf()), output, 0, hash(byteArrayOf()), { ampleSpace }, {})
        assertEquals(hash(byteArrayOf()), checksum)
    }

    @Test fun acknowledgementMatchesAppleEnvelope() {
        val id = UUID.randomUUID().toString()
        val raw = Envelope.acknowledgement(id)
        val ack = JSONObject(raw)
        assertEquals(2, ack.getInt("version"))
        assertEquals("ack", ack.getString("type"))
        assertTrue(ack.getLong("timestamp") > 0)
        assertNotEquals(id, UUID.fromString(ack.getString("messageID")).toString())
        assertEquals(id, ack.getJSONObject("payload").getString("messageID"))
        System.getenv("NEARLINK_ACK_FIXTURE")?.let { File(it).writeText(raw) }
    }
}
