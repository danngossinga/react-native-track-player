package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.trackplayer.utils.RejectionException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackBackendRuntimePrimitivesTest {
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
