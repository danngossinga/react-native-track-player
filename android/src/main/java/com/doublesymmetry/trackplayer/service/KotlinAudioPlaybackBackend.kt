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
    val playbackError: AndroidPlaybackErrorSnapshot?
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

internal data class AndroidPlaybackErrorSnapshot(
    val message: String?,
    val code: String?
)

internal data class AndroidPlaybackBackendReadSnapshot(
    val backendType: PlaybackBackendType,
    val queueItems: List<TrackAudioItem>,
    val currentIndex: Int,
    val playbackState: AudioPlayerState,
    val playbackError: AndroidPlaybackErrorSnapshot?,
    val playWhenReady: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val bufferedMs: Long,
    val volume: Float,
    val rate: Float,
    val repeatMode: RepeatMode
)

internal fun AndroidPlaybackBackendRouting.readSnapshot() =
    AndroidPlaybackBackendReadSnapshot(
        backendType = type,
        queueItems = queueItems.toList(),
        currentIndex = currentIndex,
        playbackState = playbackState,
        playbackError = playbackError,
        playWhenReady = playWhenReady,
        positionMs = positionMs,
        durationMs = durationMs,
        bufferedMs = bufferedMs,
        volume = volume,
        rate = rate,
        repeatMode = repeatMode
    )

internal class KotlinAudioLogicalPlaybackStateSidecar {
    private var idleWithoutActiveItem = false

    fun restore(snapshot: PlaybackBackendSnapshot) {
        idleWithoutActiveItem = snapshot.queueIds.isNotEmpty() &&
            (snapshot.activeIndex == null || snapshot.activeIndex < 0)
    }

    fun activate(): Boolean {
        val wasIdle = idleWithoutActiveItem
        idleWithoutActiveItem = false
        return wasIdle
    }

    fun consumeIdleForNext(): Boolean = activate()

    fun shouldIgnorePrevious(): Boolean = idleWithoutActiveItem

    fun rollbackActivation(wasIdle: Boolean) {
        if (wasIdle) idleWithoutActiveItem = true
    }

    fun hasLogicalActiveItem(physicalIndex: Int): Boolean =
        !idleWithoutActiveItem && physicalIndex >= 0

    fun onQueueCleared() {
        idleWithoutActiveItem = false
    }

    fun onQueueSizeChanged(queueSize: Int) {
        if (queueSize == 0) idleWithoutActiveItem = false
    }

    fun currentIndex(physicalIndex: Int): Int =
        if (idleWithoutActiveItem) -1 else physicalIndex

    fun activeIndex(physicalIndex: Int, queueSize: Int): Int? =
        currentIndex(physicalIndex).takeIf { it in 0 until queueSize }

    fun playbackState(physicalState: AudioPlayerState): AudioPlayerState =
        if (idleWithoutActiveItem) AudioPlayerState.IDLE else physicalState

    fun playWhenReady(physicalPlayWhenReady: Boolean): Boolean =
        !idleWithoutActiveItem && physicalPlayWhenReady

    fun positionMs(physicalPositionMs: Long): Long =
        if (idleWithoutActiveItem) 0L else physicalPositionMs

    fun durationMs(physicalDurationMs: Long): Long =
        if (idleWithoutActiveItem) 0L else physicalDurationMs

    fun bufferedMs(physicalBufferedMs: Long): Long =
        if (idleWithoutActiveItem) 0L else physicalBufferedMs
}

internal class KotlinAudioPlaybackBackend(
    private val player: QueuedAudioPlayer,
    override val identity: Any,
    private val queueStore: AndroidTrackQueue,
    private val transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
    private val onCommitted: (QueuedAudioPlayer) -> Unit,
    private val onActivated: (QueuedAudioPlayer) -> Unit,
    private val onDisposed: (QueuedAudioPlayer) -> Unit,
    private val onLogicalActiveItemActivated: (Int) -> Unit = {},
    private val onActivatedAfterDrain: suspend (QueuedAudioPlayer, AudioPlayerState) -> Unit =
        { activated, _ -> onActivated(activated) },
    private val suspendControlSurface: () -> Unit = {},
    private val resumeControlSurface: suspend (AudioPlayerState) -> Unit = {},
    private val readinessGate: StandardPlaybackReadinessGate = StandardPlaybackReadinessGate(),
    initiallyAuthoritative: Boolean = false
) : AndroidPlaybackBackendRouting {
    override val type = PlaybackBackendType.STANDARD
    private val queueState = PlaybackBackendQueueState<TrackAudioItem>()
    private val logicalPlaybackState = KotlinAudioLogicalPlaybackStateSidecar()
    private var pendingSnapshot = PlaybackBackendSnapshot.empty()
    private var isAuthoritative = initiallyAuthoritative
    private var disposed = false
    private var playerReleased = false

    override val queueItems: List<TrackAudioItem>
        get() = queueStore.snapshot()
    override val currentIndex: Int
        get() = logicalPlaybackState.currentIndex(player.currentIndex)
    override val playbackState: AudioPlayerState
        get() = logicalPlaybackState.playbackState(player.playerState)
    override val playbackError: AndroidPlaybackErrorSnapshot?
        get() = player.playbackError?.let { error ->
            AndroidPlaybackErrorSnapshot(
                message = error.message,
                code = error.code?.let { "android-$it" }
            )
        }
    override val playWhenReady: Boolean
        get() = logicalPlaybackState.playWhenReady(player.playWhenReady)
    override val positionMs: Long
        get() = logicalPlaybackState.positionMs(player.position)
    override val durationMs: Long
        get() = logicalPlaybackState.durationMs(player.duration)
    override val bufferedMs: Long
        get() = logicalPlaybackState.bufferedMs(player.bufferedPosition)
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
        queueState.captureAuthoritative(queue)
        val index = logicalPlaybackState.activeIndex(player.currentIndex, queue.size)
        return PlaybackBackendSnapshot(
            queueIds = queue.map { it.track.queueId.toString() },
            activeIndex = index,
            activeTrackId = index?.let { queue[it].track.queueId.toString() },
            positionMs = positionMs.coerceAtLeast(0L),
            playWhenReady = playWhenReady,
            volume = player.volume,
            rate = player.playbackSpeed,
            repeatMode = repeatMode.ordinal,
            transitionGeneration = transitionGenerationSidecar.current()
        )
    }

    override suspend fun prepareSilently(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        queueState.stage(queueStore.snapshot())
        pendingSnapshot = snapshot
        if (!isAuthoritative) {
            player.volume = 0f
            player.stop()
        }
    }

    override suspend fun restore(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        val queue = if (isAuthoritative) queueState.authoritative() else queueState.pending()
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
        logicalPlaybackState.restore(snapshot)
    }

    override suspend fun prepareActivation(snapshot: PlaybackBackendSnapshot) {
        check(!disposed && !playerReleased) { "The standard playback candidate was disposed before activation." }
        StandardPlaybackActivationSnapshotValidator.validate(snapshot)
        val index = snapshot.activeIndex?.takeIf { it >= 0 }
        if (index == null) return
        check(index in queueState.pending().indices) {
            "The standard playback candidate does not contain the active track."
        }
        readinessGate.await(index, snapshot.positionMs) {
            StandardPlaybackReadinessObservation(
                state = player.playerState,
                currentIndex = player.currentIndex,
                positionMs = player.position
            )
        }
    }

    override suspend fun beginHandoffQuiescence(): PlaybackBackendSnapshot {
        settleActiveTransition()
        val logicalPlayWhenReady = player.playWhenReady
        val logicalVolume = player.volume
        player.volume = 0f
        player.playWhenReady = false
        player.pause()
        return snapshot().copy(
            playWhenReady = logicalPlayWhenReady,
            volume = logicalVolume
        )
    }

    override suspend fun cancelHandoffQuiescence(snapshot: PlaybackBackendSnapshot) {
        if (disposed || playerReleased) return
        player.volume = snapshot.volume
        player.playWhenReady = snapshot.playWhenReady
        if (snapshot.playWhenReady) player.play() else player.pause()
    }

    override suspend fun stopAndMute() {
        if (playerReleased) return
        player.volume = 0f
        player.stop()
    }

    override suspend fun suspendControlSurface() {
        suspendControlSurface.invoke()
    }

    override suspend fun resumeControlSurface(snapshot: PlaybackBackendSnapshot) {
        resumeControlSurface.invoke(playbackState)
    }

    override fun activateInitialControlSurface() {
        check(isAuthoritative) { "Only the authoritative standard backend can activate initially." }
        onCommitted(player)
        onActivated(player)
    }

    override fun relinquishExclusiveControlSurfaceBeforeCommit() {
        // MusicService's pinned KotlinAudio adapter already deactivated the
        // private MediaSession at the physical barrier. Destruction remains
        // asynchronous until after replacement activation and admission.
    }

    override fun commitQueue(snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        pendingSnapshot = snapshot
        val committedQueue = queueState.commit()
        isAuthoritative = true
        queueStore.replaceWith(committedQueue)
        onCommitted(player)
    }

    override suspend fun activateAfterCommit(snapshot: PlaybackBackendSnapshot) {
        player.volume = snapshot.volume
        player.playWhenReady = snapshot.playWhenReady
        if (snapshot.playWhenReady) {
            logicalPlaybackState.activate()
            player.play()
        } else {
            player.pause()
        }
        onActivatedAfterDrain(player, playbackState)
    }

    override suspend fun reactivateAfterRollback(snapshot: PlaybackBackendSnapshot) {
        isAuthoritative = true
        queueStore.replaceWith(queueState.rollback())
        onCommitted(player)
        activateAfterCommit(snapshot)
    }

    override suspend fun play() {
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            player.play()
        }
    }
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
        logicalPlaybackState.onQueueSizeChanged(player.items.size)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun removeUpcomingTracks() {
        if (!logicalPlaybackState.hasLogicalActiveItem(player.currentIndex)) return
        player.removeUpcomingItems()
        logicalPlaybackState.onQueueSizeChanged(player.items.size)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun removePreviousTracks() {
        if (!logicalPlaybackState.hasLogicalActiveItem(player.currentIndex)) return
        player.removePreviousItems()
        logicalPlaybackState.onQueueSizeChanged(player.items.size)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun replace(index: Int, item: TrackAudioItem) {
        player.replaceItem(index, item)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun replaceQueue(items: List<TrackAudioItem>) {
        player.clear()
        player.add(items)
        logicalPlaybackState.onQueueSizeChanged(items.size)
        queueStore.replaceWith(items)
    }

    override fun clearQueue() {
        player.clear()
        logicalPlaybackState.onQueueCleared()
        queueStore.clear()
    }

    override suspend fun load(item: TrackAudioItem) {
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            player.load(item)
            queueStore.replaceWith(player.items.map { it as TrackAudioItem })
        }
    }

    override suspend fun skip(index: Int) {
        if (index !in player.items.indices) {
            throw IndexOutOfBoundsException("The track index is out of bounds: $index")
        }
        runActivatingOperation(
            publishLogicalActivation = index == player.currentIndex
        ) { _ -> player.jumpToItem(index) }
    }
    override suspend fun skipToNext() {
        if (logicalPlaybackState.consumeIdleForNext()) {
            try {
                selectFirstPhysicalItemIfNeeded()
            } catch (error: Throwable) {
                logicalPlaybackState.rollbackActivation(wasIdle = true)
                throw error
            }
            publishCurrentPhysicalItem()
            return
        }
        player.next()
    }
    override suspend fun skipToPrevious() {
        if (logicalPlaybackState.shouldIgnorePrevious()) return
        player.previous()
    }
    override suspend fun seekBy(offsetMs: Long) { player.seekBy(offsetMs, TimeUnit.MILLISECONDS) }
    override suspend fun retry() {
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            player.prepare()
        }
    }
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

    private suspend fun selectFirstPhysicalItemIfNeeded() {
        if (player.items.isNotEmpty() && player.currentIndex != 0) {
            player.jumpToItem(0)
        }
    }

    private suspend fun runActivatingOperation(
        publishLogicalActivation: Boolean = false,
        operation: suspend (Boolean) -> Unit
    ) {
        val wasIdle = logicalPlaybackState.activate()
        try {
            operation(wasIdle)
        } catch (error: Throwable) {
            logicalPlaybackState.rollbackActivation(wasIdle)
            throw error
        }
        if (wasIdle && publishLogicalActivation) publishCurrentPhysicalItem()
    }

    private fun publishCurrentPhysicalItem() {
        player.currentIndex.takeIf { it in player.items.indices }
            ?.let(onLogicalActiveItemActivated)
    }
}

internal fun sameAudioItems(lhs: List<TrackAudioItem>, rhs: List<TrackAudioItem>): Boolean {
    return lhs.size == rhs.size && lhs.indices.all { lhs[it] === rhs[it] }
}
