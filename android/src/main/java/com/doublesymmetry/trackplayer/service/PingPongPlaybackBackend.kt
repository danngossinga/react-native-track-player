package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.RepeatMode
import com.doublesymmetry.trackplayer.model.TrackAudioItem

internal class PingPongPlaybackBackend(
    private val orchestrator: AndroidPlaybackOrchestrator,
    override val identity: Any,
    private val queueStore: AndroidTrackQueue,
    private val transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
    private val suspendControlSurface: () -> Unit,
    private val resumeControlSurface: () -> Unit,
    private val activateControlSurface: () -> Unit,
    private val onCommitted: (AndroidPlaybackOrchestrator) -> Unit,
    private val onDisposed: (AndroidPlaybackOrchestrator) -> Unit,
    initiallyAuthoritative: Boolean = false
) : AndroidPlaybackBackendRouting {
    override val type = PlaybackBackendType.PING_PONG
    private var pendingQueue: List<TrackAudioItem> = emptyList()
    private var authoritativeQueue: List<TrackAudioItem> = emptyList()
    private var isAuthoritative = initiallyAuthoritative
    private var disposed = false

    init {
        if (initiallyAuthoritative) onCommitted(orchestrator)
    }

    override val queueItems: List<TrackAudioItem>
        get() = queueStore.snapshot()
    override val currentIndex: Int
        get() = orchestrator.currentIndex
    override val playbackState: AudioPlayerState
        get() = orchestrator.playbackState
    override val playWhenReady: Boolean
        get() = orchestrator.playWhenReady
    override val positionMs: Long
        get() = orchestrator.positionMs
    override val durationMs: Long
        get() = orchestrator.durationMs
    override val bufferedMs: Long
        get() = orchestrator.bufferedMs
    override val volume: Float
        get() = orchestrator.volume
    override val rate: Float
        get() = orchestrator.rate
    override val repeatMode: RepeatMode
        get() = orchestrator.repeatMode

    override suspend fun settleActiveTransition() {
        orchestrator.settleActiveTransition()
    }

    override suspend fun snapshot(): PlaybackBackendSnapshot {
        val queue = queueStore.snapshot()
        authoritativeQueue = queue
        val index = orchestrator.currentIndex.takeIf { it in queue.indices }
        return PlaybackBackendSnapshot(
            queueIds = queue.map { it.track.queueId.toString() },
            activeIndex = index,
            activeTrackId = index?.let { queue[it].track.queueId.toString() },
            positionMs = orchestrator.positionMs.coerceAtLeast(0L),
            playWhenReady = orchestrator.playWhenReady,
            volume = orchestrator.volume,
            rate = orchestrator.rate,
            repeatMode = orchestrator.repeatMode.ordinal,
            transitionGeneration = transitionGenerationSidecar.observe(orchestrator.transitionGeneration)
        )
    }

    override suspend fun prepareSilently(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        pendingQueue = queueStore.snapshot()
        orchestrator.setVolume(0f)
        orchestrator.setQueue(pendingQueue)
    }

    override suspend fun restore(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        val queue = if (isAuthoritative) authoritativeQueue else pendingQueue
        orchestrator.setQueue(queue)
        orchestrator.setRate(snapshot.rate)
        orchestrator.setRepeatMode(RepeatMode.fromOrdinal(snapshot.repeatMode))
        val index = snapshot.activeIndex
        val needsRestore = !isAuthoritative ||
            orchestrator.currentIndex != (index ?: -1) ||
            kotlin.math.abs(orchestrator.positionMs - snapshot.positionMs) > 750L ||
            orchestrator.playWhenReady != snapshot.playWhenReady
        if (needsRestore && index != null && index in queue.indices) {
            orchestrator.skip(index)
            orchestrator.seekTo(snapshot.positionMs)
        }
        orchestrator.pause()
    }

    override suspend fun stopAndMute() {
        orchestrator.setVolume(0f)
        orchestrator.stop()
    }

    override suspend fun suspendControlSurface() {
        suspendControlSurface.invoke()
    }

    override suspend fun resumeControlSurface(snapshot: PlaybackBackendSnapshot) {
        resumeControlSurface.invoke()
    }

    override fun activateInitialControlSurface() {
        activateControlSurface.invoke()
    }

    override fun relinquishExclusiveControlSurfaceBeforeCommit() {
        suspendControlSurface.invoke()
    }

    override fun commitQueue(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        authoritativeQueue = pendingQueue
        isAuthoritative = true
        queueStore.replaceWith(pendingQueue)
        onCommitted(orchestrator)
    }

    override fun activateAfterCommit(snapshot: PlaybackBackendSnapshot) {
        orchestrator.activatePreparedPlayback(
            playWhenReady = snapshot.playWhenReady,
            restoredVolume = snapshot.volume
        )
        activateControlSurface.invoke()
    }

    override suspend fun play() { orchestrator.play() }
    override fun pause() { orchestrator.pause() }
    override suspend fun seekTo(positionMs: Long) { orchestrator.seekTo(positionMs) }
    override suspend fun startTransition(request: PlaybackTransitionRequest) {
        orchestrator.crossFade(
            request.durationMs.toDouble(),
            request.intervalMs.toDouble(),
            request.targetVolume.toDouble(),
            request.waitUntilMs.toDouble()
        )
    }

    override suspend fun dispose() {
        if (disposed) return
        disposed = true
        isAuthoritative = false
        orchestrator.release()
        onDisposed(orchestrator)
    }

    override fun add(items: List<TrackAudioItem>, atIndex: Int?) {
        if (atIndex == null) queueStore.add(items) else queueStore.add(items, atIndex)
        orchestrator.setQueue(queueStore.snapshot())
    }
    override fun move(fromIndex: Int, toIndex: Int) {
        queueStore.move(fromIndex, toIndex)
        orchestrator.setQueue(queueStore.snapshot())
    }
    override fun remove(indexes: List<Int>) {
        queueStore.remove(indexes)
        orchestrator.setQueue(queueStore.snapshot())
    }
    override fun removeUpcomingTracks() {
        queueStore.removeUpcoming(currentIndex)
        orchestrator.setQueue(queueStore.snapshot())
    }
    override fun removePreviousTracks() {
        queueStore.removePrevious(currentIndex)
        orchestrator.setQueue(queueStore.snapshot())
    }
    override fun replace(index: Int, item: TrackAudioItem) {
        queueStore.replace(index, item)
        orchestrator.setQueue(queueStore.snapshot())
    }
    override fun replaceQueue(items: List<TrackAudioItem>) {
        queueStore.replaceWith(items)
        orchestrator.setQueue(items)
    }
    override fun clearQueue() {
        queueStore.clear()
        orchestrator.stop()
        orchestrator.setQueue(emptyList())
    }
    override suspend fun load(item: TrackAudioItem) {
        if (queueStore.indexOfQueueId(item.track.queueId) < 0) queueStore.replaceWith(listOf(item))
        orchestrator.setQueue(queueStore.snapshot())
        orchestrator.load(item)
    }
    override suspend fun skip(index: Int) { orchestrator.skip(index) }
    override suspend fun skipToNext() { orchestrator.skipToNext() }
    override suspend fun skipToPrevious() { orchestrator.skipToPrevious() }
    override suspend fun seekBy(offsetMs: Long) { orchestrator.seekBy(offsetMs) }
    override suspend fun retry() { orchestrator.play() }
    override fun stop() { orchestrator.stop() }
    override fun setVolume(value: Float) { orchestrator.setVolume(value) }
    override fun setRate(value: Float) { orchestrator.setRate(value) }
    override fun setRepeatMode(value: RepeatMode) { orchestrator.setRepeatMode(value) }
    override suspend fun prepareCrossfade(previous: Boolean, seekTo: Double) {
        orchestrator.crossFadePrepare(previous, seekTo)
    }
}
