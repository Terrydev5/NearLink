package com.terrydev.nearlink

import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Synchronizes the local stream and receiver's verified-save acknowledgement. */
internal class OutgoingTransferConfirmation(
    private val peerID: UUID,
    private val fileSize: Long
) {
    data class Snapshot(val status: TransferStatus, val completedBytes: Long, val error: String?)

    private val lock = Any()
    private val settled = CountDownLatch(1)
    private var snapshot = Snapshot(TransferStatus.WAITING, 0, null)
    private var receiverConfirmed = false
    private var localStreamFinished = false

    fun start(): Boolean = synchronized(lock) {
        if (snapshot.status != TransferStatus.WAITING) return false
        snapshot = snapshot.copy(status = TransferStatus.SENDING)
        true
    }

    fun progress(bytes: Long): Snapshot = synchronized(lock) {
        if (snapshot.status == TransferStatus.SENDING) {
            snapshot = snapshot.copy(completedBytes = bytes.coerceIn(0, fileSize))
        }
        snapshot
    }

    fun confirm(fromPeer: UUID, receivedBytes: Long): Boolean = synchronized(lock) {
        if (fromPeer != peerID || receivedBytes != fileSize ||
            snapshot.status !in setOf(TransferStatus.SENDING, TransferStatus.AWAITING_CONFIRMATION)) return false
        receiverConfirmed = true
        if (localStreamFinished) finishCompleted()
        true
    }

    fun finishSending(bytes: Long): Snapshot = synchronized(lock) {
        if (snapshot.status != TransferStatus.SENDING) return snapshot
        if (bytes != fileSize) {
            settle(TransferStatus.FAILED, "Sent $bytes of $fileSize bytes")
        } else {
            localStreamFinished = true
            if (receiverConfirmed) finishCompleted()
            else snapshot = snapshot.copy(status = TransferStatus.AWAITING_CONFIRMATION)
        }
        snapshot
    }

    fun awaitReceipt(timeoutMillis: Long): Snapshot {
        if (!settled.await(timeoutMillis, TimeUnit.MILLISECONDS)) synchronized(lock) {
            if (snapshot.status == TransferStatus.AWAITING_CONFIRMATION) {
                settle(TransferStatus.UNCONFIRMED, "Receiver confirmation timed out")
            }
        }
        return synchronized(lock) { snapshot }
    }

    fun fail(reason: String): Snapshot = synchronized(lock) {
        if (snapshot.status !in TERMINAL) settle(TransferStatus.FAILED, reason)
        snapshot
    }

    fun cancel(fromPeer: UUID): Snapshot = synchronized(lock) {
        if (fromPeer == peerID && snapshot.status !in TERMINAL) settle(TransferStatus.CANCELLED, null)
        snapshot
    }

    fun snapshot(): Snapshot = synchronized(lock) { snapshot }

    private fun finishCompleted() = settle(TransferStatus.COMPLETED, null)
    private fun settle(status: TransferStatus, error: String?) {
        snapshot = Snapshot(status, if (status == TransferStatus.COMPLETED) fileSize else snapshot.completedBytes, error)
        settled.countDown()
    }

    companion object {
        private const val RECEIPT_TIMEOUT_MILLIS = 60_000L
        private val TERMINAL = setOf(
            TransferStatus.COMPLETED, TransferStatus.FAILED,
            TransferStatus.CANCELLED, TransferStatus.UNCONFIRMED
        )
        fun receiptTimeoutMillis() = RECEIPT_TIMEOUT_MILLIS
    }
}
