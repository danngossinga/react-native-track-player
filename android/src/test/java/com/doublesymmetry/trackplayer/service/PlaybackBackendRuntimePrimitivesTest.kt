package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.trackplayer.utils.RejectionException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
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
            StandardPlaybackReadinessObservation(AudioPlayerState.LOADING, 1, 0L),
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 1, 12_345L)
        )
        var readCount = 0
        val gate = StandardPlaybackReadinessGate(timeoutMs = 100L, pollIntervalMs = 1L)

        gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
            observations[minOf(readCount++, observations.lastIndex)]
        }

        assertEquals(2, readCount)
    }

    @Test
    fun standardReadinessRequiresReadyIndexAndRestoredPosition() = runTest {
        val observations = listOf(
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 0, 12_345L),
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 1, 13_096L),
            StandardPlaybackReadinessObservation(AudioPlayerState.READY, 1, 13_095L)
        )
        var readCount = 0
        val gate = StandardPlaybackReadinessGate(
            timeoutMs = 100L,
            pollIntervalMs = 1L,
            positionToleranceMs = 750L
        )

        gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
            observations[minOf(readCount++, observations.lastIndex)]
        }

        assertEquals(3, readCount)
    }

    @Test
    fun standardReadinessAcceptsPausedAndPlayingAfterRestore() = runTest {
        for (state in listOf(AudioPlayerState.PAUSED, AudioPlayerState.PLAYING)) {
            val gate = StandardPlaybackReadinessGate(timeoutMs = 5L, pollIntervalMs = 1L)

            gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
                StandardPlaybackReadinessObservation(state, 1, 12_345L)
            }
        }
    }

    @Test
    fun standardReadinessRejectsPlayerError() = runTest {
        val gate = StandardPlaybackReadinessGate(timeoutMs = 100L, pollIntervalMs = 1L)

        try {
            gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
                StandardPlaybackReadinessObservation(AudioPlayerState.ERROR, 1, 12_345L)
            }
            fail("expected readiness failure")
        } catch (error: RejectionException) {
            assertEquals("playback_backend_activation_not_ready", error.code)
        }
    }

    @Test
    fun standardReadinessRejectsLoadingAndBufferingUntilBoundedTimeout() = runTest {
        for (state in listOf(AudioPlayerState.LOADING, AudioPlayerState.BUFFERING)) {
            val gate = StandardPlaybackReadinessGate(timeoutMs = 5L, pollIntervalMs = 1L)

            try {
                gate.await(expectedIndex = 1, expectedPositionMs = 12_345L) {
                    StandardPlaybackReadinessObservation(state, 1, 12_345L)
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
}
