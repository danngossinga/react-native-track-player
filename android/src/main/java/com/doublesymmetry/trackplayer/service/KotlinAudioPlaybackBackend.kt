package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.QueuedPlayerOptions
import com.doublesymmetry.kotlinaudio.models.RepeatMode
import com.doublesymmetry.kotlinaudio.players.QueuedAudioPlayer
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.utils.RejectionException
import java.util.concurrent.TimeUnit

internal interface AndroidPlaybackBackendRouting : PlaybackBackend {
    val queueItems: List<TrackAudioItem>
    val currentIndex: Int
    val playbackState: AudioPlayerState
    val playWhenReady: Boolean
    val positionMs: Long
    val durationMs: Long
    val bufferedMs: Long
    val volume: Float
    val rate: Float
    val repeatMode: RepeatMode

    fun add(items: List<TrackAudioItem>, atIndex: Int? = null)
    fun move(fromIndex: Int, toIndex: Int)
    fun remove(indexes: List<Int>)
    fun removeUpcomingTracks()
    fun removePreviousTracks()
    fun replace(index: Int, item: TrackAudioItem)
    fun replaceQueue(items: List<TrackAudioItem>)
    fun clearQueue()
    suspend fun load(item: TrackAudioItem)
    suspend fun skip(index: Int)
    suspend fun skipToNext()
    suspend fun skipToPrevious()
    suspend fun seekBy(offsetMs: Long)
    suspend fun retry()
    fun stop()
    fun setVolume(value: Float)
    fun setRate(value: Float)
    fun setRepeatMode(value: RepeatMode)
    suspend fun prepareCrossfade(previous: Boolean, seekTo: Double)
}

internal class KotlinAudioPlaybackBackend(
    private val player: QueuedAudioPlayer,
    override val identity: Any,
    private val queueStore: AndroidTrackQueue,
    private val transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
    private val onCommitted: (QueuedAudioPlayer) -> Unit,
    private val onDisposed: (QueuedAudioPlayer) -> Unit,
    initiallyAuthoritative: Boolean = false
) : AndroidPlaybackBackendRouting {
    override val type = PlaybackBackendType.STANDARD
    private var pendingQueue: List<TrackAudioItem> = emptyList()
    private var authoritativeQueue: List<TrackAudioItem> = emptyList()
    private var pendingSnapshot = PlaybackBackendSnapshot.empty()
    private var isAuthoritative = initiallyAuthoritative
    private var disposed = false
    private var playerReleased = false

    init {
        if (initiallyAuthoritative) onCommitted(player)
    }

    override val queueItems: List<TrackAudioItem>
        get() = queueStore.snapshot()
    override val currentIndex: Int
        get() = player.currentIndex
    override val playbackState: AudioPlayerState
        get() = player.playerState
    override val playWhenReady: Boolean
        get() = player.playWhenReady
    override val positionMs: Long
        get() = player.position
    override val durationMs: Long
        get() = player.duration
    override val bufferedMs: Long
        get() = player.bufferedPosition
    override val volume: Float
        get() = player.volume
    override val rate: Float
        get() = player.playbackSpeed
    override val repeatMode: RepeatMode
        get() = (player.playerOptions as? QueuedPlayerOptions)?.repeatMode ?: RepeatMode.OFF

    override suspend fun settleActiveTransition() = Unit

    override suspend fun snapshot(): PlaybackBackendSnapshot {
        val queue = player.items.map { it as TrackAudioItem }
        queueStore.replaceWith(queue)
        authoritativeQueue = queue
        val index = player.currentIndex.takeIf { it in queue.indices }
        return PlaybackBackendSnapshot(
            queueIds = queue.map { it.track.queueId.toString() },
            activeIndex = index,
            activeTrackId = index?.let { queue[it].track.queueId.toString() },
            positionMs = player.position.coerceAtLeast(0L),
            playWhenReady = player.playWhenReady,
            volume = player.volume,
            rate = player.playbackSpeed,
            repeatMode = repeatMode.ordinal,
            transitionGeneration = transitionGenerationSidecar.current()
        )
    }

    override suspend fun prepareSilently(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        pendingQueue = queueStore.snapshot()
        pendingSnapshot = snapshot
        if (!isAuthoritative) {
            player.volume = 0f
            player.stop()
        }
    }

    override suspend fun restore(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        val queue = if (isAuthoritative) authoritativeQueue else pendingQueue
        val current = player.items.map { it as TrackAudioItem }
        val queueChanged = !sameAudioItems(current, queue)
        if (!isAuthoritative || queueChanged) {
            player.stop()
            player.clear()
            player.add(queue)
        }
        player.playbackSpeed = snapshot.rate
        (player.playerOptions as? QueuedPlayerOptions)?.repeatMode = RepeatMode.fromOrdinal(snapshot.repeatMode)
        val index = snapshot.activeIndex
        if (index != null && index in queue.indices &&
            (!isAuthoritative || queueChanged || player.currentIndex != index)
        ) {
            player.jumpToItem(index)
            player.seek(snapshot.positionMs, TimeUnit.MILLISECONDS)
        }
        player.playWhenReady = false
        player.pause()
    }

    override suspend fun stopAndMute() {
        if (playerReleased) return
        player.volume = 0f
        player.stop()
    }

    override fun relinquishExclusiveControlSurfaceBeforeCommit() {
        releasePlayer()
    }

    override fun commitQueue(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        pendingSnapshot = snapshot
        authoritativeQueue = pendingQueue
        isAuthoritative = true
        queueStore.replaceWith(pendingQueue)
        onCommitted(player)
    }

    override fun activateAfterCommit(snapshot: PlaybackBackendSnapshot) {
        player.volume = snapshot.volume
        player.playWhenReady = snapshot.playWhenReady
        if (snapshot.playWhenReady) player.play() else player.pause()
    }

    override suspend fun play() { player.play() }
    override fun pause() { player.pause() }
    override suspend fun seekTo(positionMs: Long) { player.seek(positionMs, TimeUnit.MILLISECONDS) }

    override suspend fun startTransition(request: PlaybackTransitionRequest) {
        throw RejectionException(
            "The standard playback backend does not own a crossfade engine.",
            "crossfade_disabled"
        )
    }

    override suspend fun dispose() {
        if (disposed) return
        disposed = true
        isAuthoritative = false
        if (!playerReleased) player.stop()
        releasePlayer()
    }

    private fun releasePlayer() {
        if (playerReleased) return
        onDisposed(player)
        playerReleased = true
    }

    override fun add(items: List<TrackAudioItem>, atIndex: Int?) {
        if (atIndex == null) player.add(items) else player.add(items, atIndex)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun move(fromIndex: Int, toIndex: Int) {
        player.move(fromIndex, toIndex)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun remove(indexes: List<Int>) {
        player.remove(indexes)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun removeUpcomingTracks() {
        player.removeUpcomingItems()
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun removePreviousTracks() {
        player.removePreviousItems()
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun replace(index: Int, item: TrackAudioItem) {
        player.replaceItem(index, item)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun replaceQueue(items: List<TrackAudioItem>) {
        player.clear()
        player.add(items)
        queueStore.replaceWith(items)
    }

    override fun clearQueue() {
        player.clear()
        queueStore.clear()
    }

    override suspend fun load(item: TrackAudioItem) {
        player.load(item)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override suspend fun skip(index: Int) { player.jumpToItem(index) }
    override suspend fun skipToNext() { player.next() }
    override suspend fun skipToPrevious() { player.previous() }
    override suspend fun seekBy(offsetMs: Long) { player.seekBy(offsetMs, TimeUnit.MILLISECONDS) }
    override suspend fun retry() { player.prepare() }
    override fun stop() { player.stop() }
    override fun setVolume(value: Float) { player.volume = value }
    override fun setRate(value: Float) { player.playbackSpeed = value }
    override fun setRepeatMode(value: RepeatMode) {
        (player.playerOptions as? QueuedPlayerOptions)?.repeatMode = value
    }
    override suspend fun prepareCrossfade(previous: Boolean, seekTo: Double) {
        throw RejectionException(
            "The standard playback backend does not own a crossfade engine.",
            "crossfade_disabled"
        )
    }
}

internal fun sameAudioItems(lhs: List<TrackAudioItem>, rhs: List<TrackAudioItem>): Boolean {
    return lhs.size == rhs.size && lhs.indices.all { lhs[it] === rhs[it] }
}
