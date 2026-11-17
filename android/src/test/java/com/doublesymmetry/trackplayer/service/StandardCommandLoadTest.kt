package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A standard command's wait for its track's load (the crossfade rule), with [FailedLoadRule] as
 * the backend feeds them; the same cases as iOS's testStandardCommandLoad* tests.
 */
class StandardCommandLoadTest {
    private val first = Any()
    private val second = Any()
    private val third = Any()
    private val outcomes = mutableListOf<StandardCommandLoad.Outcome>()
    private val loads = StandardCommandLoad()
    private val rule = FailedLoadRule()

    /** A command moved the player to [item] and waits for its load, as the backend does. */
    private fun command(item: Any, into: MutableList<StandardCommandLoad.Outcome> = outcomes) {
        rule.command()
        loads.begin(item, rule.active, rule.reported) { into += it }
    }

    /** The player's item became ready, as the backend's followLoad. */
    private fun ready() {
        rule.ready()
        loads.ruleSettled(rule.active, rule.reported)
    }

    @Test
    fun smartMusicPlayersSequenceASkipAfterSettingTheQueueEndsOnceTheTargetLoadedAndIsReported() {
        // setQueue: the first track is selected (reported at once), then skip(2).
        rule.reset()
        rule.moved(first)
        command(third)
        rule.moved(third)
        assertTrue("the skip waits while its track loads", outcomes.isEmpty())
        assertEquals("the previous track is still the one the app has", first, rule.reported)
        ready()
        assertEquals(listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Loaded), outcomes)
        assertEquals("the target is the active track when the skip ends", third, rule.reported)
        // Previous: skip back to the second track.
        outcomes.clear()
        command(second)
        rule.moved(second)
        assertTrue(outcomes.isEmpty())
        ready()
        assertEquals(listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Loaded), outcomes)
        assertEquals(second, rule.reported)
    }

    @Test
    fun aSkipToTheSelectedFirstTrackOfANewQueueEndsAtItsLoadNotAtItsSelection() {
        rule.reset()
        rule.moved(first)
        assertEquals("selected and reported at once", first, rule.reported)
        command(first)
        assertTrue("reported but not loaded: the skip waits", outcomes.isEmpty())
        ready()
        assertEquals(listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Loaded), outcomes)
    }

    @Test
    fun aSkipToTheTrackAlreadyLoadedAndReportedEndsAtOnce() {
        rule.reset()
        rule.moved(first)
        rule.ready()
        assertNull(loads.begin(first, rule.active, rule.reported) { outcomes += it })
        assertEquals(listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Loaded), outcomes)
        assertFalse(loads.isWaiting)
    }

    @Test
    fun anotherTrackReadyDoesNotEndTheWait() {
        rule.reset()
        rule.moved(first)
        rule.ready()
        command(second)
        // The player still showed the first track ready (its move not yet seen).
        ready()
        assertTrue(outcomes.isEmpty())
        assertTrue(loads.isWaiting)
    }

    @Test
    fun aFailedLoadRejectsWithItsCodeAndTheCommandReportsIt() {
        rule.reset()
        rule.moved(first)
        rule.ready()
        command(second)
        rule.moved(second)
        assertTrue(loads.waitsFor(second))
        assertTrue(loads.reportsFailureOf(second))
        assertFalse("another track's failure is not this command's", loads.failed(first, STANDARD_LOAD_ERROR_CODE, "x", reportedByPlayer = true))
        rule.failed()
        assertTrue(loads.failed(second, STANDARD_LOAD_ERROR_CODE, "Source error", reportedByPlayer = true))
        assertEquals(
            listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Failed(STANDARD_LOAD_ERROR_CODE, "Source error")),
            outcomes
        )
        assertEquals("the previous track stays active", first, rule.reported)
        // Its player error is the rejection's, not a playback error, until the player leaves it.
        assertTrue(loads.reportsFailureOf(second))
        assertFalse(loads.reportsFailureOf(first))
        loads.failureCleared()
        assertFalse(loads.reportsFailureOf(second))
    }

    @Test
    fun aGiveUpTheCommandRejectedWithLeavesTheTracksLaterFailuresReported() {
        rule.reset()
        rule.moved(first)
        command(first)
        assertTrue(loads.failed(first, PREPARE_TIMEOUT_CODE, "The track did not become ready.", reportedByPlayer = false))
        assertEquals(
            listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Failed(PREPARE_TIMEOUT_CODE, "The track did not become ready.")),
            outcomes
        )
        // A play retries it and it gives up again, with no command waiting: a playback error.
        assertFalse(loads.reportsFailureOf(first))
    }

    @Test
    fun aWaitStartsItsTracksLoadOnlyWhenThePlayerStandsStill() {
        assertTrue(standardCommandLoadMustStart(targetLoaded = false, exoState = com.google.android.exoplayer2.Player.STATE_IDLE))
        assertFalse(standardCommandLoadMustStart(targetLoaded = false, exoState = com.google.android.exoplayer2.Player.STATE_BUFFERING))
        assertFalse(standardCommandLoadMustStart(targetLoaded = false, exoState = com.google.android.exoplayer2.Player.STATE_READY))
        assertFalse(standardCommandLoadMustStart(targetLoaded = true, exoState = com.google.android.exoplayer2.Player.STATE_IDLE))
    }

    @Test
    fun aNewerCommandCancelsTheOlderWait() {
        rule.reset()
        rule.moved(first)
        rule.ready()
        val older = mutableListOf<StandardCommandLoad.Outcome>()
        command(second, older)
        command(third)
        assertEquals(listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Cancelled), older)
        rule.moved(third)
        loads.cancel()
        assertEquals(listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Cancelled), outcomes)
        assertEquals("settled once", 1, older.size)
    }

    @Test
    fun aSeekPauseOrStopThatCancelsAWaitGoesBackToTheReportedTrack() {
        // A plays; a skip to B waits for its load (the player is on B); a seek, pause or stop
        // cancels it: the skip does not take effect, the player goes back to A (crossfade's
        // operation cancelled while it loads). iOS: the same steps.
        rule.reset()
        rule.moved(first)
        rule.ready()
        command(second)
        rule.moved(second)
        assertTrue("one was waiting", loads.cancel())
        assertEquals(listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Cancelled), outcomes)
        assertTrue(standardTrackToReturnTo(cancelledWait = true, playerItem = second, reported = rule.reported) === first)
        rule.moved(first)
        assertEquals(FailedLoadRule.Phase.Loaded(first), rule.phase)
        assertNull("nothing reported, nothing to reload", rule.play())
        // No wait cancelled (after a failed load too, LOAD-06): the player's own track.
        assertFalse("none waits any more", loads.cancel())
        assertNull(standardTrackToReturnTo(cancelledWait = false, playerItem = second, reported = first))
        // Already on the reported track, or none reported (the first load failed): it stays.
        assertNull(standardTrackToReturnTo(cancelledWait = true, playerItem = first, reported = first))
        assertNull(standardTrackToReturnTo(cancelledWait = true, playerItem = second, reported = null))
    }

    @Test
    fun aDroppedWaitEndsWithoutAResult() {
        val wait = loads.begin(first, null, null) { outcomes += it }!!
        loads.drop(wait)
        loads.ruleSettled(first, first)
        loads.cancel()
        assertTrue(outcomes.isEmpty())
        assertFalse(loads.isWaiting)
    }

    @Test
    fun theCodesAreTheCrossfadePaths() {
        assertEquals("crossfade_prepare_timeout", PREPARE_TIMEOUT_CODE)
        assertEquals("crossfade_engine_error", STANDARD_LOAD_ERROR_CODE)
    }
}
