package com.terrydev.nearlink

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

object IncomingFilePolicy {
    const val MAXIMUM_FILE_BYTES = 2L * 1024 * 1024 * 1024
    const val MINIMUM_FREE_BYTES = 512L * 1024 * 1024
    const val LOW_STORAGE_BYTES = 2L * 1024 * 1024 * 1024
    const val MAXIMUM_CONCURRENT_RECEIVES = 10

    fun validateOffer(expectedBytes: Long, checksum: String) {
        if (expectedBytes !in 0..MAXIMUM_FILE_BYTES) {
            throw IOException("Cannot receive this file. The maximum file size is 2 GiB.")
        }
        if (!checksum.matches(Regex("[0-9a-fA-F]{64}"))) {
            throw IOException("The sender provided an invalid SHA-256 checksum.")
        }
    }

    fun checkCapacity(requiredBytes: Long, availableBytes: Long, reservedBytes: Long = 0): String? {
        val usable = (availableBytes - reservedBytes).coerceAtLeast(0)
        if (requiredBytes < 0 || usable < MINIMUM_FREE_BYTES || requiredBytes > usable - MINIMUM_FREE_BYTES) {
            throw IOException("Not enough storage to receive this file. ${format(usable)} available; ${format(requiredBytes + MINIMUM_FREE_BYTES)} needed, including 512 MiB kept free. Free up space and ask the sender to retry.")
        }
        val remaining = usable - requiredBytes
        return if (remaining < LOW_STORAGE_BYTES) {
            "Storage is running low. About ${format(remaining)} will remain after the current files are received. NearLink keeps at least 512 MiB free and will stop if space runs out."
        } else null
    }

    private fun format(bytes: Long): String = String.format(Locale.ROOT, "%.2f GiB", bytes.coerceAtLeast(0) / (1024.0 * 1024 * 1024))
}

object VerifiedFileCopy {
    fun copy(input: InputStream, output: OutputStream, expectedBytes: Long, expectedChecksum: String,
             availableBytes: () -> Long, onProgress: (Long) -> Unit): String {
        IncomingFilePolicy.validateOffer(expectedBytes, expectedChecksum)
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(256 * 1024)
        var completed = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            if (count.toLong() > expectedBytes - completed) {
                throw IOException("The sender sent more data than the advertised file size. Reception stopped.")
            }
            IncomingFilePolicy.checkCapacity(count.toLong(), availableBytes())
            output.write(buffer, 0, count)
            digest.update(buffer, 0, count)
            completed += count
            onProgress(completed)
        }
        if (completed != expectedBytes) throw IOException("The file stream ended before all expected bytes arrived.")
        val checksum = digest.digest().joinToString("") { "%02x".format(it) }
        if (!checksum.equals(expectedChecksum, ignoreCase = true)) {
            throw IOException("The received file failed SHA-256 verification.")
        }
        output.flush()
        return checksum
    }

    fun saveToFile(directory: File, fileName: String, input: InputStream, expectedBytes: Long,
                   expectedChecksum: String, availableBytes: () -> Long,
                   onProgress: (Long) -> Unit): Pair<File, String> {
        val temporary = File.createTempFile(".nearlink-", ".partial", directory)
        try {
            val checksum = temporary.outputStream().use { output ->
                copy(input, output, expectedBytes, expectedChecksum, availableBytes, onProgress)
            }
            // Reserve the final name atomically, so rename cannot replace another receive.
            var destination = File(directory, fileName)
            while (!destination.createNewFile()) {
                val original = File(fileName)
                val suffix = if (original.extension.isEmpty()) "" else ".${original.extension}"
                destination = File(directory, "${original.nameWithoutExtension}-${UUID.randomUUID()}$suffix")
            }
            if (!temporary.renameTo(destination)) {
                destination.delete()
                throw IOException("Could not publish the verified file.")
            }
            return destination to checksum
        } finally {
            temporary.delete()
        }
    }
}
