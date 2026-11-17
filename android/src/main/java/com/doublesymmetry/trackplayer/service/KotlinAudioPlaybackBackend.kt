package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.PlaybackError
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
    private val readinessGate: StandardPlaybackReadinessGate,
    /** Waits for every seek, as on iOS (`standardSeekTimeoutMs`, `stallTimeoutMs`). */
    private val seekGate: StandardSeekGate,
    /** The player's ExoPlayer and automatic transitions (StandardPlayerAnalytics), for seeks. */
    private val analytics: () -> StandardPlayerAnalytics? = { null },
    /** The app's `backendSwitchPositionToleranceMs`, read at every restore. */
    private val positionToleranceMs: () -> Long = { DEFAULT_BACKEND_SWITCH_POSITION_TOLERANCE_MS },
    /** Gives up the loads that make no progress ([superviseLoads]); null: none (tests). */
    private val loadWatch: StandardLoadWatch? = null,
    /**
     * Reports a change of the active track ([FailedLoadRule]: once the track loaded, never a
     * track that failed to load): its index (null: none), the track the app had (index, item;
     * null: none) and that track's last position (ms).
     */
    private val onActiveTrackChanged: (index: Int?, lastIndex: Int?, lastItem: TrackAudioItem?, lastPositionMs: Long) -> Unit =
        { _, _, _, _ -> },
    /** A load failed: the active track's index (null: none), for the notification to show it again. */
    private val onLoadFailed: (activeIndex: Int?) -> Unit = {},
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
        get() = if (failedLoads.isPending(player.currentItem)) reportedIndex() else logicalPlaybackState.currentIndex(player.currentIndex)

    /**
     * Which track is active around a load, and when the app is told (iOS's crossfade rule): the
     * player's track is reported once it loaded; while it loads, and after its load failed, the
     * previous one is the active track.
     */
    private val failedLoads = FailedLoadRule()
    private var observedItem: Any? = null
    /** The position of the track the player left at its last item change (the event's lastPosition). */
    private var lastItemPositionMs = 0L
    private var loadDriver: StandardLoadDriver? = null
    /** Skip, next, previous and load end once their track loaded, or with its failure (crossfade's rule). */
    private val commandLoads = StandardCommandLoad()

    /** A new queue (replaced, cleared, emptied): its first track is a new selection. */
    private fun forgetReportedTrack() {
        failedLoads.reset()
        observedItem = null
    }

    private fun indexOfItem(item: Any?): Int? =
        item?.let { target -> player.items.indexOfFirst { it === target } }?.takeIf { it >= 0 }

    /** The track the app was told is active (-1: none, or it left the queue). */
    private fun reportedIndex(): Int = indexOfItem(failedLoads.reported) ?: -1
    override val playbackState: AudioPlayerState
        get() = logicalPlaybackState.playbackState(player.playerState)
    override val playbackError: AndroidPlaybackErrorSnapshot?
        get() = player.playbackError?.let { error ->
            AndroidPlaybackErrorSnapshot(
                message = error.message,
                code = standardPlaybackErrorCode(error)
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
        if (index != null && index in queue.indices) {
            // As iOS: load the track again when needed, and seek when further off than
            // backendSwitchPositionToleranceMs.
            val steps = standardRestoreSteps(
                isAuthoritative = isAuthoritative,
                queueChanged = queueChanged,
                currentIndex = player.currentIndex,
                targetIndex = index,
                positionMs = player.position,
                targetPositionMs = snapshot.positionMs,
                positionToleranceMs = positionToleranceMs()
            )
            if (steps.jump) player.jumpToItem(index)
            if (steps.seek) player.seek(snapshot.positionMs, TimeUnit.MILLISECONDS)
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
                positionMs = player.position,
                bufferedPositionMs = player.bufferedPosition
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
        // A backend switch restored this track, ready (the readiness gate): the app has it.
        failedLoads.adopted(player.currentItem.takeIf { logicalPlaybackState.hasLogicalActiveItem(player.currentIndex) })
        observedItem = player.currentItem
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
        // A new load: a failure of it no command waits for is reported again.
        commandLoads.failureCleared()
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            loadActiveTrackAfterFailedLoad()
            player.play()
        }
    }
    override fun pause() {
        // As iOS (cancelPendingSeeks): a pause, stop, load or relative seek ends a seek in progress.
        seekGate.cancel("pause")
        player.pause()
    }
    override suspend fun seekTo(positionMs: Long) {
        // A newer command, as a crossfade seek: a skip or load still waiting ends cancelled.
        commandLoads.cancel()
        failedLoads.command()
        try {
            // As a crossfade seek that gives up: the player stops loading and is in error.
            seekGate.seekOrGiveUp(seekPlayer, positionMs) { error ->
                androidXfadeLog("standard load abandoned (seek ${error.message}) positionMs=${player.position}")
                player.failLoad(PlaybackError(error.code, error.message, fromHost = true), report = false)
            }
        } finally {
            // The seek no longer owns the loading: the load watch looks again at once.
            loadDriver?.poke()
        }
    }

    /**
     * Starts the stall rule on this player's loads, on its thread ([handler], the main one):
     * checked at each of the player's events and, only while a load is watched, by one timer
     * (StandardLoadDriver). Only the authoritative backend's player is watched (a candidate's
     * readiness is [StandardPlaybackReadinessGate]'s); a waited seek owns its loading (it gives up
     * by its own limits). A load that gives up stops the player, which goes to the error state and
     * reports the error, as a crossfade advance that fails.
     */
    fun startLoadWatch(handler: android.os.Handler) {
        val collector = analytics() ?: return
        collector.addListener(object : com.google.android.exoplayer2.analytics.AnalyticsListener {
            // The seek and readiness waits look at every player event (they only sample the
            // player between events, every stallTimeoutMs / 10).
            override fun onEvents(
                player: com.google.android.exoplayer2.Player,
                events: com.google.android.exoplayer2.analytics.AnalyticsListener.Events
            ) {
                seekGate.poke()
                readinessGate.poke()
            }

            override fun onPositionDiscontinuity(
                eventTime: com.google.android.exoplayer2.analytics.AnalyticsListener.EventTime,
                oldPosition: com.google.android.exoplayer2.Player.PositionInfo,
                newPosition: com.google.android.exoplayer2.Player.PositionInfo,
                reason: Int
            ) {
                if (oldPosition.mediaItemIndex != newPosition.mediaItemIndex) lastItemPositionMs = oldPosition.positionMs
            }
        })
        val watch = loadWatch ?: return
        loadDriver = StandardLoadDriver(watch, handler, ::observeLoad, ::giveUpLoad).also {
            it.listenTo(collector)
            it.poke()
        }
    }

    /** What the load watch sees, after feeding [failedLoads] (item moves, ready, errors). */
    private fun observeLoad(): StandardLoadObservation {
        val exo = analytics()?.player
        val logicalItem = player.currentItem.takeIf { logicalPlaybackState.hasLogicalActiveItem(player.currentIndex) }
        if (!isAuthoritative || disposed || playerReleased || logicalItem == null) {
            return standardLoadObservation(exo, null, null)
        }
        return standardLoadObservation(exo, logicalItem, analytics()?.loadedBytes, ownedElsewhere = seekGate.isWaiting)
            .also(::followLoad)
    }

    /** Feeds [failedLoads]: the player's item changes, when it is ready, and a player error. */
    private fun followLoad(observed: StandardLoadObservation) {
        val item = observed.item ?: return
        if (item !== observedItem) {
            val from = failedLoads.reported
            observedItem = item
            // The selection of a new queue's first track is reported at once; a move to another
            // track once it loaded.
            if (failedLoads.moved(item)) report(FailedLoadRule.Report(item, from))
        }
        if (observed.hasError) {
            if (failedLoads.playerErrorSeen()) {
                failLoadedTrack()
                // A command waiting for this load rejects with the player's error, as a crossfade
                // load that fails (crossfade_engine_error).
                commandLoads.failed(
                    item,
                    STANDARD_LOAD_ERROR_CODE,
                    analytics()?.player?.playerError?.message ?: STANDARD_LOAD_FAILED_MESSAGE,
                    reportedByPlayer = true
                )
            }
            return
        }
        if (failedLoads.playerErrorGone()) commandLoads.failureCleared()
        if (observed.ownedElsewhere) return
        if (observed.playbackState == com.google.android.exoplayer2.Player.STATE_READY ||
            observed.playbackState == com.google.android.exoplayer2.Player.STATE_ENDED
        ) {
            failedLoads.ready()?.let(::report)
            commandLoads.ruleSettled(failedLoads.active, failedLoads.reported)
        }
    }

    /**
     * Waits for the load a command started (skip, next, previous, load) on the player's current
     * item, as the crossfade path: returns once it loaded and is the active track; throws the
     * load's failure (crossfade_prepare_timeout, crossfade_engine_error), or `cancelled` when a
     * newer command replaced it. Without a load watch (tests), returns at once.
     */
    private suspend fun awaitCommandLoad() {
        val driver = loadDriver ?: return
        val target = player.currentItem ?: return
        if (disposed || playerReleased) return
        val outcome = kotlinx.coroutines.CompletableDeferred<StandardCommandLoad.Outcome>()
        val wait = commandLoads.begin(target, failedLoads.active, failedLoads.reported) { outcome.complete(it) } ?: return
        // Its track must load: after a give-up or a player error on it, the player stands still.
        if (standardCommandLoadMustStart(targetLoaded = false, exoState = analytics()?.player?.playbackState ?: com.google.android.exoplayer2.Player.STATE_IDLE)) {
            player.prepare()
        }
        // The load is looked at now (the player's events of the command may have come first).
        driver.poke()
        val result = try {
            outcome.await()
        } catch (error: kotlinx.coroutines.CancellationException) {
            commandLoads.drop(wait)
            throw error
        }
        when (result) {
            StandardCommandLoad.Outcome.Loaded -> Unit
            is StandardCommandLoad.Outcome.Failed -> throw RejectionException(result.message, result.code)
            StandardCommandLoad.Outcome.Cancelled ->
                throw RejectionException(STANDARD_COMMAND_LOAD_CANCELLED_MESSAGE, "cancelled")
        }
    }

    /**
     * Whether the player's current error is a command's to report (its rejection): no playback
     * error event for it, as the crossfade path (MusicService).
     */
    fun reportsPlayerErrorThroughCommand(): Boolean = commandLoads.reportsFailureOf(player.currentItem)

    /** A load failed: the previous track stays active (none when there was none), as iOS. */
    private fun failLoadedTrack() {
        androidXfadeLog("standard load failed index=${player.currentIndex} activeIndex=${indexOfItem(failedLoads.active)}")
        val change = failedLoads.failed()
        change?.let(::report)
        if (failedLoads.isPending(player.currentItem)) onLoadFailed(indexOfItem(failedLoads.reported))
    }

    private fun report(change: FailedLoadRule.Report, lastIndex: Int? = indexOfItem(change.from)) {
        val lastItem = change.from as? TrackAudioItem
        onActiveTrackChanged(indexOfItem(change.to), lastIndex, lastItem, lastItemPositionMs)
    }

    /**
     * The reported track left the queue: no active track, reported at once (as the crossfade
     * path's queue change); the player's next track is reported once it loaded.
     */
    private fun reportRemovedTrack(before: List<Any?>) {
        val reported = failedLoads.reported ?: return
        if (indexOfItem(reported) != null) return
        val lastIndex = before.indexOfFirst { it === reported }.takeIf { it >= 0 }
        failedLoads.removed(reported)?.let { report(it, lastIndex) }
    }

    /** Before a play or retry after a failed load: the previous track, else the failed one, loads. */
    private fun loadActiveTrackAfterFailedLoad() {
        val target = indexOfItem(failedLoads.play()) ?: return
        if (target != player.currentIndex) player.jumpToItem(target)
    }

    private fun giveUpLoad(verdict: StallVerdict) {
        val stallMs = loadWatch?.lastStallTimeoutMs ?: 0L
        val totalMs = loadWatch?.lastTotalTimeoutMs ?: 0L
        val reason = stallVerdictReason(verdict, stallMs, totalMs)
        androidXfadeLog("standard load abandoned (load $reason) positionMs=${player.position}")
        val item = player.currentItem
        val message = standardLoadGiveUpMessage(verdict, stallMs, totalMs)
        // A load a command waits for is reported by its rejection; one no command waits for (a
        // natural advance, a play) as a playback error, as the crossfade path.
        player.failLoad(
            PlaybackError(PREPARE_TIMEOUT_CODE, message, fromHost = true),
            report = !commandLoads.waitsFor(item)
        )
        failLoadedTrack()
        commandLoads.failed(item, PREPARE_TIMEOUT_CODE, message, reportedByPlayer = false)
    }

    /** ExoPlayer's own state (masked at once by seekTo), not KotlinAudio's (a message later). */
    private val seekPlayer = object : StandardSeekPlayer {
        override val currentItem: Any? get() = player.currentItem
        // A give-up (failLoad) left the player stopped and in error until the next command: a
        // seek loads the track again, as after a stop (iOS: hostFailure cleared, item reloaded).
        override val kotlinAudioState: AudioPlayerState
            get() = player.playerState.let {
                if (it == AudioPlayerState.ERROR && player.playbackError?.fromHost == true) AudioPlayerState.STOPPED else it
            }
        override val exo: ExoSeekState = CapturedExoSeekState { analytics()?.player }
        override val positionMs: Long get() = player.position
        override val bufferedPositionMs: Long get() = player.bufferedPosition
        override val durationMs: Long get() = player.duration
        override val rate: Float get() = player.playbackSpeed
        override val autoTransitions: Long get() = analytics()?.transitions?.count ?: 0L
        override fun prepare() = player.prepare()
        override fun seekTo(positionMs: Long) = player.seek(positionMs, TimeUnit.MILLISECONDS)
    }

    override suspend fun startTransition(request: PlaybackTransitionRequest) {
        throw RejectionException(
            "The standard playback backend does not own a crossfade engine.",
            "crossfade_disabled"
        )
    }

    override suspend fun dispose() {
        if (disposed) return
        disposed = true
        commandLoads.cancel()
        loadDriver?.stop()
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
        val before = player.items.toList()
        player.remove(indexes)
        cancelCommandLoadOfRemovedTrack()
        if (player.items.isEmpty()) forgetReportedTrack() else reportRemovedTrack(before)
        logicalPlaybackState.onQueueSizeChanged(player.items.size)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun removeUpcomingTracks() {
        if (!logicalPlaybackState.hasLogicalActiveItem(player.currentIndex)) return
        val before = player.items.toList()
        player.removeUpcomingItems()
        cancelCommandLoadOfRemovedTrack()
        reportRemovedTrack(before)
        logicalPlaybackState.onQueueSizeChanged(player.items.size)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun removePreviousTracks() {
        if (!logicalPlaybackState.hasLogicalActiveItem(player.currentIndex)) return
        val before = player.items.toList()
        player.removePreviousItems()
        cancelCommandLoadOfRemovedTrack()
        reportRemovedTrack(before)
        logicalPlaybackState.onQueueSizeChanged(player.items.size)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    override fun replace(index: Int, item: TrackAudioItem) {
        // New metadata for the same track: it keeps its place in the rule.
        player.items.getOrNull(index)?.let { failedLoads.replaced(it, item) }
        if (observedItem === player.items.getOrNull(index)) observedItem = item
        player.replaceItem(index, item)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    /** The track a command waits for left the queue: its wait ends cancelled. */
    private fun cancelCommandLoadOfRemovedTrack() {
        if (commandLoads.isWaiting && player.items.none { commandLoads.waitsFor(it) }) commandLoads.cancel()
    }

    override fun replaceQueue(items: List<TrackAudioItem>) {
        commandLoads.cancel()
        forgetReportedTrack()
        player.clear()
        player.add(items)
        logicalPlaybackState.onQueueSizeChanged(items.size)
        queueStore.replaceWith(items)
    }

    override fun clearQueue() {
        commandLoads.cancel()
        forgetReportedTrack()
        player.clear()
        logicalPlaybackState.onQueueCleared()
        queueStore.clear()
    }

    override suspend fun load(item: TrackAudioItem) {
        commandLoads.cancel()
        failedLoads.command()
        seekGate.cancel("load")
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            player.load(item)
            queueStore.replaceWith(player.items.map { it as TrackAudioItem })
        }
        awaitCommandLoad()
    }

    override suspend fun skip(index: Int) {
        if (index !in player.items.indices) {
            throw IndexOutOfBoundsException("The track index is out of bounds: $index")
        }
        commandLoads.cancel()
        seekGate.cancel("skip")
        failedLoads.command()
        runActivatingOperation(
            publishLogicalActivation = index == player.currentIndex
        ) { _ -> player.jumpToItem(index) }
        awaitCommandLoad()
    }
    override suspend fun skipToNext() {
        commandLoads.cancel()
        moveToNext()
        awaitCommandLoad()
    }
    private suspend fun moveToNext() {
        seekGate.cancel("skip")
        // After a failed load, next is relative to the active (previous) track, as iOS.
        // While a track loads or after it failed, next is relative to the active one, as iOS.
        if (failedLoads.isPending(player.currentItem)) {
            val active = reportedIndex()
            failedLoads.command()
            if (active >= 0 && active + 1 < player.items.size) {
                player.jumpToItem(active + 1)
                return
            }
        }
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
        commandLoads.cancel()
        moveToPrevious()
        awaitCommandLoad()
    }
    private fun moveToPrevious() {
        seekGate.cancel("skip")
        if (failedLoads.isPending(player.currentItem)) {
            val active = reportedIndex()
            failedLoads.command()
            if (active - 1 >= 0) {
                player.jumpToItem(active - 1)
                return
            }
        }
        player.previous()
    }
    // A waited seek with the same limits, as on iOS (it ends a seek in progress, as any seek).
    override suspend fun seekBy(offsetMs: Long) = seekTo(maxOf(0L, player.position + offsetMs))
    override suspend fun retry() {
        commandLoads.failureCleared()
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            loadActiveTrackAfterFailedLoad()
            player.prepare()
        }
    }
    override fun stop() {
        commandLoads.cancel()
        failedLoads.command()
        seekGate.cancel("stop")
        player.stop()
    }
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
            ?.let {
                failedLoads.published(player.currentItem)
                observedItem = player.currentItem
                onLogicalActiveItemActivated(it)
            }
    }
}

internal fun sameAudioItems(lhs: List<TrackAudioItem>, rhs: List<TrackAudioItem>): Boolean {
    return lhs.size == rhs.size && lhs.indices.all { lhs[it] === rhs[it] }
}

/**
 * The code an app sees for the standard player's error: the host's own code as is (a give-up,
 * [com.doublesymmetry.kotlinaudio.models.PlaybackError.fromHost]), ExoPlayer's prefixed `android-`.
 */
internal fun standardPlaybackErrorCode(error: com.doublesymmetry.kotlinaudio.models.PlaybackError): String? =
    if (error.fromHost) error.code else error.code?.let { "android-$it" }
