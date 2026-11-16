package com.doublesymmetry.trackplayer.service

import android.net.Uri
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.upstream.TransferListener

/**
 * An HTTP data source factory whose connect and read timeouts follow the app's current
 * `stallTimeoutMs` for every request, instead of ExoPlayer's fixed 8 s.
 *
 * ExoPlayer's DefaultHttpDataSource copies its timeouts when it is created, and a loaded or
 * preloaded track keeps its data sources; so each source made here builds its DefaultHttpDataSource
 * at every [DataSource.open], with the value read then. A new value from updateOptions applies from
 * the next request, on every track. Request headers and user agent are configured as usual and read
 * at the same moment.
 */
internal class CurrentTimeoutHttpDataSourceFactory(
    /** The app's current `stallTimeoutMs`, read at every request. */
    private val stallTimeoutMs: () -> Long,
    /** Called when a request that opened is closed (a transfer of this item ended). */
    private val onTransferEnded: () -> Unit = {},
    /** Opens one request with the given timeout (tests replace it). */
    private val newRequestSource: (DefaultHttpDataSource.Factory, Int) -> DataSource = ::httpSourceWithTimeouts
) : DataSource.Factory {
    private val http = DefaultHttpDataSource.Factory()

    /** Changes the request headers or user agent of the requests opened from now on. */
    fun configure(change: DefaultHttpDataSource.Factory.() -> Unit) {
        synchronized(http) { http.change() }
    }

    override fun createDataSource(): DataSource = PerRequestSource()

    private fun openRequestSource(): DataSource {
        val timeoutMs = httpTimeoutMs(stallTimeoutMs())
        return synchronized(http) { newRequestSource(http, timeoutMs) }
    }

    private inner class PerRequestSource : DataSource {
        private val listeners = mutableListOf<TransferListener>()
        private var current: DataSource? = null

        override fun addTransferListener(transferListener: TransferListener) {
            listeners += transferListener
            current?.addTransferListener(transferListener)
        }

        private var opened = false

        override fun open(dataSpec: DataSpec): Long {
            val source = openRequestSource()
            listeners.forEach(source::addTransferListener)
            current = source
            return source.open(dataSpec).also { opened = true }
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            checkNotNull(current) { "read before open" }.read(buffer, offset, length)

        override fun getUri(): Uri? = current?.uri

        override fun getResponseHeaders(): Map<String, List<String>> =
            current?.responseHeaders ?: emptyMap()

        override fun close() {
            val source = current
            current = null
            val transferred = opened
            opened = false
            try {
                source?.close()
            } finally {
                if (transferred) onTransferEnded()
            }
        }
    }
}

/** The HTTP connect and read timeout for a stall timeout (the option fits an Int). */
internal fun httpTimeoutMs(stallTimeoutMs: Long): Int =
    stallTimeoutMs.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()

/** A DefaultHttpDataSource for one request, with the given connect and read timeouts. */
internal fun httpSourceWithTimeouts(factory: DefaultHttpDataSource.Factory, timeoutMs: Int): DataSource =
    factory.setConnectTimeoutMs(timeoutMs).setReadTimeoutMs(timeoutMs).createDataSource()

/**
 * The standard player's HTTP data source factory for one item (vendored KotlinAudio's
 * `PlayerHooks.httpDataSourceFactory`): KotlinAudio's configuration of the item (user agent,
 * redirects, headers) on a factory whose requests follow the current `stallTimeoutMs`.
 */
internal fun standardHttpDataSourceFactory(
    stallTimeoutMs: () -> Long,
    /** Records each item's ended transfers (start-low: a track follows the meter once measured). */
    transfers: OwnTransferRegistry = OwnTransferRegistry(),
    newRequestSource: (DefaultHttpDataSource.Factory, Int) -> DataSource = ::httpSourceWithTimeouts
): (Any, DefaultHttpDataSource.Factory.() -> Unit) -> DataSource.Factory = { item, configure ->
    CurrentTimeoutHttpDataSourceFactory(stallTimeoutMs, onTransferEnded = { transfers.transferEnded(item) }, newRequestSource = newRequestSource)
        .apply { configure(configure) }
}
