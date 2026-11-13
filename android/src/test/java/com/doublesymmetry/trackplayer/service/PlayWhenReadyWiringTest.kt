package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.MediaType
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.google.android.exoplayer2.Player
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The PingPong backend's playWhenReady events, driven through the real orchestrator with a
 * delegate that mirrors MusicService's wiring: `playback-state` from onPlaybackStateChanged, then
 * `playback-play-when-ready-changed` from onSnapshotChanged (sent on every state change, so a flip
 * is never lost), forced on each backend activation. JS's value must always equal the native one.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PlayWhenReadyWiringTest {

    private class ServiceWiring : AndroidPlaybackOrchestratorDelegate {
        lateinit var orchestrator: AndroidPlaybackOrchestrator
        var admitted = false
        private val publication = PlayWhenReadyPublication()
        val events = mutableListOf<String>()
        /** What JS's usePlayWhenReady holds: the last value sent. */
        var jsPlayWhenReady: Boolean? = null

        private fun publish(force: Boolean) {
            val value = orchestrator.playWhenReady
            if (!publication.shouldPublish(value, force)) return
            events += "pwr:$value"
            jsPlayWhenReady = value
        }

        // MusicService: onPlaybackStateChanged
        override fun onPlaybackStateChanged(state: AudioPlayerState) {
            if (!admitted) return
            events += "state:$state"
        }

        // MusicService: publishInitialSurface / admitAndPublishSurface
        fun activate() {
            admitted = true
            events += "state:${orchestrator.playbackState}"
            publish(force = true)
        }

        fun suspendAdmission() { admitted = false }

        override fun onActiveTrackChanged(index: Int?, previousIndex: Int?, oldPositionMs: Long, previousItem: TrackAudioItem?) = Unit
        override fun onQueueEnded(index: Int, positionMs: Long) { if (admitted) events += "queue-ended" }
        override fun onCrossfadeState(state: String, fromIndex: Int, toIndex: Int, elapsedMs: Int?, fromVolume: Float?, toVolume: Float?, errorCode: String?) = Unit
        override fun onNowPlayingChanged(index: Int) = Unit
        override fun onPlaybackError(code: String, message: String?) = Unit
        // MusicService: onSnapshotChanged
        override fun onSnapshotChanged(snapshot: AndroidPlaybackSnapshot) {
            if (!admitted) return
            publish(force = false)
        }
    }

    /** Mirrors AndroidCrossfadeEngine: the track key is set before the wait for READY. */
    private class Engine(override val name: String) : AndroidCrossfadeEnginePort {
        private var preparedItem: TrackAudioItem? = null
        var state = Player.STATE_IDLE
        var gate: CompletableDeferred<Unit>? = null
        private var position = 0L
        private var volume = 0f
        override val positionMs get() = position
        override val durationMs get() = preparedItem?.duration ?: 0L
        override val bufferedMs get() = position
        override val isReady get() = state == Player.STATE_READY
        override val playbackState get() = state
        override val currentVolume get() = volume
        override val playerErrorMessage: String? = null
        override fun isPreparedFor(item: TrackAudioItem) = preparedItem === item
        override suspend fun prepare(item: TrackAudioItem, positionMs: Long, timeoutMs: Long, ticket: PlaybackOperationTicket?) {
            ticket?.ensureActive()
            preparedItem = item
            position = positionMs
            state = Player.STATE_BUFFERING
            val g = gate
            if (g != null) {
                while (!g.isCompleted) {
                    if (ticket == null) kotlinx.coroutines.delay(25) else ticket.delayOrThrow(25)
                }
            }
            ticket?.ensureActive()
            state = Player.STATE_READY
        }
        override fun play(rate: Float) = Unit
        override fun pause() = Unit
        override fun reset() { preparedItem = null; state = Player.STATE_IDLE; position = 0L; volume = 0f }
        override fun release() = reset()
        override suspend fun seekTo(positionMs: Long, timeoutMs: Long, ticket: PlaybackOperationTicket?) { ticket?.ensureActive(); position = positionMs }
        override fun setVolume(value: Float) { volume = value }
        override fun setRate(value: Float) = Unit
    }

    private fun items(count: Int) = (0 until count).map { index ->
        TrackAudioItem(track = allocateTrack(), type = MediaType.DEFAULT, audioUrl = "https://example.invalid/$index.mp3", title = "Track $index", duration = 60_000L)
    }

    private fun allocateTrack(): Track {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe")
        field.isAccessible = true
        return unsafeClass.getMethod("allocateInstance", Class::class.java).invoke(field.get(null), Track::class.java) as Track
    }

    private class Rig(scope: kotlinx.coroutines.CoroutineScope) {
        val a = Engine("engineA")
        val b = Engine("engineB")
        val wiring = ServiceWiring()
        val orchestrator = AndroidPlaybackOrchestrator.forTesting(scope, wiring, a, b).also { wiring.orchestrator = it }
        fun check(label: String) {
            assertEquals("$label: JS playWhenReady must equal native", orchestrator.playWhenReady, wiring.jsPlayWhenReady)
        }
    }

    @Test
    fun mainPath_playPauseStopEachPublishOnce() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.wiring.activate()
            rig.orchestrator.setQueue(items(2))
            rig.orchestrator.play(); rig.check("play")
            rig.orchestrator.pause(); rig.check("pause")
            rig.orchestrator.play(); rig.check("play again")
            rig.orchestrator.seekTo(5_000L); rig.check("seek while playing")
            rig.orchestrator.skip(1); rig.check("skip while playing")
            rig.orchestrator.stop(); rig.check("stop")
            rig.orchestrator.play(); rig.check("play after stop")
            assertEquals(
                listOf("pwr:false", "pwr:true", "pwr:false", "pwr:true", "pwr:false", "pwr:true"),
                rig.wiring.events.filter { it.startsWith("pwr:") }
            )
        } finally { rig.orchestrator.release() }
    }

    @Test
    fun playDuringAPausedLoad_publishesBeforeTheTrackIsReady() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.wiring.activate()
            rig.orchestrator.setQueue(items(2))
            val gate = CompletableDeferred<Unit>()
            rig.a.gate = gate
            val skip = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { runCatching { rig.orchestrator.skip(1) } }
            runCurrent()
            rig.check("paused skip, loading")
            val play = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { runCatching { rig.orchestrator.play() } }
            runCurrent()
            rig.check("play() while the paused skip is still loading")
            gate.complete(Unit)
            advanceTimeBy(100); runCurrent()
            rig.check("after ready")
            skip.cancel(); play.cancel()
        } finally { rig.orchestrator.release() }
    }

    @Test
    fun queueEnd_andRemovalOfThePlayingTrack() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.wiring.activate()
            val queue = items(2)
            rig.orchestrator.setQueue(queue)
            rig.orchestrator.skip(1)
            rig.orchestrator.play(); rig.check("play")
            rig.a.state = Player.STATE_ENDED
            advanceTimeBy(600); runCurrent()
            rig.check("queue ended")
            rig.orchestrator.pause(); rig.check("pause after end")
            rig.a.state = Player.STATE_READY
            rig.orchestrator.play(); rig.check("play")
            rig.orchestrator.setQueue(items(2)); rig.check("playing track removed from queue")
            assertEquals(AudioPlayerState.STOPPED, rig.orchestrator.playbackState)
            assertEquals(false, rig.orchestrator.playWhenReady)
        } finally { rig.orchestrator.release() }
    }

    @Test
    fun settleDuringABlockedPlay_publishesFalse() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.wiring.activate()
            rig.orchestrator.setQueue(items(2))
            rig.a.gate = CompletableDeferred()
            val play = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { runCatching { rig.orchestrator.play() } }
            runCurrent()
            rig.check("play, loading")
            rig.orchestrator.settleActiveTransition()
            rig.check("settled (backend swap capture)")
            play.cancel()
        } finally { rig.orchestrator.release() }
    }

    @Test
    fun swapInAndRollback_forcedPublication() = runTest {
        val rig = Rig(backgroundScope)
        try {
            // Candidate committed after a standard -> pingPong swap, playing.
            rig.orchestrator.setQueue(items(2))
            rig.orchestrator.skip(0)
            rig.orchestrator.pause()
            rig.orchestrator.activatePreparedPlayback(playWhenReady = true, restoredVolume = 1f)
            rig.wiring.activate(); rig.check("activated playing")
            rig.orchestrator.pause(); rig.check("pause after activation")
            rig.orchestrator.play(); rig.check("play")
            // pingPong -> standard swap that fails: quiescence, then rollback.
            rig.wiring.suspendAdmission()
            val quiescence = rig.orchestrator.beginHandoffQuiescence()
            rig.orchestrator.cancelHandoffQuiescence(quiescence)
            rig.wiring.activate(); rig.check("rolled back")
            rig.orchestrator.pause(); rig.check("pause after rollback")
        } finally { rig.orchestrator.release() }
    }

    @Test
    fun playOnAnEmptyQueueAfterActivation_isPublished() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.orchestrator.activatePreparedPlayback(playWhenReady = false, restoredVolume = 1f)
            rig.wiring.activate(); rig.check("activated, empty queue")
            rig.orchestrator.play()
            rig.check("play() on an empty queue")
        } finally { rig.orchestrator.release() }
    }

    @Test
    fun playOnAnEmptyQueueTwice_isPublishedEachTime() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.wiring.activate()
            rig.orchestrator.play(); rig.check("first play() on empty queue")
            rig.orchestrator.pause(); rig.check("pause")
            rig.orchestrator.play(); rig.check("second play() on empty queue")
        } finally { rig.orchestrator.release() }
    }

    @Test
    fun pauseAfterARollbackWhileBuffering_isPublished() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.wiring.activate()
            rig.orchestrator.setQueue(items(2))
            rig.orchestrator.play(); rig.check("play")
            rig.a.state = Player.STATE_BUFFERING // network stall while playing
            rig.wiring.suspendAdmission()
            val quiescence = rig.orchestrator.beginHandoffQuiescence()
            rig.orchestrator.cancelHandoffQuiescence(quiescence)
            rig.wiring.activate(); rig.check("rolled back while buffering")
            rig.orchestrator.pause()
            rig.check("pause after that rollback")
        } finally { rig.orchestrator.release() }
    }
    @Test
    fun playbackStateComesBeforePlayWhenReady() = runTest {
        val rig = Rig(backgroundScope)
        try {
            rig.wiring.activate()
            rig.orchestrator.setQueue(items(2))
            rig.orchestrator.play(); rig.check("play")
            rig.orchestrator.pause(); rig.check("pause")
            rig.orchestrator.play(); rig.check("play again")
            rig.orchestrator.stop(); rig.check("stop")
            assertEquals(
                listOf("state:IDLE", "pwr:false", "state:LOADING", "pwr:true", "state:PLAYING", "state:PAUSED", "pwr:false", "state:PLAYING", "pwr:true", "state:STOPPED", "pwr:false"),
                rig.wiring.events
            )
        } finally { rig.orchestrator.release() }
    }
}
