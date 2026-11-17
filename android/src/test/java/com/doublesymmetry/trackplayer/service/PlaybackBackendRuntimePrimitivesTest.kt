package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.trackplayer.utils.RejectionException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackBackendRuntimePrimitivesTest {
    @Test
    fun standardLogicalIdleMasksKotlinAudioPhysicalAutoSelection() {
        for (logicalIndex in listOf<Int?>(null, -1)) {
            val sidecar = KotlinAudioLogicalPlaybackStateSidecar()
            sidecar.restore(
                PlaybackBackendSnapshot(
                    queueIds = listOf("queued"),
                    activeIndex = logicalIndex,
                    activeTrackId = null,
                    positionMs = 0L,
                    playWhenReady = false,
                    volume = 1f,
                    rate = 1f,
                    repeatMode = 0,
                    transitionGeneration = 0L
                )
            )

            assertEquals(-1, sidecar.currentIndex(physicalIndex = 0))
            assertEquals(AudioPlayerState.IDLE, sidecar.playbackState(AudioPlayerState.READY))
            assertEquals(0L, sidecar.positionMs(physicalPositionMs = 321L))
            assertEquals(0L, sidecar.durationMs(physicalDurationMs = 4_000L))
            assertEquals(0L, sidecar.bufferedMs(physicalBufferedMs = 2_000L))
            assertFalse(sidecar.playWhenReady(physicalPlayWhenReady = true))
            assertNull(sidecar.activeIndex(physicalIndex = 0, queueSize = 1))
        }
    }

    @Test
    fun standardLogicalIdleSurvivesPauseAndReadsUntilExplicitActivation() {
        val sidecar = KotlinAudioLogicalPlaybackStateSidecar()
        sidecar.restore(PlaybackBackendSnapshot.empty().copy(queueIds = listOf("queued")))

        assertEquals(AudioPlayerState.IDLE, sidecar.playbackState(AudioPlayerState.PAUSED))
        assertEquals(-1, sidecar.currentIndex(0))
        assertEquals(AudioPlayerState.IDLE, sidecar.playbackState(AudioPlayerState.READY))

        sidecar.activate()

        assertEquals(0, sidecar.currentIndex(0))
        assertEquals(AudioPlayerState.READY, sidecar.playbackState(AudioPlayerState.READY))
        assertEquals(321L, sidecar.positionMs(321L))
        assertEquals(4_000L, sidecar.durationMs(4_000L))
        assertEquals(2_000L, sidecar.bufferedMs(2_000L))
        assertTrue(sidecar.playWhenReady(true))
        assertEquals(0, sidecar.activeIndex(physicalIndex = 0, queueSize = 1))
    }

    @Test
    fun standardLogicalIdleNextActivatesPhysicalZeroButPreviousStaysIdle() {
        val sidecar = KotlinAudioLogicalPlaybackStateSidecar()
        sidecar.restore(PlaybackBackendSnapshot.empty().copy(queueIds = listOf("first", "second")))

        assertTrue(sidecar.shouldIgnorePrevious())
        assertEquals(-1, sidecar.currentIndex(physicalIndex = 0))
        assertTrue(sidecar.consumeIdleForNext())
        assertEquals(0, sidecar.currentIndex(physicalIndex = 0))
        assertFalse(sidecar.consumeIdleForNext())
        assertFalse(sidecar.shouldIgnorePrevious())
    }

    @Test
    fun standardLogicalIdleQueueMutationPolicyOnlyPreservesRestoredIdle() {
        val sidecar = KotlinAudioLogicalPlaybackStateSidecar()

        sidecar.restore(PlaybackBackendSnapshot.empty())
        sidecar.onQueueSizeChanged(queueSize = 2)
        assertTrue(sidecar.hasLogicalActiveItem(physicalIndex = 0))

        sidecar.restore(PlaybackBackendSnapshot.empty().copy(queueIds = listOf("first", "second")))
        sidecar.onQueueSizeChanged(queueSize = 3)
        assertFalse(sidecar.hasLogicalActiveItem(physicalIndex = 0))

        sidecar.onQueueCleared()
        assertFalse(sidecar.hasLogicalActiveItem(physicalIndex = -1))
    }

    @Test
    fun standardFailedExplicitActivationRestoresLogicalIdle() {
        val sidecar = KotlinAudioLogicalPlaybackStateSidecar()
        sidecar.restore(PlaybackBackendSnapshot.empty().copy(queueIds = listOf("first")))

        val wasIdle = sidecar.activate()
        sidecar.rollbackActivation(wasIdle)

        assertEquals(-1, sidecar.currentIndex(physicalIndex = 0))
        assertEquals(AudioPlayerState.IDLE, sidecar.playbackState(AudioPlayerState.READY))
    }

    @Test
    fun standardActivationValidatorAcceptsOnlyCoherentIdleOrActiveSnapshots() {
        val idle = PlaybackBackendSnapshot.empty().copy(queueIds = listOf("first"))
        StandardPlaybackActivationSnapshotValidator.validate(idle)
        StandardPlaybackActivationSnapshotValidator.validate(
            idle.copy(activeIndex = 0, activeTrackId = "first", playWhenReady = true)
        )

        val incoherent = listOf(
            idle.copy(playWhenReady = true),
            idle.copy(activeIndex = -1),
            idle.copy(activeTrackId = "first"),
            idle.copy(activeIndex = 0, activeTrackId = null),
            idle.copy(activeIndex = 0, activeTrackId = "wrong"),
            idle.copy(activeIndex = 1, activeTrackId = "first")
        )
        incoherent.forEach { snapshot ->
            try {
                StandardPlaybackActivationSnapshotValidator.validate(snapshot)
                fail("expected incoherent snapshot rejection: $snapshot")
            } catch (error: RejectionException) {
                assertEquals("playback_backend_activation_not_ready", error.code)
            }
        }
    }

    @Test
    fun standardReadinessPollsCurrentStateSoAReadyTransitionCannotBeLost() = runTest {
        val observations = listOf(
            StandardPlaybackReadinessObservation(AudioPlayerState.LOADING, 1, 0L, 0L),
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 1, 12_345L, 0L)
        )
        var readCount = 0
        val gate = StandardPlaybackReadinessGate(timeoutMs = { 100L }, stallTimeoutMs = { 10_000L }, pollIntervalMs = 1L, nowMs = { currentTime })

        gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
            observations[minOf(readCount++, observations.lastIndex)]
        }

        assertEquals(2, readCount)
    }

    @Test
    fun standardReadinessRequiresReadyIndexAndRestoredPosition() = runTest {
        val observations = listOf(
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 0, 12_345L, 0L),
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 1, 13_096L, 0L),
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 1, 13_095L, 0L)
        )
        var readCount = 0
        val gate = StandardPlaybackReadinessGate(
            timeoutMs = { 100L },
            stallTimeoutMs = { 10_000L },
            pollIntervalMs = 1L,
            positionToleranceMs = { 750L },
            nowMs = { currentTime }
        )

        gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
            observations[minOf(readCount++, observations.lastIndex)]
        }

        assertEquals(3, readCount)
    }

    @Test
    fun standardReadinessAcceptsPausedAndPlayingAfterRestore() = runTest {
        for (state in listOf(AudioPlayerState.PAUSED, AudioPlayerState.PLAYING)) {
            val gate = StandardPlaybackReadinessGate(timeoutMs = { 5L }, stallTimeoutMs = { 10_000L }, pollIntervalMs = 1L, nowMs = { currentTime })

            gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
                StandardPlaybackReadinessObservation(state, 1, 12_345L, 0L)
            }
        }
    }

    @Test
    fun standardReadinessRejectsPlayerError() = runTest {
        val gate = StandardPlaybackReadinessGate(timeoutMs = { 100L }, stallTimeoutMs = { 10_000L }, pollIntervalMs = 1L, nowMs = { currentTime })

        try {
            gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
                StandardPlaybackReadinessObservation(AudioPlayerState.ERROR, 1, 12_345L, 0L)
            }
            fail("expected readiness failure")
        } catch (error: RejectionException) {
            assertEquals("playback_backend_activation_not_ready", error.code)
        }
    }

    @Test
    fun standardReadinessRejectsLoadingAndBufferingUntilBoundedTimeout() = runTest {
        for (state in listOf(AudioPlayerState.LOADING, AudioPlayerState.BUFFERING)) {
            val gate = StandardPlaybackReadinessGate(timeoutMs = { 5L }, stallTimeoutMs = { 10_000L }, pollIntervalMs = 1L, nowMs = { currentTime })

            try {
                gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
                    StandardPlaybackReadinessObservation(state, 1, 12_345L, 0L)
                }
                fail("expected readiness timeout for $state")
            } catch (error: RejectionException) {
                assertEquals("playback_backend_activation_not_ready", error.code)
            }
        }
    }

    @Test
    fun operationTicketCancelsBlockedMediaWaitExactlyOnce() = runTest {
        val controller = PlaybackOperationController()
        val ticket = controller.begin()
        val wait = async {
            ticket.delayOrThrow(5_000)
            fail("cancelled media wait completed normally")
        }

        controller.invalidate("pause")
        controller.invalidate("stop")
        runCurrent()

        assertTrue(wait.isCompleted)
        try {
            wait.await()
            fail("expected cancellation")
        } catch (error: PlaybackOperationCancelledException) {
            assertEquals("pause", error.reason)
        }
        assertEquals(1, ticket.cancellationCount)
    }

    @Test
    fun staleTicketCannotOverwriteNewEngineRun() = runTest {
        val controller = PlaybackOperationController()
        val stale = controller.begin()
        controller.invalidate("seek")
        val current = controller.begin()

        assertFalse(controller.isCurrent(stale))
        assertTrue(controller.isCurrent(current))
    }

    @Test
    fun adapterQueueStateRollbackNeverPublishesCandidatePendingQueue() {
        val state = PlaybackBackendQueueState(listOf("old-a", "old-b"))
        state.stage(listOf("candidate-a"))

        val rollback = state.rollback()

        assertEquals(listOf("old-a", "old-b"), rollback)
        assertEquals(listOf("old-a", "old-b"), state.authoritative())
    }

    @Test
    fun standardReadinessGateReadsItsTimeoutAtEveryWait() = runTest {
        var setting = 50L
        var reads = 0
        val gate = StandardPlaybackReadinessGate(
            timeoutMs = { reads += 1; setting },
            stallTimeoutMs = { 10_000L },
            pollIntervalMs = 1L,
            nowMs = { currentTime }
        )
        val notReady = StandardPlaybackReadinessObservation(AudioPlayerState.LOADING, 0, 0L, 0L)
        val started = currentTime
        runCatching { gate.await(expectedIndex = 0, expectedPositionMs = 0L) { notReady } }
        assertEquals(50L, currentTime - started)
        setting = 200L
        val again = currentTime
        runCatching { gate.await(expectedIndex = 0, expectedPositionMs = 0L) { notReady } }
        assertEquals(200L, currentTime - again)
        assertEquals(2, reads)
    }

    @Test
    fun standardReadinessWaitsWhileTheTrackKeepsBufferingAndFailsWhenItStalls() = runTest {
        // Buffering a little every 100 ms: the wait outlives the 300 ms stall timeout and only
        // gives up at its 2 s limit.
        var buffered = 0L
        val gate = StandardPlaybackReadinessGate(
            timeoutMs = { 2_000L },
            stallTimeoutMs = { 300L },
            pollIntervalMs = 100L,
            nowMs = { currentTime }
        )
        val started = currentTime
        val progressing = runCatching {
            gate.await(expectedIndex = 0, expectedPositionMs = 0L) {
                buffered += 500L
                StandardPlaybackReadinessObservation(AudioPlayerState.BUFFERING, 0, 0L, buffered)
            }
        }
        assertTrue(progressing.isFailure)
        assertEquals(2_000L, currentTime - started)

        // Nothing more buffers: it fails at the stall timeout, long before the limit.
        val stalledAt = currentTime
        val stalled = runCatching {
            gate.await(expectedIndex = 0, expectedPositionMs = 0L) {
                StandardPlaybackReadinessObservation(AudioPlayerState.BUFFERING, 0, 0L, 4_000L)
            }
        }
        assertTrue(stalled.isFailure)
        assertEquals(300L, currentTime - stalledAt)
    }

    @Test
    fun standardReadinessGateReadsItsStallTimeoutAtEveryWait() = runTest {
        var stall = 200L
        val gate = StandardPlaybackReadinessGate(
            timeoutMs = { 60_000L },
            stallTimeoutMs = { stall },
            pollIntervalMs = 50L,
            nowMs = { currentTime }
        )
        val notReady = StandardPlaybackReadinessObservation(AudioPlayerState.LOADING, 0, 0L, 0L)
        val started = currentTime
        runCatching { gate.await(expectedIndex = 0, expectedPositionMs = 0L) { notReady } }
        assertEquals(200L, currentTime - started)
        stall = 400L
        val again = currentTime
        runCatching { gate.await(expectedIndex = 0, expectedPositionMs = 0L) { notReady } }
        assertEquals(400L, currentTime - again)
    }

    @Test
    fun aStandardSeekWaitsWhileBufferingGrowsAndFailsWhenItStalls() = runTest {
        var stall = 300L
        var limit = 2_000L
        val gate = StandardSeekGate(timeoutMs = { limit }, stallTimeoutMs = { stall }, pollIntervalMs = 100L, nowMs = { currentTime })
        val item = Any()
        // Buffering at the target, data arriving: it waits up to its limit.
        var buffered = 0L
        val started = currentTime
        val progressing = runCatching {
            gate.await(20_000L, item) {
                buffered += 500L
                StandardSeekObservation(AudioPlayerState.BUFFERING, 20_000L, buffered, item = item)
            }
        }
        assertEquals("standard_seek_timeout", (progressing.exceptionOrNull() as RejectionException).code)
        assertEquals(2_000L, currentTime - started)
        // No data: it fails at the stall timeout read now.
        stall = 400L
        val stalledAt = currentTime
        val stalled = runCatching {
            gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.BUFFERING, 20_000L, 9_000L, item = item) }
        }
        assertEquals("standard_seek_timeout", (stalled.exceptionOrNull() as RejectionException).code)
        assertEquals(400L, currentTime - stalledAt)
        // Ready at the target: done at once; a seek past the end completes at the end.
        limit = 60_000L
        gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 20_100L, 25_000L, item = item) }
        gate.await(90_000L, item) { StandardSeekObservation(AudioPlayerState.PAUSED, 60_000L, 60_000L, durationMs = 60_000L, item = item) }
    }

    @Test
    fun aSeekInATrackThePlayerCannotSeekInCompletesWhereThePlayerLandsOnceLoaded() = runTest {
        // ExoPlayer lands a seek in a track it cannot seek in at the start, and completes it.
        val gate = StandardSeekGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 1_000L }, pollIntervalMs = 100L, nowMs = { currentTime })
        val item = Any()
        var reads = 0
        val started = currentTime
        gate.await(20_000L, item) {
            reads += 1
            // Loading (masked by the seek) first, then ready where it landed.
            if (reads < 3) StandardSeekObservation(AudioPlayerState.BUFFERING, 20_000L, reads * 100L, item = item, seekable = false)
            else StandardSeekObservation(AudioPlayerState.READY, 0L, 4_000L, item = item, seekable = false)
        }
        assertEquals("done at the first ready reading", 3, reads)
        assertEquals(200L, currentTime - started)
        // A track it can seek in, ready short of the target: not done (it gives up at the stall).
        val seekable = runCatching {
            gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 0L, 4_000L, item = item) }
        }
        assertEquals("standard_seek_timeout", (seekable.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aStandardSeekFailsAtOnceOnAPlayerError() = runTest {
        val gate = StandardSeekGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 10_000L }, nowMs = { currentTime })
        val item = Any()
        val failed = runCatching { gate.await(1_000L, item) { StandardSeekObservation(AudioPlayerState.ERROR, 0L, 0L, item = item) } }
        assertEquals("standard_seek_unavailable", (failed.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aStandardSeekWithNoActiveTrackFailsAtOnceAsOnIos() = runTest {
        val gate = StandardSeekGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 10_000L }, nowMs = { currentTime })
        var observed = false
        val started = currentTime
        val failed = runCatching { gate.await(1_000L, item = null) { observed = true; StandardSeekObservation(AudioPlayerState.IDLE, 0L, 0L) } }
        assertEquals("standard_seek_unavailable", (failed.exceptionOrNull() as RejectionException).code)
        assertEquals(0L, currentTime - started)
        assertFalse(observed)
    }

    @Test
    fun aStandardSeekThatReachesTheEndOfTheTrackCompletes() = runTest {
        val gate = StandardSeekGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 10_000L }, nowMs = { currentTime })
        val item = Any()
        val started = currentTime
        // Far from the target and not ready, but the track ended: the seek is done.
        gate.await(50_000L, item) { StandardSeekObservation(AudioPlayerState.ENDED, 1_000L, 1_000L, item = item) }
        assertEquals(0L, currentTime - started)
    }

    @Test
    fun aNewerSeekASkipOrAnotherItemEndsTheOlderSeekAtOnce() = runTest {
        val gate = StandardSeekGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 60_000L }, pollIntervalMs = 1_000L, nowMs = { currentTime })
        val item = Any()
        val buffering = { StandardSeekObservation(AudioPlayerState.BUFFERING, 0L, 0L, item = item) }

        // A newer seek: the older one ends at once with standard_seek_cancelled.
        val older = async { runCatching { gate.await(30_000L, item, buffering) } }
        runCurrent()
        val newer = async { runCatching { gate.await(40_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 40_000L, 41_000L, item = item) } } }
        runCurrent()
        assertEquals("standard_seek_cancelled", (older.await().exceptionOrNull() as RejectionException).code)
        assertTrue(newer.await().isSuccess)

        // A skip.
        val skipped = async { runCatching { gate.await(30_000L, item, buffering) } }
        runCurrent()
        val skippedAt = currentTime
        gate.cancel("skip")
        assertEquals("standard_seek_cancelled", (skipped.await().exceptionOrNull() as RejectionException).code)
        assertEquals(0L, currentTime - skippedAt)

        // Another item (an auto-advance).
        val advanced = runCatching { gate.await(30_000L, item) { StandardSeekObservation(AudioPlayerState.BUFFERING, 0L, 0L, item = Any()) } }
        assertEquals("standard_seek_cancelled", (advanced.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aStandardSeekReadsThePlayerEveryTenthOfTheStallTimeoutAndAtEveryEvent() = runTest {
        // No fixed poll: between the player's events the seek samples the player every
        // stallTimeoutMs / 10 (as the load watch, and iOS); an event (poke) looks at once.
        val gate = StandardSeekGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 10_000L }, nowMs = { currentTime })
        val item = Any()
        var reads = 0
        var ready = false
        val started = currentTime
        val wait = async {
            gate.await(20_000L, item) {
                reads += 1
                StandardSeekObservation(if (ready) AudioPlayerState.READY else AudioPlayerState.BUFFERING, 20_000L, reads * 100L, item = item)
            }
        }
        advanceTimeBy(5_000L)
        runCurrent()
        assertEquals("one reading at the start and one a second", 6, reads)
        advanceTimeBy(300L)
        ready = true
        gate.poke()
        runCurrent()
        assertTrue("the player's event ended the seek", wait.isCompleted)
        assertEquals(5_300L, currentTime - started)
    }

    @Test
    fun aStandardSeekIsNeverDoneBeforeItsTargetWhateverTheSamplingPeriod() = runTest {
        // Sampled every 200 ms (stallTimeoutMs / 10), ready 150 ms before the target: not this
        // seek's position (the sampling period is no tolerance).
        val gate = StandardSeekGate(timeoutMs = { 2_000L }, stallTimeoutMs = { 2_000L }, nowMs = { currentTime })
        val item = Any()
        val early = runCatching {
            gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 19_850L, 30_000L, item = item) }
        }
        assertEquals("standard_seek_timeout", (early.exceptionOrNull() as RejectionException).code)
        assertTrue(standardSeekIsAtTarget(20_000L, 20_000L, playedMs = 0L, sinceLastMs = 0L))
        assertFalse(standardSeekIsAtTarget(19_999L, 20_000L, playedMs = 500L, sinceLastMs = 200L))
        assertTrue(standardSeekIsAtTarget(20_700L, 20_000L, playedMs = 500L, sinceLastMs = 200L))
        assertFalse(standardSeekIsAtTarget(20_701L, 20_000L, playedMs = 500L, sinceLastMs = 200L))
    }

    @Test
    fun aStandardBackendSwitchReadsThePlayerEveryTenthOfTheStallTimeoutAndAtEveryEvent() = runTest {
        val gate = StandardPlaybackReadinessGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 10_000L }, nowMs = { currentTime })
        var reads = 0
        var ready = false
        val started = currentTime
        val wait = async {
            gate.await(expectedIndex = 0, expectedPositionMs = 0L) {
                reads += 1
                StandardPlaybackReadinessObservation(if (ready) AudioPlayerState.READY else AudioPlayerState.BUFFERING, 0, 0L, reads * 100L)
            }
        }
        advanceTimeBy(5_000L)
        runCurrent()
        assertEquals("one reading at the start and one a second", 6, reads)
        advanceTimeBy(300L)
        ready = true
        gate.poke()
        runCurrent()
        assertTrue("the player's event ended the wait", wait.isCompleted)
        assertEquals(5_300L, currentTime - started)
    }

    @Test
    fun aSeekIsAtItsTargetWithinWhatPlaybackCouldHaveMovedNotAFixedTolerance() = runTest {
        val gate = StandardSeekGate(timeoutMs = { 2_000L }, stallTimeoutMs = { 2_000L }, pollIntervalMs = 100L, nowMs = { currentTime })
        val item = Any()
        // Ready, but 700 ms past the target right after the seek: not this seek's position yet
        // (a fixed 750 ms tolerance would have taken it).
        val early = runCatching {
            gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 20_700L, 30_000L, item = item) }
        }
        assertEquals("standard_seek_timeout", (early.exceptionOrNull() as RejectionException).code)
        // Playing at 2x for 500 ms since the seek: up to 1 s (plus one poll) past the target is it.
        var position = 20_000L
        val started = currentTime
        gate.await(20_000L, item) {
            position = 20_000L + (currentTime - started) * 2
            StandardSeekObservation(AudioPlayerState.PLAYING, if (currentTime - started >= 500L) position else 25_000L, 30_000L, item = item, rate = 2f)
        }
        assertEquals(500L, currentTime - started)
    }

    @Test
    fun theRestoredPositionToleranceIsTheAppsSettingReadAtEveryWait() = runTest {
        var tolerance = 750L
        val gate = StandardPlaybackReadinessGate(
            timeoutMs = { 50L }, stallTimeoutMs = { 10_000L }, pollIntervalMs = 1L,
            positionToleranceMs = { tolerance }, nowMs = { currentTime }
        )
        val offBy500 = StandardPlaybackReadinessObservation(AudioPlayerState.READY, 0, 10_500L, 0L)
        gate.await(expectedIndex = 0, expectedPositionMs = 10_000L) { offBy500 }
        tolerance = 200L
        val failed = runCatching { gate.await(expectedIndex = 0, expectedPositionMs = 10_000L) { offBy500 } }
        assertEquals("playback_backend_activation_not_ready", (failed.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aSeekThatPlaysThroughTheEndOfTheTrackIsDoneAsOnIos() = runTest {
        val gate = StandardSeekGate(timeoutMs = { 2_000L }, stallTimeoutMs = { 2_000L }, pollIntervalMs = 100L, nowMs = { currentTime })
        val item = Any()
        var transitions = 3L
        val started = currentTime
        // Repeat-one: a seek near the end loops back to the start; the position never sits at the
        // target, but the player made an automatic transition (it played to the end).
        gate.await(59_900L, item) {
            if (currentTime - started >= 300L) transitions = 4L
            StandardSeekObservation(AudioPlayerState.PLAYING, 200L, 5_000L, durationMs = 60_000L, item = item, autoTransitions = transitions)
        }
        assertEquals(300L, currentTime - started)
        // The next track began after the seek (repeat off): done too, not cancelled.
        var current: Any = item
        var count = 10L
        gate.await(59_900L, item) {
            val observation = StandardSeekObservation(AudioPlayerState.PLAYING, 100L, 5_000L, item = current, autoTransitions = count)
            current = Any(); count = 11L
            observation
        }
    }

    /**
     * The real ordering in ExoPlayer 2.19 under KotlinAudio: seekTo moves the position to the target
     * and masks ExoPlayer's state to buffering at once; KotlinAudio's state still says what it was
     * (it follows on a later message, in onEvents).
     */
    private class MaskingPlayer(private val nowMs: () -> Long) : StandardSeekPlayer {
        override var currentItem: Any? = Any()
        override var kotlinAudioState = AudioPlayerState.READY
        var exoState = com.google.android.exoplayer2.Player.STATE_READY
        var exoError = false
        /** Asked to play: once ready, it plays and the position moves on at [rate]. */
        var playWhenReady = false
        override var rate = 1f
        override val durationMs = 60_000L
        override val autoTransitions = 0L
        val calls = mutableListOf<String>()
        /** ExoPlayer becomes ready this long after the seek, data arriving meanwhile (null: no data, never). */
        var readyAfterMs: Long? = 300L
        /** When set, the track ends (STATE_ENDED) this long after the seek instead of becoming ready. */
        var endsAfterMs: Long? = null
        private var seekAt = 0L
        private var target = 0L

        private val buffering: Boolean
            get() = exoState == com.google.android.exoplayer2.Player.STATE_BUFFERING

        private fun since() = nowMs() - seekAt

        private val effectiveState: Int
            get() {
                val ends = endsAfterMs
                if (buffering && ends != null && since() >= ends) return com.google.android.exoplayer2.Player.STATE_ENDED
                val ready = readyAfterMs
                return if (buffering && ready != null && since() >= ready) com.google.android.exoplayer2.Player.STATE_READY else exoState
            }

        override val exo = object : ExoSeekState {
            override val playbackState: Int get() = effectiveState
            override val hasError: Boolean get() = exoError
            override val isPlaying: Boolean
                get() = playWhenReady && effectiveState == com.google.android.exoplayer2.Player.STATE_READY
            override val isSeekable: Boolean = true
        }

        override val positionMs: Long
            get() {
                val ready = readyAfterMs ?: return target
                if (effectiveState == com.google.android.exoplayer2.Player.STATE_ENDED) return durationMs
                return if (exo.isPlaying) target + ((since() - ready) * rate).toLong() else target
            }

        override val bufferedPositionMs: Long
            get() = if (buffering && readyAfterMs != null) since() else 0L

        override fun prepare() {
            calls += "prepare"
            exoState = com.google.android.exoplayer2.Player.STATE_BUFFERING
        }

        override fun seekTo(positionMs: Long) {
            calls += "seek"
            seekAt = nowMs()
            target = positionMs
            if (exoState != com.google.android.exoplayer2.Player.STATE_IDLE) {
                exoState = com.google.android.exoplayer2.Player.STATE_BUFFERING
            }
        }
    }

    private fun gate(scope: kotlinx.coroutines.test.TestScope) = StandardSeekGate(
        timeoutMs = { 5_000L }, stallTimeoutMs = { 1_000L }, pollIntervalMs = 100L, nowMs = { scope.currentTime }
    )

    @Test
    fun aSeekWaitsForExoPlayersMaskedStateNotKotlinAudiosStaleOne() = runTest {
        val player = MaskingPlayer { currentTime }
        val started = currentTime
        gate(this).seek(player, 30_000L)
        // KotlinAudio still said READY at the target from the first check: the wait must not end
        // there, only once ExoPlayer is ready.
        assertEquals(300L, currentTime - started)
        assertEquals(listOf("seek"), player.calls)
    }

    @Test
    fun aSeekThatNeverGetsDataTimesOutInTheRealOrdering() = runTest {
        val player = MaskingPlayer { currentTime }.apply { readyAfterMs = null }
        val started = currentTime
        val failed = runCatching { gate(this).seek(player, 30_000L) }
        assertEquals("standard_seek_timeout", (failed.exceptionOrNull() as RejectionException).code)
        assertEquals(1_000L, currentTime - started)
    }

    @Test
    fun aSeekWhileStoppedLoadsTheItemFirstAndWaitsForIt() = runTest {
        val player = MaskingPlayer { currentTime }.apply {
            kotlinAudioState = AudioPlayerState.STOPPED
            exoState = com.google.android.exoplayer2.Player.STATE_IDLE
        }
        val started = currentTime
        gate(this).seek(player, 30_000L)
        assertEquals(listOf("prepare", "seek"), player.calls)
        assertEquals(300L, currentTime - started)
    }

    @Test
    fun aSeekOnAnUnloadedPlayerIsNotDoneAtTheMaskedPosition() = runTest {
        // Never prepared (IDLE) but the position reads the target: not done; it times out.
        val player = MaskingPlayer { currentTime }.apply {
            exoState = com.google.android.exoplayer2.Player.STATE_IDLE
        }
        val failed = runCatching { gate(this).seek(player, 30_000L) }
        assertEquals("standard_seek_timeout", (failed.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aSeekWithNoItemOrAPlayerErrorFailsAtOnceInTheRealOrdering() = runTest {
        val none = MaskingPlayer { currentTime }.apply { currentItem = null }
        val unavailable = runCatching { gate(this).seek(none, 30_000L) }
        assertEquals("standard_seek_unavailable", (unavailable.exceptionOrNull() as RejectionException).code)
        assertTrue(none.calls.isEmpty())
        // ExoPlayer failed; KotlinAudio's state has not caught up (still READY).
        val failing = MaskingPlayer { currentTime }.apply { exoError = true }
        val failed = runCatching { gate(this).seek(failing, 30_000L) }
        assertEquals("standard_seek_unavailable", (failed.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aSeekWhilePlayingFastWithALatePollCompletes() = runTest {
        // Ready 120 ms after the seek, then playing at 2x; the first poll after that lands at
        // 200 ms (80 ms late): the position is 160 ms past the target, which playback explains.
        val player = MaskingPlayer { currentTime }.apply {
            readyAfterMs = 120L
            playWhenReady = true
            rate = 2f
        }
        val started = currentTime
        gate(this).seek(player, 30_000L)
        assertEquals(200L, currentTime - started)
    }

    @Test
    fun readyAndPausedIsReadyAndReadyAndPlayingIsPlaying() = runTest {
        val player = MaskingPlayer { currentTime }
        player.seekTo(30_000L)
        advanceTimeBy(400L)
        // Ready, not asked to play: paused at the target, the position does not move.
        assertEquals(AudioPlayerState.READY, player.seekObservation().state)
        player.playWhenReady = true
        assertEquals(AudioPlayerState.PLAYING, player.seekObservation().state)
    }

    @Test
    fun aKotlinAudioErrorFailsTheSeekEvenBeforeExoPlayerReportsIt() = runTest {
        // KotlinAudio already reports the item's failure; ExoPlayer's state still reads ready.
        val player = MaskingPlayer { currentTime }.apply { kotlinAudioState = AudioPlayerState.ERROR }
        val failed = runCatching { gate(this).seek(player, 30_000L) }
        assertEquals("standard_seek_unavailable", (failed.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aSeekToTheEndOfTheTrackCompletesWhenItEnds() = runTest {
        val player = MaskingPlayer { currentTime }.apply {
            readyAfterMs = 10_000L
            endsAfterMs = 200L
        }
        val started = currentTime
        gate(this).seek(player, 90_000L)
        assertEquals(200L, currentTime - started)
    }

    @Test
    fun theCapturedExoPlayerIsWhatTheSeekReads() {
        var state = com.google.android.exoplayer2.Player.STATE_BUFFERING
        var playing = false
        var error: Any? = null
        val exoPlayer = java.lang.reflect.Proxy.newProxyInstance(
            javaClass.classLoader, arrayOf(com.google.android.exoplayer2.Player::class.java)
        ) { _, method, _ ->
            when (method.name) {
                "getPlaybackState" -> state
                "isPlaying" -> playing
                "getPlayerError" -> error
                else -> defaultValue(method.returnType)
            }
        } as com.google.android.exoplayer2.Player
        var captured: com.google.android.exoplayer2.Player? = null
        val exo = CapturedExoSeekState { captured }
        // Not built yet: idle, nothing to read.
        assertEquals(com.google.android.exoplayer2.Player.STATE_IDLE, exo.playbackState)
        captured = exoPlayer
        assertEquals(com.google.android.exoplayer2.Player.STATE_BUFFERING, exo.playbackState)
        state = com.google.android.exoplayer2.Player.STATE_READY
        playing = true
        assertEquals(com.google.android.exoplayer2.Player.STATE_READY, exo.playbackState)
        assertTrue(exo.isPlaying)
        assertFalse(exo.hasError)
        error = bare(com.google.android.exoplayer2.PlaybackException::class.java)
        assertTrue(exo.hasError)
    }

    @Test
    fun aStandardRestoreLoadsAndSeeksAsOnIos() {
        fun steps(authoritative: Boolean = true, queueChanged: Boolean = false, current: Int = 1, position: Long = 10_000L, tolerance: Long = 750L) =
            standardRestoreSteps(authoritative, queueChanged, current, targetIndex = 1, positionMs = position, targetPositionMs = 10_000L, positionToleranceMs = tolerance)
        // Same track, close enough: nothing; exactly at the tolerance still counts as restored
        // (iOS: the same `>`).
        assertEquals(StandardRestoreSteps(jump = false, seek = false), steps(position = 10_500L))
        assertEquals(StandardRestoreSteps(jump = false, seek = false), steps(position = 10_750L))
        assertEquals(StandardRestoreSteps(jump = false, seek = true), steps(position = 10_751L))
        // Same track, further off than the setting: seek only.
        assertEquals(StandardRestoreSteps(jump = false, seek = true), steps(position = 10_500L, tolerance = 200L))
        // Another index, a changed queue or a candidate: load the track again and seek.
        assertEquals(StandardRestoreSteps(jump = true, seek = true), steps(current = 0))
        assertEquals(StandardRestoreSteps(jump = true, seek = true), steps(queueChanged = true))
        assertEquals(StandardRestoreSteps(jump = true, seek = true), steps(authoritative = false))
    }

    private fun <T> bare(type: Class<T>): T {
        val unsafe = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        @Suppress("UNCHECKED_CAST")
        return unsafe.javaClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, type) as T
    }

    @Test
    fun aPauseAfterANewerSeekEndsTheNewerSeek() = runTest {
        // The older seek ends (replaced); it must not forget the newer one still waiting.
        val gate = StandardSeekGate(timeoutMs = { 60_000L }, stallTimeoutMs = { 60_000L }, pollIntervalMs = 1_000L, nowMs = { currentTime })
        val item = Any()
        val buffering = { StandardSeekObservation(AudioPlayerState.BUFFERING, 0L, 0L, item = item) }
        val older = async { runCatching { gate.await(30_000L, item, buffering) } }
        runCurrent()
        val newer = async { runCatching { gate.await(40_000L, item, buffering) } }
        runCurrent()
        older.await()
        val at = currentTime
        gate.cancel("pause")
        assertEquals("standard_seek_cancelled", (newer.await().exceptionOrNull() as RejectionException).code)
        assertEquals(0L, currentTime - at)
    }

    @Test
    fun onlyAnAutomaticTransitionIsCounted() {
        val counter = AutoTransitionCounter()
        val eventTime = bare(com.google.android.exoplayer2.analytics.AnalyticsListener.EventTime::class.java)
        val position = bare(com.google.android.exoplayer2.Player.PositionInfo::class.java)
        for (reason in listOf(
            com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_SEEK,
            com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_SEEK_ADJUSTMENT,
            com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_SKIP,
            com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_REMOVE,
            com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_INTERNAL
        )) counter.onPositionDiscontinuity(eventTime, position, position, reason)
        assertEquals(0L, counter.count)
        counter.onPositionDiscontinuity(eventTime, position, position, com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_AUTO_TRANSITION)
        assertEquals(1L, counter.count)
    }

    @Test
    fun aPositionBeforeTheTargetIsNotAtItAndAtTheTargetIsDoneAtOnce() = runTest {
        // Deliberately changed: the sampling period is no tolerance any more (it is stallTimeoutMs
        // / 10 for the app): a position before the target is not at it, even by less than one
        // poll; at the target it is done at once.
        val gate = StandardSeekGate(timeoutMs = { 2_000L }, stallTimeoutMs = { 2_000L }, pollIntervalMs = 100L, nowMs = { currentTime })
        val item = Any()
        val started = currentTime
        gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 20_000L, 25_000L, item = item) }
        assertEquals(0L, currentTime - started)
        val lagging = runCatching {
            gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 19_950L, 25_000L, item = item) }
        }
        assertEquals("standard_seek_timeout", (lagging.exceptionOrNull() as RejectionException).code)
        // More than one poll before it: not there yet.
        val early = runCatching {
            gate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.READY, 19_850L, 25_000L, item = item) }
        }
        assertEquals("standard_seek_timeout", (early.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun aSeekTimeoutSaysWhetherItStalledOrRanOutOfTime() = runTest {
        val item = Any()
        val stalledGate = StandardSeekGate(timeoutMs = { 5_000L }, stallTimeoutMs = { 300L }, pollIntervalMs = 100L, nowMs = { currentTime })
        val stalled = runCatching {
            stalledGate.await(20_000L, item) { StandardSeekObservation(AudioPlayerState.BUFFERING, 0L, 1_000L, item = item) }
        }.exceptionOrNull() as RejectionException
        assertEquals("The native seek made no progress for 300 ms.", stalled.message)
        var buffered = 0L
        val slowGate = StandardSeekGate(timeoutMs = { 500L }, stallTimeoutMs = { 5_000L }, pollIntervalMs = 100L, nowMs = { currentTime })
        val slow = runCatching {
            slowGate.await(20_000L, item) { buffered += 100L; StandardSeekObservation(AudioPlayerState.BUFFERING, 0L, buffered, item = item) }
        }.exceptionOrNull() as RejectionException
        assertEquals("The native seek did not complete within 500 ms.", slow.message)
    }

}

private fun defaultValue(type: Class<*>): Any? = when (type) {
    java.lang.Boolean.TYPE -> false
    java.lang.Integer.TYPE -> 0
    java.lang.Long.TYPE -> 0L
    java.lang.Float.TYPE -> 0f
    java.lang.Double.TYPE -> 0.0
    else -> null
}
