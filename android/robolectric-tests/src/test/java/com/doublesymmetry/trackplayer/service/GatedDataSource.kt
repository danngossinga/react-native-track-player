package com.doublesymmetry.trackplayer.service

import android.net.Uri
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import java.util.concurrent.CountDownLatch

/**
 * An HTTP request that the test holds before it starts: [held] counts down when a request
 * matching [isHeld] reaches it, and the request starts (its transfer listeners included) only
 * when [release] counts down. Holding ignores interrupts, as a request whose thread is already
 * past ExoPlayer's cancellation check would.
 */
internal class GatedDataSource(
    private val upstream: DataSource,
    private val isHeld: (DataSpec) -> Boolean,
    private val held: CountDownLatch,
    private val release: CountDownLatch
) : DataSource {
    override fun addTransferListener(transferListener: TransferListener) =
        upstream.addTransferListener(transferListener)

    override fun open(dataSpec: DataSpec): Long {
        if (isHeld(dataSpec)) {
            held.countDown()
            var interrupted = false
            while (true) {
                try {
                    release.await()
                    break
                } catch (_: InterruptedException) {
                    interrupted = true
                }
            }
            if (interrupted) Thread.currentThread().interrupt()
        }
        return upstream.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int = upstream.read(buffer, offset, length)

    override fun getUri(): Uri? = upstream.uri

    override fun close() = upstream.close()
}
