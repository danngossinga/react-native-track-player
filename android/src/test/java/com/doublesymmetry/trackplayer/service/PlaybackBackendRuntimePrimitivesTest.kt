package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.trackplayer.utils.RejectionException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
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
            positionToleranceMs = 750L,
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
}
