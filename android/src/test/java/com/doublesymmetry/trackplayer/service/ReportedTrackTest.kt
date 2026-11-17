package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every reader agrees with the reported track while another loads (iOS: the same tests). */
class ReportedTrackTest {
    private val a = Any()
    private val b = Any()
    private val c = Any()

    @Test
    fun theProgressIsTheReportedTracksWhileAnotherLoads() {
        val progress = ReportedTrackProgress()
        val playing = TrackProgress(60_000L, 180_000L, 90_000L)
        // On the reported track: its live values.
        assertEquals(playing, progress.read(reported = a, playerItem = a, live = playing))
        // The player left it at 61 s for B, which loads: A's last position, duration and buffer.
        progress.left(a, 61_000L)
        progress.left(b, 5_000L)
        val loadingB = TrackProgress(0L, 0L, 0L)
        assertEquals(TrackProgress(61_000L, 180_000L, 90_000L), progress.read(reported = a, playerItem = b, live = loadingB))
        // B loaded and is reported: its live values.
        val playingB = TrackProgress(200L, 240_000L, 10_000L)
        assertEquals(playingB, progress.read(reported = b, playerItem = b, live = playingB))
        // New metadata for B keeps what it had; C loads.
        val b2 = Any()
        progress.replaced(b, b2)
        progress.left(b2, 300L)
        assertEquals(TrackProgress(300L, 240_000L, 10_000L), progress.read(reported = b2, playerItem = c, live = loadingB))
        // No reported track (the first load failed, or it was removed): none.
        assertEquals(TrackProgress.NONE, progress.read(reported = null, playerItem = c, live = playingB))
        // A reported track the player never played here (a backend switch restored it): none yet.
        assertEquals(TrackProgress.NONE, ReportedTrackProgress().read(reported = a, playerItem = b, live = playingB))
    }

    @Test
    fun theNotificationShowsTheReportedTrackWhileAnotherLoads() {
        val nowPlaying = ReportedNowPlaying()
        assertNull("on the reported track: the player's own", nowPlaying.follow(reported = a, playerItem = a))
        assertEquals(ReportedNowPlaying.Change(a, held = true), nowPlaying.follow(reported = a, playerItem = b))
        assertTrue(nowPlaying.isHeld)
        assertNull("nothing new", nowPlaying.follow(reported = a, playerItem = b))
        // The player moved again (it shows its own item at every move): A again.
        assertEquals(ReportedNowPlaying.Change(a, held = true), nowPlaying.follow(reported = a, playerItem = c))
        // C loaded and is reported: released, C shown.
        assertEquals(ReportedNowPlaying.Change(c, held = false), nowPlaying.follow(reported = c, playerItem = c))
        assertFalse(nowPlaying.isHeld)
        // No reported track: the player's own (nothing held).
        assertNull(nowPlaying.follow(reported = null, playerItem = b))
        // Held, then the reported track left the queue: released to the player's own item.
        nowPlaying.follow(reported = c, playerItem = b)
        assertEquals(ReportedNowPlaying.Change(null, held = false), nowPlaying.follow(reported = null, playerItem = b))
    }

    @Test
    fun theNowPlayingStateIsReleasedOrHeldOnTheReportedTrack() {
        // iOS: testReportedNowPlayingStateIsReleasedOrHeldOnTheReportedTrack.
        val nowPlaying = ReportedNowPlaying()
        fun held(): Pair<Any?, Any?>? = (nowPlaying.state as? ReportedNowPlaying.State.Held)?.let { it.item to it.on }
        assertTrue(nowPlaying.state === ReportedNowPlaying.State.Released)
        assertEquals("the player has no item", ReportedNowPlaying.Change(a, held = true), nowPlaying.follow(reported = a, playerItem = null))
        assertTrue(held()!!.first === a && held()!!.second == null)
        assertEquals(ReportedNowPlaying.Change(a, held = true), nowPlaying.follow(reported = a, playerItem = b))
        assertTrue(held()!!.first === a && held()!!.second === b)
        assertEquals("another reported track", ReportedNowPlaying.Change(b, held = true), nowPlaying.follow(reported = b, playerItem = a))
        assertTrue(held()!!.first === b && held()!!.second === a)
        assertEquals(ReportedNowPlaying.Change(b, held = false), nowPlaying.follow(reported = b, playerItem = b))
        assertTrue(nowPlaying.state === ReportedNowPlaying.State.Released)
        assertNull(nowPlaying.follow(reported = null, playerItem = null))
        assertTrue(nowPlaying.state === ReportedNowPlaying.State.Released)
    }
}
