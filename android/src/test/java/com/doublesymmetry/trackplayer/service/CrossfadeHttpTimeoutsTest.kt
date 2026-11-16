package com.doublesymmetry.trackplayer.service

import android.net.Uri
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.upstream.TransferListener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class CrossfadeHttpTimeoutsTest {
    // A DataSpec needs a Uri, a stub in JVM tests: build the value the factory only passes along.
    private val spec: DataSpec = run {
        val unsafe = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        unsafe.javaClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, DataSpec::class.java) as DataSpec
    }

    /** Records each request's timeout and the listeners it was given. */
    private class RecordingRequest(val timeoutMs: Int) : DataSource {
        val listeners = mutableListOf<TransferListener>()
        override fun addTransferListener(transferListener: TransferListener) { listeners += transferListener }
        override fun open(dataSpec: DataSpec): Long = 0L
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int = -1
        override fun getUri(): Uri? = null
        override fun close() = Unit
    }

    @Test
    fun aSourceCreatedBeforeAnOptionsChangeOpensWithTheNewTimeout() {
        var stall = DEFAULT_STALL_TIMEOUT_MS
        val requests = mutableListOf<RecordingRequest>()
        val factory = CurrentTimeoutHttpDataSourceFactory({ stall }) { _, timeoutMs ->
            RecordingRequest(timeoutMs).also(requests::add)
        }
        // A loaded track keeps its data source; an updateOptions value reaches its next request.
        val source = factory.createDataSource()
        val listener = object : TransferListener {
            override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
            override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
            override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) = Unit
            override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        }
        source.addTransferListener(listener)
        source.open(spec)
        source.close()
        stall = 25_000L
        source.open(spec)
        source.close()
        assertEquals(listOf(10_000, 25_000), requests.map { it.timeoutMs })
        // Every request gets the listeners (bytes loaded, bandwidth meter).
        requests.forEach { assertSame(listener, it.listeners.single()) }
    }

    @Test
    fun eachRequestIsADefaultHttpDataSourceWithThoseTimeouts() {
        val request = httpSourceWithTimeouts(DefaultHttpDataSource.Factory(), 25_000) as DefaultHttpDataSource
        fun field(name: String) = DefaultHttpDataSource::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.getInt(request)
        assertEquals(25_000, field("connectTimeoutMillis"))
        assertEquals(25_000, field("readTimeoutMillis"))
        // The option's bounds fit an Int.
        assertEquals(2_147_483_646, httpTimeoutMs(2_147_483_646L))
        assertEquals(10_000, httpTimeoutMs(DEFAULT_STALL_TIMEOUT_MS))
    }

    @Test
    fun theStandardPlayersRequestsKeepKotlinAudiosConfigurationAndFollowTheCurrentStallTimeout() {
        var stall = DEFAULT_STALL_TIMEOUT_MS
        val opened = mutableListOf<Pair<String?, Int>>()
        val forItem = standardHttpDataSourceFactory({ stall }) { factory, timeoutMs ->
            val userAgent = DefaultHttpDataSource.Factory::class.java.getDeclaredField("userAgent")
                .apply { isAccessible = true }.get(factory) as String?
            opened += userAgent to timeoutMs
            RecordingRequest(timeoutMs)
        }
        // KotlinAudio configures the item's factory (here its user agent), then ExoPlayer opens.
        val source = forItem { setUserAgent("djeeloo-test") }.createDataSource()
        source.open(spec)
        stall = 30_000L
        source.open(spec)
        assertEquals(listOf("djeeloo-test" to 10_000, "djeeloo-test" to 30_000), opened)
    }
}
