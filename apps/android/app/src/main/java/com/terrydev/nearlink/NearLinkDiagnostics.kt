package com.terrydev.nearlink

import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Small, local-only crash and startup trace. It deliberately excludes message
 * text, file names, and peer addresses so it can be shared for debugging.
 */
object NearLinkDiagnostics {
    private const val DIRECTORY_NAME = "diagnostics"
    private const val CURRENT_FILE_NAME = "nearlink.log"
    private const val PREVIOUS_FILE_NAME = "nearlink.previous.log"
    private const val MAX_FILE_BYTES = 256 * 1024L
    private val lock = Any()

    @Volatile private var currentFile: File? = null

    fun install(context: Context) {
        synchronized(lock) {
            if (currentFile != null) return
            val directory = File(context.filesDir, DIRECTORY_NAME).apply { mkdirs() }
            currentFile = File(directory, CURRENT_FILE_NAME)
            event("Diagnostics installed; Android ${Build.VERSION.SDK_INT}, model=${Build.MODEL}")

            val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
            if (previousHandler != null) {
                Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                    exception("Uncaught exception on ${thread.name}", throwable)
                    previousHandler.uncaughtException(thread, throwable)
                }
            }
        }
    }

    fun event(message: String) = write("INFO", message)

    fun exception(message: String, throwable: Throwable) {
        val stackTrace = StringWriter().also { writer -> throwable.printStackTrace(PrintWriter(writer)) }.toString()
        write("ERROR", "$message\n$stackTrace")
    }

    private fun write(level: String, message: String) {
        runCatching {
            synchronized(lock) {
                val file = currentFile ?: return
                rotateIfNeeded(file)
                file.appendText("${System.currentTimeMillis()} $level $message\n")
            }
        }
    }

    private fun rotateIfNeeded(file: File) {
        if (!file.exists() || file.length() < MAX_FILE_BYTES) return
        val previous = File(file.parentFile, PREVIOUS_FILE_NAME)
        previous.delete()
        file.renameTo(previous)
    }
}
