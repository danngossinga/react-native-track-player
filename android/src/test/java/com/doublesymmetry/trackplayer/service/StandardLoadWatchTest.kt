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

    private fun observe(item: Any?, state: Int, bytes: Long = 0L, error: Boolean = false, owned: Boolean = false) =
        watch.check(StandardLoadObservation(item, state, error, longArrayOf(bytes, 0L, 0L), ownedElsewhere = owned))

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

    @Test
    fun aGiveUpsCodeIsTheHostsOwnAndExoPlayersKeepsItsPrefix() {
        val host = com.doublesymmetry.kotlinaudio.models.PlaybackError(PREPARE_TIMEOUT_CODE, "stalled", fromHost = true)
        val exo = com.doublesymmetry.kotlinaudio.models.PlaybackError("io-network-connection-failed", "failed")
        assertEquals("crossfade_prepare_timeout", standardPlaybackErrorCode(host))
        assertEquals("android-io-network-connection-failed", standardPlaybackErrorCode(exo))
    }

    @Test
    fun aGiveUpSaysTheSameAsOnIos() {
        assertEquals("The track did not become ready (no progress for 10000 ms).", standardLoadGiveUpMessage(StallVerdict.STALLED, 10_000L, 60_000L))
        assertEquals("The track did not become ready (over the 60000 ms limit).", standardLoadGiveUpMessage(StallVerdict.CAP_EXCEEDED, 10_000L, 60_000L))
    }

    @Test
    fun aRebufferAfterASeekThatWasCancelledIsNotALoad() {
        // Ready, then a seek owns the loading (watch it not), then the seek is cancelled and the
        // item buffers: it was ready, so this is a rebuffer, not a load.
        observe(a, Player.STATE_READY)
        assertNull(observe(a, Player.STATE_BUFFERING, owned = true))
        assertNull(observe(a, Player.STATE_BUFFERING))
        now = 30_000L
        assertNull(observe(a, Player.STATE_BUFFERING))
        // A seek on an item that never was ready leaves a load to watch once it ends.
        // While the seek owns it, nothing is given up, however long it takes (its own limits).
        assertNull(observe(b, Player.STATE_BUFFERING, owned = true))
        now = 60_000L
        assertNull(observe(b, Player.STATE_BUFFERING, owned = true))
        assertNull(observe(b, Player.STATE_BUFFERING))
        now = 70_000L
        assertEquals(StallVerdict.STALLED, observe(b, Player.STATE_BUFFERING))
    }

    @Test
    fun theNextCheckIsAtTheGiveUpOrATenthOfTheStallTimeoutAndNoneWithoutALoad() {
        assertNull(watch.nextCheckInMs())
        observe(a, Player.STATE_BUFFERING)
        // 10 s stall timeout: read the progress every second.
        assertEquals(1_000L, watch.nextCheckInMs())
        now = 9_500L
        observe(a, Player.STATE_BUFFERING)
        // Half a second before the give-up: check then.
        assertEquals(500L, watch.nextCheckInMs())
        stall = 2_000L
        observe(b, Player.STATE_BUFFERING)
        assertEquals(200L, watch.nextCheckInMs())
        observe(b, Player.STATE_READY)
        assertNull(watch.nextCheckInMs())
        assertEquals(1L, standardLoadSampleIntervalMs(5L))
    }
}
