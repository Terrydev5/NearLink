package com.terrydev.nearlink

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

data class SavedFile(
    val uri: Uri,
    val checksum: String
)

/** Saves received content to a user-visible Android collection. */
class NearLinkFileStorage(context: Context) {
    private val appContext = context.applicationContext

    fun saveReceivedFile(
        fileName: String,
        mimeType: String?,
        input: InputStream,
        expectedBytes: Long,
        onProgress: (Long) -> Unit
    ): SavedFile {
        val safeName = fileName.substringAfterLast('/').substringAfterLast('\\').ifBlank { "NearLink-file" }
        val resolvedMime = mimeType ?: guessMimeType(safeName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveWithMediaStore(safeName, resolvedMime, input, expectedBytes, onProgress)
        } else {
            saveToAppExternalFiles(safeName, resolvedMime, input, expectedBytes, onProgress)
        }
    }

    private fun saveWithMediaStore(
        fileName: String,
        mimeType: String,
        input: InputStream,
        expectedBytes: Long,
        onProgress: (Long) -> Unit
    ): SavedFile {
        val resolver = appContext.contentResolver
        val (collection, relativePath) = when {
            mimeType.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "Pictures/NearLink"
            mimeType.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI to "Movies/NearLink"
            mimeType.startsWith("audio/") -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to "Music/NearLink"
            else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI to "Download/NearLink"
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: error("Could not create a destination in the media library")
        try {
            resolver.openOutputStream(uri)?.use { output ->
                val checksum = copyAndHash(input, output, expectedBytes, onProgress)
                resolver.update(uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null)
                return SavedFile(uri, checksum)
            } ?: error("Could not open the media library destination")
        } catch (error: Throwable) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun saveToAppExternalFiles(
        fileName: String,
        mimeType: String,
        input: InputStream,
        expectedBytes: Long,
        onProgress: (Long) -> Unit
    ): SavedFile {
        val directory = File(
            appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
            "NearLink/Received"
        ).apply { mkdirs() }
        val destination = uniqueFile(directory, fileName)
        return try {
            destination.outputStream().use { output ->
                val checksum = copyAndHash(input, output, expectedBytes, onProgress)
                SavedFile(Uri.fromFile(destination), checksum)
            }
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }

    private fun copyAndHash(
        input: InputStream,
        output: java.io.OutputStream,
        expectedBytes: Long,
        onProgress: (Long) -> Unit
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(NearLinkProtocol.CHUNK_SIZE)
        var completed = 0L
        while (true) {
            val count = input.read(buffer)
            if (count <= 0) break
            output.write(buffer, 0, count)
            digest.update(buffer, 0, count)
            completed += count
            onProgress(completed.coerceAtMost(expectedBytes))
        }
        output.flush()
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun uniqueFile(directory: File, fileName: String): File {
        val original = File(directory, fileName)
        if (!original.exists()) return original
        val stem = original.nameWithoutExtension
        val extension = original.extension
        val suffix = System.currentTimeMillis()
        return File(directory, if (extension.isEmpty()) "$stem-$suffix" else "$stem-$suffix.$extension")
    }

    private fun guessMimeType(fileName: String): String {
        return when (fileName.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "heic" -> "image/heic"
            "mp4", "mov", "m4v" -> "video/mp4"
            "mp3", "m4a", "wav", "aac" -> "audio/*"
            "pdf" -> "application/pdf"
            else -> "application/octet-stream"
        }
    }
}
