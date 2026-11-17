package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** When the standard player's load watch arms and gives up (same rules as iOS's StandardLoadWatch). */
class StandardLoadWatchTest {
    private var now = 0L
    private var stall = 10_000L
    private val watch = StandardLoadWatch({ stall }, { 60_000L }, nowMs = { now })
    private val a = Any()
    private val b = Any()

    private fun observe(item: Any?, state: Int, bytes: Long = 0L, error: Boolean = false) =
        watch.check(StandardLoadObservation(item, state, error, longArrayOf(bytes, 0L, 0L)))

    @Test
    fun aBufferingItemThatNeverWasReadyGivesUpAtTheStallTimeout() {
        assertNull(observe(a, Player.STATE_BUFFERING))
        now = 9_999L
        assertNull(observe(a, Player.STATE_BUFFERING))
        now = 10_000L
        assertEquals(StallVerdict.STALLED, observe(a, Player.STATE_BUFFERING))
    }

    @Test
    fun aSlowButProgressingLoadGoesOnUntilTheTotalLimit() {
        var bytes = 0L
        while (now < 59_000L) {
            assertNull("$now", observe(a, Player.STATE_BUFFERING, bytes))
            now += 1_000L
            bytes += 100L
        }
        now = 60_000L
        assertEquals(StallVerdict.CAP_EXCEEDED, observe(a, Player.STATE_BUFFERING, bytes))
    }

    @Test
    fun aRebufferAfterReadyIsNotALoad() {
        observe(a, Player.STATE_READY)
        observe(a, Player.STATE_BUFFERING)
        now = 30_000L
        assertNull(observe(a, Player.STATE_BUFFERING))
    }

    @Test
    fun anotherItemIsANewLoadWithTheSettingsOfThatMoment() {
        observe(a, Player.STATE_READY)
        stall = 2_000L
        assertNull(observe(b, Player.STATE_BUFFERING))
        now = 2_000L
        assertEquals(StallVerdict.STALLED, observe(b, Player.STATE_BUFFERING))
        assertEquals(2_000L, watch.lastStallTimeoutMs)
    }

    @Test
    fun aRetryAfterAStopOrAnErrorIsANewLoad() {
        observe(a, Player.STATE_READY)
        observe(a, Player.STATE_IDLE)
        assertNull(observe(a, Player.STATE_BUFFERING))
        now = 10_000L
        assertEquals(StallVerdict.STALLED, observe(a, Player.STATE_BUFFERING))
        // A player error ends the load (the player reports it); the retry is watched again.
        observe(a, Player.STATE_BUFFERING, error = true)
        now = 20_000L
        assertNull(observe(a, Player.STATE_BUFFERING))
        now = 30_000L
        assertEquals(StallVerdict.STALLED, observe(a, Player.STATE_BUFFERING))
    }

    @Test
    fun withNoItemOrAnotherOwnerNothingIsWatched() {
        assertNull(observe(a, Player.STATE_BUFFERING))
        // The backend passes no item while a seek waits or it is not authoritative.
        assertNull(observe(null, Player.STATE_BUFFERING))
        now = 30_000L
        assertNull(observe(null, Player.STATE_BUFFERING))
        assertNull(observe(a, Player.STATE_BUFFERING))
    }
}
