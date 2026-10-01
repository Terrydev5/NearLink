package com.terrydev.nearlink

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import java.io.File
import java.io.InputStream

data class SavedFile(
    val uri: Uri,
    val checksum: String
)

/** Saves received content to a user-visible Android collection. */
class NearLinkFileStorage(context: Context) {
    private val appContext = context.applicationContext

    fun availableBytes(): Long {
        val directory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Environment.getExternalStorageDirectory()
        } else {
            requireNotNull(appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)) {
                "Download storage is unavailable"
            }
        }
        return StatFs(directory.absolutePath).availableBytes
    }

    fun saveReceivedFile(
        fileName: String,
        mimeType: String?,
        input: InputStream,
        expectedBytes: Long,
        expectedChecksum: String,
        onProgress: (Long) -> Unit
    ): SavedFile {
        IncomingFilePolicy.validateOffer(expectedBytes, expectedChecksum)
        val safeName = fileName.substringAfterLast('/').substringAfterLast('\\')
            .takeUnless { it.isBlank() || it == "." || it == ".." } ?: "NearLink-file"
        val resolvedMime = mimeType ?: guessMimeType(safeName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveWithMediaStore(safeName, resolvedMime, input, expectedBytes, expectedChecksum, onProgress)
        } else {
            saveToAppExternalFiles(safeName, input, expectedBytes, expectedChecksum, onProgress)
        }
    }

    private fun saveWithMediaStore(
        fileName: String,
        mimeType: String,
        input: InputStream,
        expectedBytes: Long,
        expectedChecksum: String,
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
            val checksum = resolver.openOutputStream(uri)?.use { output ->
                VerifiedFileCopy.copy(input, output, expectedBytes, expectedChecksum, ::availableBytes, onProgress)
            } ?: error("Could not open the media library destination")
            check(resolver.update(uri, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null) == 1) { "Could not publish the verified file" }
            return SavedFile(uri, checksum)
        } catch (error: Throwable) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun saveToAppExternalFiles(
        fileName: String,
        input: InputStream,
        expectedBytes: Long,
        expectedChecksum: String,
        onProgress: (Long) -> Unit
    ): SavedFile {
        val directory = File(
            requireNotNull(appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)) {
                "Download storage is unavailable"
            },
            "NearLink/Received"
        ).apply { mkdirs() }
        val (destination, checksum) = VerifiedFileCopy.saveToFile(
            directory, fileName, input, expectedBytes, expectedChecksum, ::availableBytes, onProgress
        )
        return SavedFile(Uri.fromFile(destination), checksum)
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
