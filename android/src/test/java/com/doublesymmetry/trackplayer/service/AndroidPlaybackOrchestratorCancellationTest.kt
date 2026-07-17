package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.MediaType
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.module.completePlaybackCommand
import com.doublesymmetry.trackplayer.utils.RejectionException
import com.google.android.exoplayer2.Player
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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

                // A normal command supersedes the operation ticket but does not call
                // cancelCrossfade(), so stale prepared markers cannot be hidden by cleanup.
                orchestrator.play()
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
            }
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

                val secondError = runCatching {
                    orchestrator.crossFade()
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

        override val positionMs: Long
            get() = position
        override val durationMs: Long
            get() = preparedItem?.duration ?: 60_000L
        override val bufferedMs: Long
            get() = if (ready) durationMs else position
        override val isReady: Boolean
            get() = ready
        override val playbackState: Int
            get() = if (ready) Player.STATE_READY else Player.STATE_IDLE
        override val currentVolume: Float
            get() = volume
        override val playerErrorMessage: String? = null

        override fun isPreparedFor(item: TrackAudioItem): Boolean = preparedItem === item

        override suspend fun prepare(
            item: TrackAudioItem,
            positionMs: Long,
            timeoutMs: Long,
            ticket: PlaybackOperationTicket?
        ) {
            prepareCalls += 1
            lastPrepareTicket = ticket
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
        override fun pause() = Unit

        override fun reset() {
            preparedItem = null
            ready = false
            position = 0L
            volume = 0f
        }

        override fun release() {
            reset()
        }

        override suspend fun seekTo(
            positionMs: Long,
            timeoutMs: Long,
            ticket: PlaybackOperationTicket?
        ) {
            ticket?.ensureActive()
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
