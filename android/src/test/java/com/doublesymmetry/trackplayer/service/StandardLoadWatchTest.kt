package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.Player
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
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
    fun aSeekDuringALoadKeepsTheLoadsTotalLimitAndStartsItsProgressOnce() {
        // As iOS: the load began at 0; a seek owned it from 5 s to 56 s. Watched again, its total
        // limit still counts from 0 (60 s), with a fresh stall clock from the seek's end.
        var starts = 0
        val counted = StandardLoadWatch({ stall }, { 60_000L }, nowMs = { now }, onLoadStart = { starts += 1 })
        fun see(state: Int, owned: Boolean = false) =
            counted.check(StandardLoadObservation(b, state, false, longArrayOf(0L, 0L, 0L), ownedElsewhere = owned))
        assertNull(see(Player.STATE_BUFFERING))
        now = 5_000L
        assertNull(see(Player.STATE_BUFFERING, owned = true))
        now = 56_000L
        assertNull(see(Player.STATE_BUFFERING))
        assertEquals("the progress counter starts once per load", 1, starts)
        now = 59_999L
        assertNull(see(Player.STATE_BUFFERING))
        now = 60_000L
        assertEquals(StallVerdict.CAP_EXCEEDED, see(Player.STATE_BUFFERING))
        // A load first seen while a seek owns it began then (its total counts from 70 s).
        now = 70_000L
        assertNull(counted.check(StandardLoadObservation(a, Player.STATE_BUFFERING, false, longArrayOf(0L, 0L, 0L), ownedElsewhere = true)))
        now = 125_000L
        assertNull(counted.check(StandardLoadObservation(a, Player.STATE_BUFFERING, false, longArrayOf(0L, 0L, 0L))))
        now = 130_000L
        assertEquals(StallVerdict.CAP_EXCEEDED, counted.check(StandardLoadObservation(a, Player.STATE_BUFFERING, false, longArrayOf(0L, 0L, 0L))))
        assertEquals(2, starts)
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

    @Test
    fun theStateMovesBetweenIdleAndOneLoad() {
        // One explicit state (iOS: testStandardLoadWatchStateMovesBetweenIdleAndOneLoad, the same steps).
        val starts = mutableListOf<Long>()
        val watch = StandardLoadWatch({ stall }, { 60_000L }, nowMs = { now }, onLoadStart = { starts += now })
        fun see(item: Any?, state: Int, owned: Boolean = false, error: Boolean = false) =
            watch.check(StandardLoadObservation(item, state, error, longArrayOf(0L, 0L, 0L), ownedElsewhere = owned))
        fun load() = (watch.state as? StandardLoadWatch.State.Loading)?.load
        assertEquals(StandardLoadWatch.State.Idle(null), watch.state)
        now = 1_000L
        see(a, Player.STATE_BUFFERING)
        assertTrue(load()!!.item === a)
        assertEquals(1_000L, load()!!.startedAtMs)
        assertTrue(load()!!.progressStarted)
        assertNotNull(load()!!.watch)
        // A seek owns it: the same load, disarmed.
        now = 2_000L
        see(a, Player.STATE_BUFFERING, owned = true)
        assertEquals(1_000L, load()!!.startedAtMs)
        assertTrue(load()!!.progressStarted)
        assertNull(load()!!.watch)
        assertFalse(watch.isWatching)
        see(a, Player.STATE_READY)
        assertEquals(StandardLoadWatch.State.Idle(a), watch.state)
        // B loads while A stays the item ready since its load.
        now = 3_000L
        see(b, Player.STATE_BUFFERING)
        val loading = watch.state as StandardLoadWatch.State.Loading
        assertTrue(loading.ready === a)
        assertTrue(loading.load.item === b)
        assertEquals(3_000L, loading.load.startedAtMs)
        // Back on A buffering: a rebuffer, not a load (B's load is over).
        assertNull(see(a, Player.STATE_BUFFERING))
        assertEquals(StandardLoadWatch.State.Idle(a), watch.state)
        // A seek owning A's buffering starts no load either.
        see(a, Player.STATE_BUFFERING, owned = true)
        assertEquals(StandardLoadWatch.State.Idle(a), watch.state)
        // A give-up ends the load and keeps the ready item.
        now = 4_000L
        see(b, Player.STATE_BUFFERING)
        now = 14_000L
        assertEquals(StallVerdict.STALLED, see(b, Player.STATE_BUFFERING))
        assertEquals(StandardLoadWatch.State.Idle(a), watch.state)
        assertEquals("the limits of the last load stay", 10_000L, watch.lastStallTimeoutMs)
        assertEquals("one progress start per load", listOf(1_000L, 3_000L, 4_000L), starts)
        // An error, no item, the idle state and reset forget the ready item.
        see(a, Player.STATE_BUFFERING, error = true)
        assertEquals(StandardLoadWatch.State.Idle(null), watch.state)
        see(a, Player.STATE_READY)
        see(null, Player.STATE_BUFFERING)
        assertEquals(StandardLoadWatch.State.Idle(null), watch.state)
        see(a, Player.STATE_READY)
        see(a, Player.STATE_IDLE)
        assertEquals(StandardLoadWatch.State.Idle(null), watch.state)
        see(b, Player.STATE_BUFFERING)
        watch.reset()
        assertEquals(StandardLoadWatch.State.Idle(null), watch.state)
    }

    @Test
    fun withoutAProgressSignalOnlyTheTotalLimitEndsALoadAndTheStallRuleRunsFromTheSignal() {
        // iOS: testStandardLoadBeforeItsItemExistsOnlyTheTotalLimitEndsALoadAndTheStallRuleRunsFromTheItemsCreation,
        // the same steps (ExoPlayer's loads always have readings: the moves are kept the same).
        fun see(item: Any, readings: LongArray?) =
            watch.check(StandardLoadObservation(item, Player.STATE_BUFFERING, false, readings))
        assertNull(see(a, null))
        now = 15_000L
        assertNull("no signal after the stall timeout: the load goes on", see(a, null))
        now = 20_000L
        assertNull(see(a, longArrayOf(1L, 0L, 0L)))
        now = 29_999L
        assertNull(see(a, longArrayOf(1L, 0L, 0L)))
        now = 30_000L
        assertEquals("no progress for stallTimeoutMs from the signal", StallVerdict.STALLED, see(a, longArrayOf(1L, 0L, 0L)))
        now = 100_000L
        observe(b, Player.STATE_READY)
        observe(b, Player.STATE_IDLE)
        assertNull(see(b, null))
        now = 159_999L
        assertNull(see(b, null))
        now = 160_000L
        assertEquals(StallVerdict.CAP_EXCEEDED, see(b, null))
    }

    @Test
    fun withoutAProgressSignalTheNextCheckIsAtTheTotalLimitOrATenthOfTheStallTimeout() {
        // iOS: testStandardLoadBeforeItsItemExistsTheNextCheckIsAtTheTotalLimitOrATenthOfTheStallTimeout.
        val delays = mutableListOf<Long>()
        var verdict: StallVerdict? = null
        while (verdict == null && delays.size < 100) {
            verdict = watch.check(StandardLoadObservation(a, Player.STATE_BUFFERING, false, null))
            watch.nextCheckInMs()?.let { delays += it; now += it }
        }
        assertEquals(StallVerdict.CAP_EXCEEDED, verdict)
        assertEquals("every second until the total limit", 60, delays.size)
        assertFalse(delays.contains(0L))
        assertEquals(60_000L, now)
    }
}
