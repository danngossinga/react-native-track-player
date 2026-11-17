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
        assertFalse("another track's failure is not this command's", loads.failed(first, PREPARE_TIMEOUT_CODE, "x"))
        rule.failed()
        assertTrue(loads.failed(second, PREPARE_TIMEOUT_CODE, "The track did not become ready."))
        assertEquals(
            listOf<StandardCommandLoad.Outcome>(StandardCommandLoad.Outcome.Failed(PREPARE_TIMEOUT_CODE, "The track did not become ready.")),
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
