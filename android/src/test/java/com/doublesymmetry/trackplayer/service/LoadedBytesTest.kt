package com.doublesymmetry.trackplayer.service

import android.net.Uri
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What counts as a standard load's progress ([LoadedBytes]): media bytes always, playlists and
 * keys until the load asks for a segment, and only the requests of the item that loads. Transfer
 * callbacks run on the player's loader threads, so a request of the previous track can still
 * report after the next track's load started.
 */
class LoadedBytesTest {
    // A DataSpec needs a Uri, a stub in JVM tests: build the value the listeners only pass along.
    private val spec: DataSpec = run {
        val unsafe = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        unsafe.javaClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, DataSpec::class.java) as DataSpec
    }
    private val source = object : DataSource {
        override fun addTransferListener(transferListener: TransferListener) = Unit
        override fun open(dataSpec: DataSpec): Long = 0L
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int = 0
        override fun getUri(): Uri? = null
        override fun close() = Unit
    }
    private val bytes = LoadedBytes()
    private val previous = Any()
    private val next = Any()

    private fun TransferListener.request(transferred: Int = 0) {
        onTransferInitializing(source, spec, true)
        onTransferStart(source, spec, true)
        if (transferred > 0) onBytesTransferred(source, spec, true, transferred)
    }

    private fun TransferListener.transfer(transferred: Int) = onBytesTransferred(source, spec, true, transferred)

    @Test
    fun playlistsCountUntilTheLoadAsksForASegmentThenOnlyMediaCounts() {
        bytes.startLoad(next)
        bytes.playlists(next).request(100)
        assertEquals(100L, bytes.value)
        bytes.media(next).request(1_000)
        assertEquals(1_100L, bytes.value)
        // A fallback to another rendition reloads its playlist: not progress.
        bytes.playlists(next).request(100)
        assertEquals(1_100L, bytes.value)
        // A new load of the same track (a retry): its playlists count again.
        bytes.startLoad(next)
        bytes.playlists(next).request(100)
        assertEquals(1_200L, bytes.value)
    }

    @Test
    fun thePreviousTracksSegmentRequestDoesNotEndTheNextLoadsPlaylistProgress() {
        val previousMedia = bytes.media(previous)
        bytes.startLoad(previous)
        bytes.startLoad(next)
        // The previous track's segment request, issued on a loader thread before the item
        // change, opens after the next load started.
        previousMedia.request()
        // The next track's playlists, slow behind a busy proxy, are still its progress.
        bytes.playlists(next).request(100)
        assertEquals("the next load's playlists are its progress", 100L, bytes.value)
    }

    @Test
    fun thePreviousTracksBytesAreNotTheNextLoadsProgress() {
        val previousMedia = bytes.media(previous)
        val previousPlaylists = bytes.playlists(previous)
        bytes.startLoad(previous)
        previousMedia.request()
        bytes.startLoad(next)
        // A stalled segment of the previous track trickling in after the change.
        previousMedia.transfer(1_000)
        previousPlaylists.transfer(100)
        assertEquals("the previous track's bytes are not the next load's progress", 0L, bytes.value)
        bytes.media(next).request(10)
        assertEquals(10L, bytes.value)
    }

    @Test
    fun aTrackPreparedAheadCountsOnceItsOwnLoadStarts() {
        val nextMedia = bytes.media(next)
        bytes.startLoad(previous)
        // ExoPlayer buffers the next track ahead while the previous one plays.
        nextMedia.request(500)
        assertEquals(0L, bytes.value)
        bytes.startLoad(next)
        nextMedia.transfer(500)
        assertEquals(500L, bytes.value)
    }
}
