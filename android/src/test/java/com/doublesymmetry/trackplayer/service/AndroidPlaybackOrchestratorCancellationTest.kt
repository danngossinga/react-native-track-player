package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.MediaType
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.module.completePlaybackCommand
import com.doublesymmetry.trackplayer.utils.RejectionException
import com.google.android.exoplayer2.Player
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidPlaybackOrchestratorCancellationTest {
    @Test
    fun pingPongCandidateFinalRebaseSeeksWithoutPreparingTheSameTrackAgain() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            RecordingOrchestratorDelegate(),
            engineA,
            engineB
        )
        val items = testItems(2)
        val queueStore = AndroidTrackQueue().apply { replaceWith(items) }
        val backend = PingPongPlaybackBackend(
            orchestrator,
            Any(),
            queueStore,
            PlaybackTransitionGenerationSidecar(),
            suspendControlSurface = {},
            resumeControlSurface = {},
            activateControlSurface = {},
            onCommitted = {},
            onDisposed = {}
        )
        val preview = PlaybackBackendSnapshot(
            queueIds = items.map { it.track.queueId.toString() },
            activeIndex = 0,
            activeTrackId = items[0].track.queueId.toString(),
            positionMs = 1_000L,
            playWhenReady = true,
            volume = 0.8f,
            rate = 1f,
            repeatMode = 0,
            transitionGeneration = 1L
        )
        try {
            backend.prepareSilently(preview)
            backend.restore(preview)
            assertEquals(1, engineA.prepareCalls)

            val finalSnapshot = preview.copy(positionMs = 4_000L)
            backend.prepareSilently(finalSnapshot)
            backend.restore(finalSnapshot)

            assertEquals(1, engineA.prepareCalls)
            assertEquals(4_000L, engineA.positionMs)
        } finally {
            backend.dispose()
        }
    }

    @Test
    fun aPingPongRestoreSeeksOnlyWhenFurtherOffThanTheAppsTolerance() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, RecordingOrchestratorDelegate(), engineA, engineB)
        var tolerance = 750L
        val items = testItems(2)
        val backend = PingPongPlaybackBackend(
            orchestrator,
            Any(),
            AndroidTrackQueue().apply { replaceWith(items) },
            PlaybackTransitionGenerationSidecar(),
            suspendControlSurface = {},
            resumeControlSurface = {},
            activateControlSurface = {},
            onCommitted = {},
            onDisposed = {},
            positionToleranceMs = { tolerance }
        )
        val snapshot = PlaybackBackendSnapshot(
            queueIds = items.map { it.track.queueId.toString() },
            activeIndex = 0,
            activeTrackId = items[0].track.queueId.toString(),
            positionMs = 10_000L,
            playWhenReady = false,
            volume = 1f,
            rate = 1f,
            repeatMode = 0,
            transitionGeneration = 1L
        )
        try {
            backend.prepareSilently(snapshot)
            backend.restore(snapshot)
            val seeks = engineA.seekCalls
            // 500 ms off, within the setting: no seek (iOS: the same option, same rule).
            backend.restore(snapshot.copy(positionMs = 10_500L))
            assertEquals(seeks, engineA.seekCalls)
            // The app lowers it: the same distance is sought.
            tolerance = 200L
            backend.restore(snapshot.copy(positionMs = 10_500L))
            assertEquals(seeks + 1, engineA.seekCalls)
        } finally {
            backend.dispose()
        }
    }

    @Test
    fun removedActiveTrackPayloadResolvesExplicitPreviousTrackFromOldQueue() {
        val previousTrack = allocateTrack()

        val resolved = resolvePreviousTrackForPlaybackEvent(
            tracks = emptyList(),
            previousIndex = 0,
            explicitPreviousTrack = previousTrack
        )

        assertTrue(resolved === previousTrack)
    }

    @Test
    fun remappingRetainedActiveTrackPublishesItsNewIndexExactlyOnce() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            delegate,
            engineA,
            engineB
        )
        try {
            val original = testItems(2)
            orchestrator.setQueue(original)
            orchestrator.play()
            orchestrator.skip(1)
            orchestrator.seekTo(2_345L)
            delegate.activeTrackChanges.clear()
            delegate.snapshots.clear()

            orchestrator.setQueue(listOf(original[1]))

            assertEquals(
                listOf(
                    ActiveTrackChange(
                        index = 0,
                        previousIndex = 1,
                        oldPositionMs = 2_345L,
                        previousItem = original[1]
                    )
                ),
                delegate.activeTrackChanges
            )
            val snapshot = orchestrator.snapshot()
            assertEquals(0, snapshot.currentIndex)
            assertTrue(snapshot.currentItem === original[1])
            assertEquals(snapshot, delegate.snapshots.last())
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun replacingQueueWithoutStableCurrentIdentityStopsAndClearsActiveTrack() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            delegate,
            engineA,
            engineB
        )
        try {
            val original = testItems(2)
            orchestrator.setQueue(original)
            orchestrator.play()
            orchestrator.seekTo(4_321L)
            delegate.activeTrackChanges.clear()
            delegate.snapshots.clear()

            orchestrator.setQueue(testItems(2))

            val snapshot = orchestrator.snapshot()
            assertEquals(-1, snapshot.currentIndex)
            assertNull(snapshot.currentItem)
            assertFalse(snapshot.playWhenReady)
            assertEquals(AndroidPlaybackOrchestratorState.STOPPED, snapshot.orchestratorState)
            assertEquals(AudioPlayerState.STOPPED, snapshot.playbackState)
            assertEquals(
                listOf(
                    ActiveTrackChange(
                        null,
                        previousIndex = 0,
                        oldPositionMs = 4_321L,
                        previousItem = original[0]
                    )
                ),
                delegate.activeTrackChanges
            )
            assertTrue(delegate.snapshots.isNotEmpty())
            assertEquals(snapshot, delegate.snapshots.last())
            assertFalse(engineA.isPreparedFor(original[0]))
            assertFalse(engineB.isPreparedFor(original[1]))
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun replacingQueueInvalidatesBlockedPreloadAndRejectsItsLatePreparation() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            delegate,
            engineA,
            engineB
        )
        val blockedPreload = PrepareBlock(swallowCancellationUntilReleased = true)
        val blockedMaintenanceRelease = CompletableDeferred<Unit>()
        val blockedMaintenance = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                awaitCancellation()
            } finally {
                withContext(NonCancellable) {
                    blockedMaintenanceRelease.await()
                }
            }
        }
        try {
            val original = testItems(2)
            engineB.blockNextPrepare = blockedPreload
            orchestrator.setQueue(original)
            orchestrator.play()
            runCurrent()
            assertTrue(blockedPreload.entered.isCompleted)
            val oldPreloadJob = requireNotNull(orchestrator.privateField("preloadJob") as? kotlinx.coroutines.Job)
            val replacementNext = testItems(1).single()
            orchestrator.setPrivateField("standbyMaintenanceJob", blockedMaintenance)

            orchestrator.setQueue(listOf(original[0], replacementNext))
            runCurrent()
            val cancellationObserved = blockedPreload.cancellationObserved.isCompleted
            val oldPreloadWasCancelled = oldPreloadJob.isCancelled
            val oldMaintenanceWasCancelled = blockedMaintenance.isCancelled

            blockedPreload.release.complete(Unit)
            runCurrent()
            assertFalse(engineB.isPreparedFor(replacementNext))
            blockedMaintenanceRelease.complete(Unit)
            runCurrent()

            assertTrue(cancellationObserved)
            assertTrue(oldPreloadWasCancelled)
            assertTrue(oldMaintenanceWasCancelled)
            assertFalse(engineB.isPreparedFor(original[1]))
            assertTrue(engineB.isPreparedFor(replacementNext))
            assertEquals(1, orchestrator.privateField("preloadTargetIndex"))
            val snapshot = orchestrator.snapshot()
            assertEquals(0, snapshot.currentIndex)
            assertTrue(snapshot.playWhenReady)
            assertEquals(AndroidPlaybackOrchestratorState.PLAYING_SINGLE, snapshot.orchestratorState)
        } finally {
            blockedPreload.release.complete(Unit)
            blockedMaintenanceRelease.complete(Unit)
            orchestrator.release()
        }
    }

    @Test
    fun settleDuringBlockedSkipRejectsLateCompletionAndLeavesStableSnapshot() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            delegate,
            engineA,
            engineB
        )
        try {
            val items = testItems(2)
            orchestrator.setQueue(items)
            orchestrator.play()
            runCurrent()

            val blockedPrepare = PrepareBlock(swallowCancellationUntilReleased = true)
            engineA.blockNextPrepare = blockedPrepare
            var bridgeResolveCount = 0
            val bridgeFailures = mutableListOf<Exception>()
            val skip = async(start = CoroutineStart.UNDISPATCHED) {
                completePlaybackCommand(
                    operation = { orchestrator.skip(1) },
                    resolve = { bridgeResolveCount += 1 },
                    reject = { bridgeFailures += it }
                )
            }
            blockedPrepare.entered.await()
            val ticket = requireNotNull(engineA.lastPrepareTicket)
            assertEquals(AndroidPlaybackOrchestratorState.LOADING, orchestrator.state)

            orchestrator.settleActiveTransition()
            blockedPrepare.cancellationObserved.await()
            val settled = orchestrator.snapshot()
            assertEquals(1, settled.currentIndex)
            assertEquals(AndroidPlaybackOrchestratorState.STOPPED, settled.orchestratorState)
            assertEquals(AudioPlayerState.STOPPED, settled.playbackState)
            assertFalse(settled.playWhenReady)
            assertEquals(1, ticket.cancellationCount)
            assertEquals(0, bridgeResolveCount)
            assertTrue(bridgeFailures.isEmpty())

            blockedPrepare.release.complete(Unit)
            runCurrent()
            skip.await()
            assertEquals(0, bridgeResolveCount)
            assertEquals(1, bridgeFailures.size)
            assertTrue(bridgeFailures.single() is RejectionException)
            assertEquals("cancelled", (bridgeFailures.single() as RejectionException).code)
            blockedPrepare.release.complete(Unit)
            runCurrent()
            assertEquals(1, bridgeFailures.size)
            assertEquals(1, orchestrator.currentIndex)
            assertEquals(AndroidPlaybackOrchestratorState.STOPPED, orchestrator.state)
            assertFalse(delegate.playbackStates.contains(AudioPlayerState.ERROR))
            assertTrue(delegate.playbackErrors.isEmpty())
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun cancelledCrossfadePrepareNeverPublishesPreparedMarkers() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            delegate,
            engineA,
            engineB
        )
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            orchestrator.skip(1)
            runCurrent()

            val blockedPrepare = PrepareBlock(swallowCancellationUntilReleased = true)
            engineB.blockNextPrepare = blockedPrepare
            supervisorScope {
                val preparation = async(start = CoroutineStart.UNDISPATCHED) {
                    orchestrator.crossFadePrepare(previous = true, seekTo = 3.0)
                }
                blockedPrepare.entered.await()

                // A normal command supersedes the operation ticket. (A play no longer does: as on
                // iOS, a play while playing has nothing to start and cancels nothing, so a seek
                // is the superseding command here.) The late completion below must still not
                // publish the cancelled preparation's markers.
                orchestrator.seekTo(0L)
                runCurrent()
                blockedPrepare.cancellationObserved.await()

                assertNull(orchestrator.privateField("preparedCrossfadeFromIndex"))
                assertNull(orchestrator.privateField("preparedCrossfadeToIndex"))
                assertEquals(0L, orchestrator.privateField("preparedCrossfadeSeekToMs"))

                blockedPrepare.release.complete(Unit)
                runCurrent()
                val error = runCatching { preparation.await() }.exceptionOrNull()
                assertTrue(error is RejectionException)
                assertEquals("cancelled", (error as RejectionException).code)
                assertNull(orchestrator.privateField("preparedCrossfadeFromIndex"))
                assertNull(orchestrator.privateField("preparedCrossfadeToIndex"))
                assertFalse(delegate.playbackStates.contains(AudioPlayerState.ERROR))
                // The cancelled preparation is reported with an event (like iOS), never as prepared.
                assertEquals(
                    listOf(CrossfadeEvent("cancelled", 1, 0, "superseded")),
                    delegate.crossfadeEvents.filter { it.state == "cancelled" || it.state == "prepared" }
                )
            }
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun everyLoadUsesTheLoadTimeoutSetAtThatMoment() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            RecordingOrchestratorDelegate(),
            engineA,
            engineB
        )
        try {
            // The service's setting, read at each load and seek: the first load, the song loaded by
            // a skip, the next one preloaded on the standby engine and a seek use it, and a new
            // value applies to the next one.
            var setting = 9_000L
            var stall = 3_000L
            orchestrator.prepareTimeoutMs = { setting }
            orchestrator.stallTimeoutMs = { stall }
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            assertEquals(9_000L, engineA.lastPrepareTimeoutMs)
            assertEquals(3_000L, engineA.lastPrepareStallTimeoutMs)
            stall = 4_000L

            setting = 12_000L
            val standbyLoads = engineB.prepareCalls
            orchestrator.skip(1)
            runCurrent()
            assertEquals(12_000L, engineA.lastPrepareTimeoutMs)
            assertTrue(engineB.prepareCalls > standbyLoads)
            assertEquals(12_000L, engineB.lastPrepareTimeoutMs)
            assertEquals(4_000L, engineA.lastPrepareStallTimeoutMs)
            assertEquals(4_000L, engineB.lastPrepareStallTimeoutMs)
            stall = 5_000L
            setting = 30_000L
            orchestrator.skip(0)
            runCurrent()
            assertEquals(30_000L, engineA.lastPrepareTimeoutMs)
            setting = 40_000L
            orchestrator.seekTo(20_000L)
            runCurrent()
            assertEquals(40_000L, engineA.lastSeekTimeoutMs)
            assertEquals(5_000L, engineA.lastSeekStallTimeoutMs)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aSlowButProgressingLoadPlaysAfterTheStallTimeoutAndAStalledLoadFailsAtIt() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.prepareTimeoutMs = { 60_000L }
            orchestrator.stallTimeoutMs = { 10_000L }
            // 30 s to load on a slow network, data arriving all along: it plays.
            engineA.simulatedLoad = SimulatedLoad(bytesPerPoll = 512L, readyAfterMs = 30_000L, nowMs = { currentTime })
            orchestrator.setQueue(testItems(3))
            val started = currentTime
            orchestrator.play()
            assertEquals(30_000L, currentTime - started)
            assertTrue(delegate.playbackErrors.isEmpty())
            assertEquals(AudioPlayerState.PLAYING, delegate.playbackStates.last())

            // The next load gets no data at all: it fails at the 10 s stall timeout.
            engineA.simulatedLoad = SimulatedLoad(bytesPerPoll = 0L, readyAfterMs = 30_000L, nowMs = { currentTime })
            val skipped = currentTime
            try {
                orchestrator.skip(2)
                fail("Expected the stalled load to fail")
            } catch (error: RejectionException) {
                assertEquals("crossfade_prepare_timeout", error.code)
            }
            assertEquals(10_000L, currentTime - skipped)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aCrossfadeFallsBackAfterTheIncomingStallGraceTheAppSet() = runTest {
        // The fake engines never move, so the incoming track always stalls: the fallback comes
        // after the grace read at that moment.
        for (grace in listOf(300L, 1_200L)) {
            val engineA = FakeCrossfadeEngine("engineA")
            val engineB = FakeCrossfadeEngine("engineB")
            val delegate = RecordingOrchestratorDelegate()
            val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
            try {
                orchestrator.incomingStallGraceMs = { grace }
                orchestrator.setQueue(testItems(3))
                orchestrator.play()
                runCurrent()
                val started = currentTime
                orchestrator.crossFade(fadeDuration = 5_000.0)
                val elapsed = currentTime - started
                assertEquals("incoming_stalled", delegate.crossfadeEvents.last { it.state == "error" }.errorCode)
                assertTrue("grace=$grace elapsed=$elapsed", elapsed >= grace && elapsed < grace + 100L)
            } finally {
                orchestrator.release()
            }
        }
    }

    @Test
    fun aPlayWaitsForPlaybackToStartWithTheCurrentLimitsAndPausesWhenItStalls() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            var limit = 45_000L
            orchestrator.playStartTimeoutMs = { limit }
            orchestrator.stallTimeoutMs = { 10_000L }
            orchestrator.setQueue(testItems(3))
            // A slow start that keeps loading: playing after 20 s, past the stall timeout.
            engineA.simulatedStart = SimulatedLoad(bytesPerPoll = 256L, readyAfterMs = 20_000L, nowMs = { currentTime })
            val started = currentTime
            orchestrator.play()
            assertEquals(20_000L, currentTime - started)
            assertEquals(45_000L, engineA.lastPlayStartTimeoutMs)
            assertEquals(10_000L, engineA.lastPlayStartStallTimeoutMs)
            assertEquals(AudioPlayerState.PLAYING, delegate.playbackStates.last())

            // A new limit applies to the next play; a start with no data fails at the stall
            // timeout, pauses, and reports the error.
            limit = 30_000L
            orchestrator.pause()
            engineA.simulatedStart = SimulatedLoad(bytesPerPoll = 0L, readyAfterMs = 60_000L, nowMs = { currentTime })
            val stalledAt = currentTime
            try {
                orchestrator.play()
                fail("Expected the play start to fail")
            } catch (error: RejectionException) {
                assertEquals("crossfade_play_start_timeout", error.code)
            }
            assertEquals(10_000L, currentTime - stalledAt)
            assertEquals(30_000L, engineA.lastPlayStartTimeoutMs)
            // The failed start leaves playback paused, not waiting to play by itself.
            assertFalse(orchestrator.playWhenReady)
            assertEquals(AudioPlayerState.PAUSED, delegate.playbackStates.last())
            assertEquals("crossfade_play_start_timeout", delegate.playbackErrors.last().first)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aPlayAfterTheQueueEndedStartsTheLastTrackAgainFromTheStartAsOnIos() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.stallTimeoutMs = { 10_000L }
            orchestrator.setQueue(testItems(1))
            orchestrator.play()
            orchestrator.seekTo(30_000L)
            engineA.ended = true
            engineB.ended = true
            advanceTimeBy(1_000L)
            runCurrent()
            assertEquals(AudioPlayerState.ENDED, delegate.playbackStates.last())

            val started = currentTime
            orchestrator.play()
            assertEquals(0L, currentTime - started)
            assertTrue(delegate.playbackErrors.isEmpty())
            assertEquals(AudioPlayerState.PLAYING, delegate.playbackStates.last())
            assertEquals(0, orchestrator.currentIndex)
            assertEquals(0L, orchestrator.positionMs)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aPauseDuringTheNextTracksStartCancelsItWithNoPlaybackError() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.stallTimeoutMs = { 10_000L }
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            // The track ends; the next one starts on its own and gets no data.
            engineA.simulatedStart = SimulatedLoad(bytesPerPoll = 0L, readyAfterMs = 120_000L, nowMs = { currentTime })
            engineB.simulatedStart = SimulatedLoad(bytesPerPoll = 0L, readyAfterMs = 120_000L, nowMs = { currentTime })
            engineA.ended = true
            advanceTimeBy(1_000L)
            runCurrent()
            assertEquals(1, delegate.activeTrackChanges.last().index)

            // The user pauses during that start: it is cancelled, not given up later.
            orchestrator.pause()
            advanceTimeBy(30_000L)
            runCurrent()
            assertTrue(delegate.playbackErrors.isEmpty())
            assertFalse(orchestrator.playWhenReady)
            assertEquals(AudioPlayerState.PAUSED, delegate.playbackStates.last())
        } finally {
            orchestrator.release()
        }
    }

    private fun kotlinx.coroutines.test.TestScope.ninth(): Triple<AndroidPlaybackOrchestrator, Pair<FakeCrossfadeEngine, FakeCrossfadeEngine>, RecordingOrchestratorDelegate> {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        orchestrator.stallTimeoutMs = { 10_000L }
        return Triple(orchestrator, engineA to engineB, delegate)
    }

    /** What a play changes: the states emitted and the orchestrator's state, before and after. */
    private suspend fun kotlinx.coroutines.test.TestScope.assertPlayChangesNothing(
        orchestrator: AndroidPlaybackOrchestrator,
        delegate: RecordingOrchestratorDelegate
    ) {
        val before = orchestrator.snapshot()
        delegate.playbackStates.clear()
        delegate.crossfadeEvents.clear()
        orchestrator.play()
        runCurrent()
        assertEquals(emptyList<AudioPlayerState>(), delegate.playbackStates)
        assertTrue(delegate.crossfadeEvents.none { it.state == "cancelled" })
        assertEquals(before.orchestratorState, orchestrator.snapshot().orchestratorState)
        assertEquals(before.currentIndex, orchestrator.snapshot().currentIndex)
    }

    @Test
    fun aPlayWhilePlayingChangesNothingAsOnIos() = runTest {
        val (orchestrator, _, delegate) = ninth()
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            assertPlayChangesNothing(orchestrator, delegate)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aPlayWhilePreparingTheNextTrackChangesNothingAsOnIos() = runTest {
        val (orchestrator, engines, delegate) = ninth()
        try {
            val block = PrepareBlock(swallowCancellationUntilReleased = false)
            engines.second.blockNextPrepare = block
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            assertEquals(AndroidPlaybackOrchestratorState.PRELOADING_NEXT, orchestrator.snapshot().orchestratorState)
            assertPlayChangesNothing(orchestrator, delegate)
            block.release.complete(Unit)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aPlayDuringACrossfadeChangesNothingAsOnIos() = runTest {
        val (orchestrator, _, delegate) = ninth()
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            val fade = async { runCatching { orchestrator.crossFade(fadeDuration = 5_000.0) } }
            advanceTimeBy(1_000L)
            runCurrent()
            assertEquals(AndroidPlaybackOrchestratorState.CROSSFADING, orchestrator.snapshot().orchestratorState)
            assertPlayChangesNothing(orchestrator, delegate)
            advanceTimeBy(10_000L)
            assertTrue(fade.await().isSuccess)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aPlayWhileSeekingOrSkippingChangesNothingAsOnIos() = runTest {
        val (orchestrator, engines, delegate) = ninth()
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            // A seek that is loading (the engine waits for data).
            val seekData = CompletableDeferred<Unit>()
            engines.first.blockNextSeek = seekData
            val seek = async { runCatching { orchestrator.seekTo(20_000L) } }
            runCurrent()
            assertEquals(AndroidPlaybackOrchestratorState.SEEKING, orchestrator.snapshot().orchestratorState)
            assertPlayChangesNothing(orchestrator, delegate)
            seekData.complete(Unit)
            assertTrue(seek.await().isSuccess)
            // SKIPPING (iOS's skipping; the Android orchestrator maps it but no path sets it today).
            orchestrator.setPrivateField("state", AndroidPlaybackOrchestratorState.SKIPPING)
            assertPlayChangesNothing(orchestrator, delegate)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aCrossfadePrepareDuringAPlayStartIsRefusedWithoutCancellingIt() = runTest {
        val (orchestrator, engines, delegate) = ninth()
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            orchestrator.pause()
            delegate.playbackStates.clear()
            engines.first.simulatedStart = SimulatedLoad(bytesPerPoll = 256L, readyAfterMs = 5_000L, nowMs = { currentTime })
            val started = async { orchestrator.play() }
            advanceTimeBy(1_000L)
            runCurrent()
            val refused = runCatching { orchestrator.crossFadePrepare() }
            assertEquals("crossfade_not_playing", (refused.exceptionOrNull() as RejectionException).code)
            started.await()
            assertEquals(listOf(AudioPlayerState.LOADING, AudioPlayerState.PLAYING), delegate.playbackStates)
            assertTrue(orchestrator.snapshot().playWhenReady)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aStartCancelledByAnotherCommandLeavesThePlayerPausedAsOnIos() = runTest {
        val (orchestrator, engines, delegate) = ninth()
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            orchestrator.pause()
            // A seek during the start (iOS: the start is dropped; the seek ends paused).
            delegate.playbackStates.clear()
            engines.first.simulatedStart = SimulatedLoad(bytesPerPoll = 256L, readyAfterMs = 5_000L, nowMs = { currentTime })
            val started = async { runCatching { orchestrator.play() } }
            advanceTimeBy(1_000L)
            runCurrent()
            orchestrator.seekTo(10_000L)
            assertEquals("cancelled", (started.await().exceptionOrNull() as RejectionException).code)
            assertEquals(listOf(AudioPlayerState.LOADING, AudioPlayerState.PAUSED), delegate.playbackStates.take(2))
            assertEquals(AudioPlayerState.PAUSED, orchestrator.snapshot().playbackState)
            assertFalse(orchestrator.snapshot().playWhenReady)

            // A backend switch during the start (settle): paused, nothing left loading.
            delegate.playbackStates.clear()
            engines.first.simulatedStart = SimulatedLoad(bytesPerPoll = 256L, readyAfterMs = 5_000L, nowMs = { currentTime })
            val again = async { runCatching { orchestrator.play() } }
            advanceTimeBy(1_000L)
            runCurrent()
            orchestrator.settleActiveTransition()
            again.await()
            // As iOS (the cancelled start is stabilized at once): paused, then the switch's own
            // stop; never left loading with playWhenReady on.
            assertEquals(listOf(AudioPlayerState.LOADING, AudioPlayerState.PAUSED, AudioPlayerState.STOPPED), delegate.playbackStates)
            assertFalse(orchestrator.snapshot().playWhenReady)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aSkipDuringAStartPlaysTheNewTrackAsOnIos() = runTest {
        val (orchestrator, engines, delegate) = ninth()
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            orchestrator.pause()
            delegate.playbackStates.clear()
            engines.first.simulatedStart = SimulatedLoad(bytesPerPoll = 256L, readyAfterMs = 5_000L, nowMs = { currentTime })
            val started = async { runCatching { orchestrator.play() } }
            advanceTimeBy(1_000L)
            runCurrent()
            orchestrator.skip(1)
            started.await()
            // As iOS: a transient paused (the start dropped), then the new track loads and plays.
            assertEquals(
                listOf(AudioPlayerState.LOADING, AudioPlayerState.PAUSED, AudioPlayerState.LOADING, AudioPlayerState.PLAYING),
                delegate.playbackStates
            )
            assertTrue(orchestrator.snapshot().playWhenReady)
            assertEquals(1, orchestrator.snapshot().currentIndex)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aPlayFromPausedIsLoadingUntilItStartsAsOnIos() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.stallTimeoutMs = { 10_000L }
            orchestrator.setQueue(testItems(2))
            orchestrator.play()
            orchestrator.pause()
            delegate.playbackStates.clear()
            // Still prepared; this start takes 5 s, data arriving.
            engineA.simulatedStart = SimulatedLoad(bytesPerPoll = 256L, readyAfterMs = 5_000L, nowMs = { currentTime })
            val started = async { orchestrator.play() }
            advanceTimeBy(1_000L)
            runCurrent()
            assertEquals(listOf(AudioPlayerState.LOADING), delegate.playbackStates)
            assertEquals(AudioPlayerState.LOADING, orchestrator.snapshot().playbackState)
            assertTrue(orchestrator.snapshot().playWhenReady)
            started.await()
            assertEquals(listOf(AudioPlayerState.LOADING, AudioPlayerState.PLAYING), delegate.playbackStates)
            assertEquals(AudioPlayerState.PLAYING, orchestrator.snapshot().playbackState)

            // A pause during the start: loading, then paused (the start is cancelled).
            orchestrator.pause()
            delegate.playbackStates.clear()
            engineA.simulatedStart = SimulatedLoad(bytesPerPoll = 256L, readyAfterMs = 5_000L, nowMs = { currentTime })
            val cancelled = async { runCatching { orchestrator.play() } }
            advanceTimeBy(1_000L)
            runCurrent()
            orchestrator.pause()
            cancelled.await()
            assertEquals(listOf(AudioPlayerState.LOADING, AudioPlayerState.PAUSED), delegate.playbackStates)
            assertEquals(AudioPlayerState.PAUSED, orchestrator.snapshot().playbackState)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aFailedFirstPlayStartLeavesThePlayerPaused() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.stallTimeoutMs = { 1_000L }
            orchestrator.setQueue(testItems(2))
            engineA.simulatedStart = SimulatedLoad(bytesPerPoll = 0L, readyAfterMs = 60_000L, nowMs = { currentTime })
            runCatching { orchestrator.play() }
            assertEquals(AndroidPlaybackOrchestratorState.PAUSED, orchestrator.snapshot().orchestratorState)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aPreparedCrossfadeThatFailsToStartLeavesNothingPreparedAndTheIncomingTrackSilent() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.stallTimeoutMs = { 1_000L }
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            orchestrator.crossFadePrepare(previous = false, seekTo = 5.0)
            assertEquals(1, orchestrator.privateField("preparedCrossfadeToIndex"))
            engineB.simulatedStart = SimulatedLoad(bytesPerPoll = 0L, readyAfterMs = 60_000L, nowMs = { currentTime })
            val failed = runCatching { orchestrator.crossFade(fadeDuration = 1_000.0) }
            assertEquals("crossfade_start_failed", (failed.exceptionOrNull() as RejectionException).code)
            assertNull(orchestrator.privateField("preparedCrossfadeFromIndex"))
            assertNull(orchestrator.privateField("preparedCrossfadeToIndex"))
            assertEquals(0L, orchestrator.privateField("preparedCrossfadeSeekToMs"))
            assertEquals(0f, engineB.currentVolume)
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aCrossfadeStartsOnceTheIncomingTrackPlaysAndKeepsTheOutgoingOneWhenItStalls() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.playStartTimeoutMs = { 40_000L }
            orchestrator.stallTimeoutMs = { 10_000L }
            orchestrator.incomingStallGraceMs = { 60_000L }
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            // The incoming track gets no data: the fade does not start; the outgoing track plays on.
            engineB.simulatedStart = SimulatedLoad(bytesPerPoll = 0L, readyAfterMs = 60_000L, nowMs = { currentTime })
            val started = currentTime
            try {
                orchestrator.crossFade(fadeDuration = 1_000.0)
                fail("Expected the crossfade start to fail")
            } catch (error: RejectionException) {
                assertEquals("crossfade_start_failed", error.code)
            }
            assertEquals(10_000L, currentTime - started)
            assertEquals(40_000L, engineB.lastPlayStartTimeoutMs)
            assertEquals("crossfade_start_failed", delegate.crossfadeEvents.last().errorCode)
            assertTrue(delegate.crossfadeEvents.none { it.state == "started" })
            assertEquals(0, orchestrator.currentIndex)
            assertEquals(AudioPlayerState.PLAYING, delegate.playbackStates.last())
            // No fade is left running or prepared.
            listOf("activeCrossfadeFromIndex", "activeCrossfadeToIndex", "preparedCrossfadeFromIndex", "preparedCrossfadeToIndex")
                .forEach { assertNull(it, orchestrator.privateField(it)) }
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun aStalledSeekLeavesThePlayerInErrorAsOnIos() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(backgroundScope, delegate, engineA, engineB)
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()
            engineA.failNextSeek = RejectionException("engineA did not finish seeking.", "crossfade_seek_timeout")
            try {
                orchestrator.seekTo(30_000L)
                fail("Expected the seek to fail")
            } catch (error: RejectionException) {
                assertEquals("crossfade_seek_timeout", error.code)
            }
            // Not stuck in seeking (JS would see loading): the player reports an error.
            assertEquals(AudioPlayerState.ERROR, delegate.playbackStates.last())
        } finally {
            orchestrator.release()
        }
    }

    @Test
    fun secondCrossfadeRejectsWithoutCancellingFirstAndPauseEmitsOneTerminalEvent() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            delegate,
            engineA,
            engineB
        )
        try {
            orchestrator.setQueue(testItems(2))
            orchestrator.play()
            runCurrent()

            supervisorScope {
                val first = async(start = CoroutineStart.UNDISPATCHED) {
                    orchestrator.crossFade(waitUntil = 30_000.0)
                }
                assertEquals(1, delegate.crossfadeEvents.count { it.state == "scheduled" })

                // A second call whose start is still ahead is refused. (One with its start already
                // reached starts the armed fade instead: see manualNextStartsTheArmedCrossfadeImmediately.)
                val secondError = runCatching {
                    orchestrator.crossFade(waitUntil = 40_000.0)
                }.exceptionOrNull()
                assertTrue(secondError is RejectionException)
                assertEquals("crossfade_in_progress", (secondError as RejectionException).code)
                assertTrue(first.isActive)
                assertEquals(0, delegate.crossfadeEvents.count { it.state == "cancelled" })

                orchestrator.pause()
                runCurrent()
                val firstError = runCatching { first.await() }.exceptionOrNull()
                assertTrue(firstError is RejectionException)
                assertEquals("cancelled", (firstError as RejectionException).code)
            }

            assertEquals(1, delegate.crossfadeEvents.count { it.state == "cancelled" })
            assertEquals(AndroidPlaybackOrchestratorState.PAUSED, orchestrator.state)
            assertFalse(delegate.playbackStates.contains(AudioPlayerState.ERROR))
            assertTrue(delegate.playbackErrors.isEmpty())
        } finally {
            orchestrator.release()
        }
    }

    // Bug seen in the Djeeloo app (Android): after a completed crossfade, the player schedules a
    // "standby maintenance" for later in the song. The JS player arms the next crossfade right away,
    // which changes the crossfade run id. When the maintenance woke up it threw "Crossfade was
    // cancelled." outside any caller, and the app crashed. It must now step aside quietly.
    @Test
    fun standbyMaintenanceStepsAsideWhenTheNextCrossfadeIsAlreadyScheduled() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        // The app runs the orchestrator in MainScope, where an exception thrown by a background
        // job crashes the process. Record such exceptions here so the test fails on them explicitly.
        val uncaught = mutableListOf<Throwable>()
        val scope = CoroutineScope(
            backgroundScope.coroutineContext + SupervisorJob(backgroundScope.coroutineContext[Job]) +
                CoroutineExceptionHandler { _, error -> uncaught += error }
        )
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            scope,
            delegate,
            engineA,
            engineB
        )
        try {
            orchestrator.setQueue(testItems(3))
            orchestrator.play()
            runCurrent()

            // First crossfade (0 -> 1) runs to the end: the maintenance is scheduled for later.
            orchestrator.crossFade(fadeDuration = 1_000.0)
            assertEquals(1, delegate.crossfadeEvents.count { it.state == "completed" })
            assertTrue(orchestrator.privateField("standbyMaintenanceJob") != null)

            supervisorScope {
                // The next crossfade (1 -> 2) is armed right away and waits for the end of the song.
                val next = async(start = CoroutineStart.UNDISPATCHED) {
                    orchestrator.crossFade(fadeDuration = 1_000.0, waitUntil = 59_000.0)
                }
                assertEquals(2, delegate.crossfadeEvents.count { it.state == "scheduled" })

                // Let the maintenance wake up (it waits about 50 s here): it must not throw.
                testScheduler.advanceTimeBy(55_000)
                runCurrent()
                assertTrue(next.isActive)

                orchestrator.pause()
                runCurrent()
                runCatching { next.await() }
            }
            assertTrue(delegate.playbackErrors.isEmpty())
            assertTrue("background job threw: $uncaught", uncaught.isEmpty())
        } finally {
            orchestrator.release()
        }
    }

    // Manual "next" while the automatic fade is armed and waiting for the end of the song: JS
    // calls crossFade again with waitUntil already reached. Android used to refuse it
    // (crossfade_in_progress) so "next" did nothing until the planned start; it must now start
    // the armed fade right away, as iOS does.
    @Test
    fun manualNextStartsTheArmedCrossfadeImmediately() = runTest {
        val engineA = FakeCrossfadeEngine("engineA")
        val engineB = FakeCrossfadeEngine("engineB")
        val delegate = RecordingOrchestratorDelegate()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(
            backgroundScope,
            delegate,
            engineA,
            engineB
        )
        try {
            orchestrator.setQueue(testItems(2))
            orchestrator.play()
            runCurrent()

            supervisorScope {
                val armed = async(start = CoroutineStart.UNDISPATCHED) {
                    orchestrator.crossFade(fadeDuration = 1_000.0, waitUntil = 50_000.0)
                }
                assertEquals(1, delegate.crossfadeEvents.count { it.state == "scheduled" })
                val startedAt = testScheduler.currentTime

                // The forced start resolves at once and does not report an error.
                orchestrator.crossFade(fadeDuration = 1_000.0, waitUntil = 0.0)
                armed.await()

                assertTrue(delegate.crossfadeEvents.none { it.errorCode == "crossfade_in_progress" })
                assertEquals(1, delegate.crossfadeEvents.count { it.state == "started" })
                assertEquals(1, delegate.crossfadeEvents.count { it.state == "completed" })
                // Started right away, not after the 50 s wait.
                assertTrue(testScheduler.currentTime - startedAt < 5_000)
            }
        } finally {
            orchestrator.release()
        }
    }

    private data class CrossfadeEvent(
        val state: String,
        val fromIndex: Int,
        val toIndex: Int,
        val errorCode: String?
    )

    private data class ActiveTrackChange(
        val index: Int?,
        val previousIndex: Int?,
        val oldPositionMs: Long,
        val previousItem: TrackAudioItem? = null
    )

    private class RecordingOrchestratorDelegate : AndroidPlaybackOrchestratorDelegate {
        val playbackStates = mutableListOf<AudioPlayerState>()
        val playbackErrors = mutableListOf<Pair<String, String?>>()
        val crossfadeEvents = mutableListOf<CrossfadeEvent>()
        val activeTrackChanges = mutableListOf<ActiveTrackChange>()
        val snapshots = mutableListOf<AndroidPlaybackSnapshot>()

        override fun onPlaybackStateChanged(state: AudioPlayerState) {
            playbackStates += state
        }

        override fun onActiveTrackChanged(
            index: Int?,
            previousIndex: Int?,
            oldPositionMs: Long,
            previousItem: TrackAudioItem?
        ) {
            activeTrackChanges += ActiveTrackChange(index, previousIndex, oldPositionMs, previousItem)
        }
        override fun onQueueEnded(index: Int, positionMs: Long) = Unit

        override fun onCrossfadeState(
            state: String,
            fromIndex: Int,
            toIndex: Int,
            elapsedMs: Int?,
            fromVolume: Float?,
            toVolume: Float?,
            errorCode: String?
        ) {
            crossfadeEvents += CrossfadeEvent(state, fromIndex, toIndex, errorCode)
        }

        override fun onNowPlayingChanged(index: Int) = Unit

        override fun onPlaybackError(code: String, message: String?) {
            playbackErrors += code to message
        }

        override fun onSnapshotChanged(snapshot: AndroidPlaybackSnapshot) {
            snapshots += snapshot
        }
    }

    private class PrepareBlock(
        val swallowCancellationUntilReleased: Boolean
    ) {
        val entered = CompletableDeferred<Unit>()
        val cancellationObserved = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
    }

    private class SimulatedLoad(val bytesPerPoll: Long, val readyAfterMs: Long, val nowMs: () -> Long)

    private class FakeCrossfadeEngine(
        override val name: String
    ) : AndroidCrossfadeEnginePort {
        private var preparedItem: TrackAudioItem? = null
        private var ready = false
        private var position = 0L
        private var volume = 0f

        var blockNextPrepare: PrepareBlock? = null
        var prepareCalls = 0
            private set
        var lastPrepareTicket: PlaybackOperationTicket? = null
            private set
        var lastPrepareTimeoutMs: Long? = null
            private set
        var lastSeekTimeoutMs: Long? = null
            private set
        var lastPrepareStallTimeoutMs: Long? = null
            private set
        var lastSeekStallTimeoutMs: Long? = null
            private set
        /**
         * When set, the next load downloads like a network does: [SimulatedLoad.bytesPerPoll]
         * every 25 ms (0: stalled) until [SimulatedLoad.readyAfterMs], judged by the same wait as
         * the real engine with the limits the orchestrator passed.
         */
        var simulatedLoad: SimulatedLoad? = null
        /** When set, the next play start behaves like [simulatedLoad] (time to start, data rate). */
        var simulatedStart: SimulatedLoad? = null
        var lastPlayStartTimeoutMs: Long? = null
            private set
        var lastPlayStartStallTimeoutMs: Long? = null
            private set
        /** When set, the next seek fails with it (a stalled seek). */
        var failNextSeek: RejectionException? = null

        override val positionMs: Long
            get() = position
        override val durationMs: Long
            get() = preparedItem?.duration ?: 60_000L
        override val bufferedMs: Long
            get() = if (ready) durationMs else position
        override val isReady: Boolean
            get() = ready
        /** The loaded track played to its end (until the next reset). */
        var ended = false
        override val playbackState: Int
            get() = if (ended) Player.STATE_ENDED else if (ready) Player.STATE_READY else Player.STATE_IDLE
        override val currentVolume: Float
            get() = volume
        override val playerErrorMessage: String? = null

        override fun isPreparedFor(item: TrackAudioItem): Boolean = preparedItem === item

        override suspend fun prepare(
            item: TrackAudioItem,
            positionMs: Long,
            timeoutMs: Long,
            stallTimeoutMs: Long,
            ticket: PlaybackOperationTicket?
        ) {
            prepareCalls += 1
            lastPrepareTicket = ticket
            lastPrepareTimeoutMs = timeoutMs
            lastPrepareStallTimeoutMs = stallTimeoutMs
            simulatedLoad?.let { load ->
                simulatedLoad = null
                var bytes = 0L
                var elapsed = 0L
                val verdict = awaitWhileProgressing(
                    stallTimeoutMs = stallTimeoutMs,
                    totalTimeoutMs = timeoutMs,
                    pollIntervalMs = ENGINE_WAIT_POLL_INTERVAL_MS,
                    nowMs = load.nowMs,
                    pause = { if (ticket == null) delay(it) else ticket.delayOrThrow(it); elapsed += it },
                    readings = { bytes += load.bytesPerPoll; longArrayOf(bytes) }
                ) { elapsed >= load.readyAfterMs }
                if (verdict != null) {
                    throw RejectionException("$name did not become ready.", "crossfade_prepare_timeout")
                }
            }
            val block = blockNextPrepare.also { blockNextPrepare = null }
            if (block != null) {
                block.entered.complete(Unit)
                try {
                    if (ticket == null) {
                        block.release.await()
                    } else {
                        ticket.delayOrThrow(timeoutMs)
                    }
                } catch (error: PlaybackOperationCancelledException) {
                    block.cancellationObserved.complete(Unit)
                    if (!block.swallowCancellationUntilReleased) throw error
                    block.release.await()
                } catch (error: CancellationException) {
                    block.cancellationObserved.complete(Unit)
                    if (!block.swallowCancellationUntilReleased) throw error
                    withContext(NonCancellable) {
                        block.release.await()
                    }
                }
            }
            preparedItem = item
            position = positionMs
            ready = true
        }

        override fun play(rate: Float) = Unit

        override suspend fun awaitPlaying(timeoutMs: Long, stallTimeoutMs: Long, ticket: PlaybackOperationTicket?) {
            lastPlayStartTimeoutMs = timeoutMs
            lastPlayStartStallTimeoutMs = stallTimeoutMs
            // An ended player does not start again by itself (as ExoPlayer at STATE_ENDED).
            if (ended) {
                if (ticket == null) delay(stallTimeoutMs) else ticket.delayOrThrow(stallTimeoutMs)
                throw RejectionException("$name did not start playing.", "crossfade_play_start_timeout")
            }
            val start = simulatedStart?.also { simulatedStart = null } ?: return
            var bytes = 0L
            var elapsed = 0L
            val verdict = awaitWhileProgressing(
                stallTimeoutMs = stallTimeoutMs,
                totalTimeoutMs = timeoutMs,
                pollIntervalMs = ENGINE_WAIT_POLL_INTERVAL_MS,
                nowMs = start.nowMs,
                pause = { if (ticket == null) delay(it) else ticket.delayOrThrow(it); elapsed += it },
                readings = { bytes += start.bytesPerPoll; longArrayOf(bytes) }
            ) { elapsed >= start.readyAfterMs }
            if (verdict != null) throw RejectionException("$name did not start playing.", "crossfade_play_start_timeout")
        }

        override fun pause() = Unit

        override fun reset() {
            ended = false
            preparedItem = null
            ready = false
            position = 0L
            volume = 0f
        }

        override fun release() {
            reset()
        }

        var seekCalls = 0
            private set

        /** When set, the next seek waits for it (data not there yet). */
        var blockNextSeek: CompletableDeferred<Unit>? = null

        override suspend fun seekTo(
            positionMs: Long,
            timeoutMs: Long,
            stallTimeoutMs: Long,
            ticket: PlaybackOperationTicket?
        ) {
            seekCalls += 1
            blockNextSeek?.let { blockNextSeek = null; it.await() }
            ticket?.ensureActive()
            failNextSeek?.let { failNextSeek = null; throw it }
            lastSeekTimeoutMs = timeoutMs
            lastSeekStallTimeoutMs = stallTimeoutMs
            position = positionMs
        }

        override fun setVolume(value: Float) {
            volume = value
        }

        override fun setRate(value: Float) = Unit
    }

    private fun testItems(count: Int): List<TrackAudioItem> = (0 until count).map { index ->
        TrackAudioItem(
            track = allocateTrack(),
            type = MediaType.DEFAULT,
            audioUrl = "https://example.invalid/$index.mp3",
            title = "Track $index",
            duration = 60_000L
        )
    }

    private fun allocateTrack(): Track {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe")
        field.isAccessible = true
        val unsafe = field.get(null)
        return unsafeClass
            .getMethod("allocateInstance", Class::class.java)
            .invoke(unsafe, Track::class.java) as Track
    }

    private fun AndroidPlaybackOrchestrator.privateField(name: String): Any? {
        val field = AndroidPlaybackOrchestrator::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.get(this)
    }

    private fun AndroidPlaybackOrchestrator.setPrivateField(name: String, value: Any?) {
        val field = AndroidPlaybackOrchestrator::class.java.getDeclaredField(name)
        field.isAccessible = true
        field.set(this, value)
    }
}
