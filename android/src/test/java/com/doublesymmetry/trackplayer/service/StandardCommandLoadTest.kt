package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
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
        rule.skipped()
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
        val back = standardCancelledLoad(cancelledWait = true, playerItem = second, reported = rule.reported)
        assertTrue("back to A: $back", back is StandardCancelledLoad.ReturnsTo && back.item === first)
        rule.moved(first)
        assertEquals(FailedLoadRule.Phase.Loaded(first), rule.phase)
        assertNull("nothing reported, nothing to reload", rule.play())
        // No wait cancelled: a pause stays; a seek or stop on a track other than the reported one
        // (a failed skip, a natural advance loading) goes back to it (changed deliberately: owner
        // decision, 2026-11-17, LOAD-06), and with none reported acts on the player's own track
        // (the failed first track, retried).
        assertFalse("none waits any more", loads.cancel())
        assertSame(StandardCancelledLoad.Stays, standardCancelledLoad(cancelledWait = false, playerItem = second, reported = first))
        assertSame(StandardCancelledLoad.Stays, standardCancelledLoad(cancelledWait = false, playerItem = second, reported = null))
        val seekBack = standardCancelledLoad(cancelledWait = false, playerItem = second, reported = first, actsOnReportedTrack = true)
        assertTrue("a seek or stop goes back to A: $seekBack", seekBack is StandardCancelledLoad.ReturnsTo && seekBack.item === first)
        assertSame(StandardCancelledLoad.Stays, standardCancelledLoad(cancelledWait = false, playerItem = second, reported = null, actsOnReportedTrack = true))
        assertSame(StandardCancelledLoad.Stays, standardCancelledLoad(cancelledWait = false, playerItem = first, reported = first, actsOnReportedTrack = true))
        // Already on the reported track: it stays.
        assertSame(StandardCancelledLoad.Stays, standardCancelledLoad(cancelledWait = true, playerItem = first, reported = first))
        // None reported (the first load failed): the cancelled load stops, no active track (as
        // crossfade's active index -1), so the cancelled track is never reported.
        assertSame(StandardCancelledLoad.StopsInIdle, standardCancelledLoad(cancelledWait = true, playerItem = second, reported = null))
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

    @Test
    fun theStandardSeekResumeMovesByItsEvents() {
        // Every move of the explicit state: the same table as iOS's
        // testStandardSeekResumeMovesByItsEvents. Sixth review, I6: a seek that cancelled a
        // command's wait stays paused even after a failure (unreachable from the backend today:
        // every command that waits clears a failed load first, FailedLoadRule.skipped, and a failure
        // of the waited load settles the wait). Eighth round: a failure's request stays (the app
        // reads play-when-ready true) until a pause or stop, or the next command that loads a track
        // takes it over; a seek on the player's track with that request plays once done (a seek
        // after a seek that gave up); the latest seek that fails keeps it.
        val none = StandardSeekResume.Kind.NONE
        val kept = StandardSeekResume.Kind.KEPT_AFTER_FAILURE
        val resumes = StandardSeekResume.Kind.RESUMES_AFTER_SEEK
        val kinds = listOf(none, kept, resumes)
        fun machine(kind: StandardSeekResume.Kind) = StandardSeekResume().apply {
            when (kind) {
                StandardSeekResume.Kind.NONE -> Unit
                StandardSeekResume.Kind.KEPT_AFTER_FAILURE -> gaveUp(playing = true)
                StandardSeekResume.Kind.RESUMES_AFTER_SEEK -> seekBegan(returnsToActiveTrack = true, afterFailedLoad = true, cancelledWait = false, playerPlaying = true)
            }
            assertEquals(kind, this.kind)
        }
        assertEquals(listOf(false, true, true), kinds.map { machine(it).requestsPlay })
        assertEquals(listOf(kept, kept, kept), kinds.map { machine(it).apply { gaveUp(playing = true) }.kind })
        assertEquals(listOf(none, kept, kept), kinds.map { machine(it).apply { gaveUp(playing = false) }.kind })
        assertEquals(listOf(none, none, none), kinds.map { machine(it).apply { paused() }.kind })
        assertEquals(listOf(false, true, true), kinds.map { machine(it).handedToPlayer() })
        assertEquals(listOf(none, none, none), kinds.map { machine(it).apply { handedToPlayer() }.kind })
        // seekBegan: (returns, afterFailed, cancelledWait, playerPlaying) -> after each kind.
        val table = listOf(
            listOf(true, true, false, false) to listOf(none, resumes, resumes),
            listOf(true, true, false, true) to listOf(resumes, resumes, resumes),
            listOf(true, false, false, true) to listOf(none, none, none),
            listOf(true, false, false, false) to listOf(none, none, none),
            listOf(true, true, true, true) to listOf(none, none, none),
            listOf(false, false, true, true) to listOf(none, none, none),
            listOf(false, false, false, true) to listOf(none, resumes, resumes),
            listOf(false, false, false, false) to listOf(none, resumes, resumes),
            listOf(false, true, false, true) to listOf(none, resumes, resumes)
        )
        for ((input, after) in table) {
            val got = kinds.map {
                machine(it).apply { seekBegan(input[0], input[1], input[2], input[3]) }.kind
            }
            assertEquals("$input", after, got)
        }
        // seekEnded: only the latest seek, only once; one that failed keeps the request.
        val m = machine(resumes)
        val first = m.seekBegan(false, false, false, false)
        val second = m.seekBegan(false, false, false, false)
        assertFalse("an older seek", m.seekEnded(first, succeeded = true))
        assertEquals(resumes, m.kind)
        assertTrue(m.seekEnded(second, succeeded = true))
        assertEquals(none, m.kind)
        assertFalse("once", m.seekEnded(second, succeeded = true))
        val failed = machine(resumes)
        assertFalse(failed.seekEnded(failed.seekBegan(false, false, false, false), succeeded = false))
        assertEquals("the latest seek failed: the request stays", kept, failed.kind)
        val keptMachine = machine(kept)
        assertFalse(keptMachine.seekEnded(0L, succeeded = true))
        assertEquals("a failure's request waits for the next seek or command", kept, keptMachine.kind)
        // While a seek holds the player paused the app reads LOADING, as crossfade's seek.
        val held = listOf(AudioPlayerState.LOADING, AudioPlayerState.BUFFERING, AudioPlayerState.READY, AudioPlayerState.PAUSED)
        val passed = AudioPlayerState.values().filter { it !in held }
        for (kind in kinds) {
            val machine = machine(kind)
            for (state in held) assertEquals("$kind $state", if (kind == resumes) AudioPlayerState.LOADING else state, machine.reportedState(state))
            for (state in passed) assertEquals("$kind $state", state, machine.reportedState(state))
        }
    }
}
