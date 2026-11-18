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

/**
 * Whether the standard player has an active track: one explicit state (rule 12, ADR 0042 form 3),
 * moved only by [after]. The same states and moves as iOS's `StandardActivity`
 * (PlaybackBackend.swift).
 */
internal enum class StandardActivity {
    /** A track is active: every reader reads the player. */
    ACTIVE,
    /** No active track (a restored snapshot with none, or a rolled-back activation): state IDLE. */
    IDLE,
    /**
     * No active track after a cancel stopped the player ([StandardActivityEvent.Cancelled]): its
     * state is the player's own (stopped, as its event says), not IDLE, so every reader agrees
     * with the state event the stop emitted (rule 13).
     */
    IDLE_FOLLOWING_PLAYER;

    val isIdle: Boolean get() = this != ACTIVE

    fun after(event: StandardActivityEvent): StandardActivity = when (event) {
        is StandardActivityEvent.Restored -> if (event.idle) IDLE else ACTIVE
        StandardActivityEvent.Activated -> ACTIVE
        // Back to idle; an idle state stays as it is.
        StandardActivityEvent.ActivationRolledBack -> if (this == ACTIVE) IDLE else this
        StandardActivityEvent.QueueEmptied -> ACTIVE
        // A restored idle stays one (its state IDLE), as iOS's queue change there. Unreachable on
        // Android (seventh review): Cancelled comes only from a cancel that stops in the idle
        // (leaveCancelledLoad, StopsInIdle), which needs a command waiting, and that command
        // activated the player first; kept so both platforms have the same table (iOS reaches it
        // through a queue change in a restored idle, StandardLoadCoordinator.queueChanged).
        StandardActivityEvent.Cancelled -> if (this == IDLE) IDLE else IDLE_FOLLOWING_PLAYER
    }
}

/** What moves [StandardActivity]; the same events as iOS's `StandardActivityEvent`. */
internal sealed class StandardActivityEvent {
    /** A backend snapshot restored: idle when its queue has tracks and none is active. */
    data class Restored(val idle: Boolean) : StandardActivityEvent()
    /** A play, skip, next or load selects a track. */
    object Activated : StandardActivityEvent()
    /** That selection failed: no active track again. */
    object ActivationRolledBack : StandardActivityEvent()
    /** The queue is empty: nothing to be idle on. */
    object QueueEmptied : StandardActivityEvent()
    /** A cancel stopped the player with no reported track, the queue staying. */
    object Cancelled : StandardActivityEvent()
}

internal class KotlinAudioLogicalPlaybackStateSidecar {
    var activity = StandardActivity.ACTIVE
        private set

    private fun move(event: StandardActivityEvent) {
        activity = activity.after(event)
    }

    fun restore(snapshot: PlaybackBackendSnapshot) {
        move(
            StandardActivityEvent.Restored(
                snapshot.queueIds.isNotEmpty() && (snapshot.activeIndex == null || snapshot.activeIndex < 0)
            )
        )
    }

    fun activate(): Boolean {
        val wasIdle = activity.isIdle
        move(StandardActivityEvent.Activated)
        return wasIdle
    }

    fun consumeIdleForNext(): Boolean = activate()

    fun shouldIgnorePrevious(): Boolean = activity.isIdle

    fun rollbackActivation(wasIdle: Boolean) {
        if (wasIdle) move(StandardActivityEvent.ActivationRolledBack)
    }

    fun hasLogicalActiveItem(physicalIndex: Int): Boolean =
        !activity.isIdle && physicalIndex >= 0

    fun onQueueCleared() {
        move(StandardActivityEvent.QueueEmptied)
    }

    /**
     * No active track any more (a cancelled load with none reported, the player stopped); the
     * queue stays. Its state is the player's ([StandardActivity.IDLE_FOLLOWING_PLAYER]).
     */
    fun enterIdle(queueSize: Int) {
        if (queueSize == 0) return
        move(StandardActivityEvent.Cancelled)
    }

    /** Whether no track is active (a play, skip or load selects one). */
    val isIdle: Boolean
        get() = activity.isIdle

    fun onQueueSizeChanged(queueSize: Int) {
        if (queueSize == 0) move(StandardActivityEvent.QueueEmptied)
    }

    fun currentIndex(physicalIndex: Int): Int =
        if (activity.isIdle) -1 else physicalIndex

    fun activeIndex(physicalIndex: Int, queueSize: Int): Int? =
        currentIndex(physicalIndex).takeIf { it in 0 until queueSize }

    fun playbackState(physicalState: AudioPlayerState): AudioPlayerState =
        if (activity == StandardActivity.IDLE) AudioPlayerState.IDLE else physicalState

    fun playWhenReady(physicalPlayWhenReady: Boolean): Boolean =
        !activity.isIdle && physicalPlayWhenReady

    fun positionMs(physicalPositionMs: Long): Long =
        if (activity.isIdle) 0L else physicalPositionMs

    fun durationMs(physicalDurationMs: Long): Long =
        if (activity.isIdle) 0L else physicalDurationMs

    fun bufferedMs(physicalBufferedMs: Long): Long =
        if (activity.isIdle) 0L else physicalBufferedMs
}

/**
 * What MusicService does with what the standard backend reports with no event of the player's
 * ([KotlinAudioPlaybackBackend]'s onReportedChanged: a failure's kept request, a seek holding the
 * player paused): the state event, the foreground rule's state, the play-when-ready event. One
 * function the service and the tests share (iOS: `StandardReadingEvents`).
 */
internal class StandardReportedSink(
    private val emitState: (AudioPlayerState) -> Unit,
    private val emitPlayWhenReady: (Boolean) -> Unit,
    private val foreground: StandardForegroundRule
) {
    fun changed(playWhenReady: Boolean?, state: AudioPlayerState?) {
        state?.let {
            emitState(it)
            foreground.stateChanged(it)
        }
        playWhenReady?.let(emitPlayWhenReady)
    }
}

/**
 * When MusicService lets the standard player's foreground service go, fed the state the app reads
 * ([KotlinAudioPlaybackBackend.reportedStateOf] of the player's events, and [StandardReportedSink]):
 * a seek holding the player paused reads LOADING, not the paused player's PAUSED, and its
 * notification is ongoing (ReportedSessionPlayer: buffering, play-when-ready), as crossfade's
 * surface stays in the foreground while it loads with playWhenReady. Only a notification that is
 * still not ongoing lets it go (a grace period's end after a give-up's error does not end the
 * foreground of the seek that followed). In a failure's error while its request is kept
 * ([playRequested], read live: the request the app reads) the foreground goes and the
 * notification stays, as crossfade's surface in ERROR (stopForegroundButKeepNotification); once
 * the request ended (a pause) the error removes it, and so does a stop, as crossfade's stop
 * (surface.hide()). Based on Pocket Casts' PlaybackService (MusicService.setupForegrounding).
 */
internal class StandardForegroundRule(
    /** The play request the app reads (the backend's playWhenReady, a failure's kept one included). */
    private val playRequested: () -> Boolean = { false }
) {
    /** What a notification that is not ongoing does to the foreground service. */
    enum class Release {
        /** Nothing: it stays (or is not one). */
        NONE,
        /** It goes; the notification stays (MusicService: stopForeground(false)). */
        KEEP_NOTIFICATION,
        /**
         * It goes with its notification (stopForeground(true)), which MusicService also cancels: one
         * an earlier [KEEP_NOTIFICATION] or pause left is no longer the foreground service's.
         */
        REMOVE_NOTIFICATION
    }

    private var stateCount = 0
    /** The last state that lets the foreground go (null: none, or the initial idle state). */
    private var settled: AudioPlayerState? = null
    /** Whether the notification last posted is ongoing. */
    private var ongoing = false

    /** The notification was posted ([ongoing]: PlayerNotificationManager's ongoing flag). */
    fun notificationPosted(ongoing: Boolean) {
        this.ongoing = ongoing
    }

    /** What happens to the foreground service now ([isForegroundService]: whether it is one). */
    fun release(isForegroundService: () -> Boolean): Release {
        val state = settled
        if (ongoing || state == null) return Release.NONE
        val removes = state in REMOVABLE_STATES && !(state == AudioPlayerState.ERROR && playRequested())
        return when {
            removes -> Release.REMOVE_NOTIFICATION
            isForegroundService() -> Release.KEEP_NOTIFICATION
            else -> Release.NONE
        }
    }

    fun stateChanged(state: AudioPlayerState) {
        stateCount++
        if (state in LOADING_STATES) return
        // The initial idle state is skipped: only a state after another counts.
        settled = state.takeIf { stateCount > 1 && it in BACKGROUNDABLE_STATES }
    }

    private companion object {
        val BACKGROUNDABLE_STATES = setOf(
            AudioPlayerState.IDLE,
            AudioPlayerState.ENDED,
            AudioPlayerState.STOPPED,
            AudioPlayerState.ERROR,
            AudioPlayerState.PAUSED
        )
        val REMOVABLE_STATES = setOf(AudioPlayerState.IDLE, AudioPlayerState.STOPPED, AudioPlayerState.ERROR)
        val LOADING_STATES = setOf(AudioPlayerState.LOADING, AudioPlayerState.READY, AudioPlayerState.BUFFERING)
    }
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
    /**
     * What the notification shows ([ReportedNowPlaying]): the reported track's index (null: the
     * player's own item), and whether the player's own updates are held (another track loads).
     */
    private val onNowPlaying: (index: Int?, held: Boolean) -> Unit = { _, _ -> },
    /**
     * What the app reads changed with no event of the player's ([StandardSeekResume]: a failure's
     * kept request, a seek holding the player paused): the new play-when-ready and state, each
     * null when unchanged. The player's own events are mapped by [reportedPlayWhenReadyOf] and
     * [reportedStateOf].
     */
    private val onReportedChanged: (playWhenReady: Boolean?, state: AudioPlayerState?) -> Unit = { _, _ -> },
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
    /** What the progress readers see: the reported track's (rule 13). */
    private val progress = ReportedTrackProgress()
    /** What the notification shows: the reported track (rule 13). */
    private val nowPlaying = ReportedNowPlaying()
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
        // No reported track: the notification and the media session read the player again.
        followNowPlaying()
    }

    private fun indexOfItem(item: Any?): Int? =
        item?.let { target -> player.items.indexOfFirst { it === target } }?.takeIf { it >= 0 }

    /** The track the app was told is active (-1: none, or it left the queue). */
    private fun reportedIndex(): Int = indexOfItem(failedLoads.reported) ?: -1
    // As crossfade: a failure keeps the play request and a seek after it reads LOADING while it
    // holds the player paused ([StandardSeekResume], rule 13: every reader and event agree).
    override val playbackState: AudioPlayerState
        get() = seekResume.reportedState(logicalPlaybackState.playbackState(player.playerState))
    override val playbackError: AndroidPlaybackErrorSnapshot?
        get() = player.playbackError?.let { error ->
            AndroidPlaybackErrorSnapshot(
                message = error.message,
                code = standardPlaybackErrorCode(error)
            )
        }
    override val playWhenReady: Boolean
        get() = logicalPlaybackState.playWhenReady(player.playWhenReady || seekResume.requestsPlay)

    /** The play-when-ready event the app gets for the player's own [playerPlayWhenReady] event. */
    fun reportedPlayWhenReadyOf(playerPlayWhenReady: Boolean): Boolean = playerPlayWhenReady || seekResume.requestsPlay

    /** The state event the app gets for the player's own [playerState] event. */
    fun reportedStateOf(playerState: AudioPlayerState): AudioPlayerState = seekResume.reportedState(playerState)

    /**
     * Runs [block], which may move [seekResume]; what the app reads that changed by that move is
     * published at once ([onReportedChanged]): the player may send no event (a pause of a player
     * a seek already holds paused). The player's own changes come with its own events (mapped by
     * [reportedPlayWhenReadyOf], [reportedStateOf]), not here. A command that takes a failure's
     * request over ([StandardSeekResume.handedToPlayer]) is not reported: it sets the player's own
     * request at once, so the app reads true throughout. iOS: StandardLoadCoordinator.reporting.
     */
    private inline fun <T> reporting(block: () -> T): T {
        val kindBefore = seekResume.kind
        try {
            return block()
        } finally {
            val kindAfter = seekResume.kind
            if (kindAfter != kindBefore) {
                val idle = logicalPlaybackState.isIdle
                val physical = logicalPlaybackState.playbackState(player.playerState)
                val playerPlayWhenReady = player.playWhenReady
                val playWhenReadyBefore = !idle && (playerPlayWhenReady || StandardSeekResume.requestsPlay(kindBefore))
                val playWhenReadyAfter = !idle && (playerPlayWhenReady || StandardSeekResume.requestsPlay(kindAfter))
                val stateBefore = StandardSeekResume.reportedState(kindBefore, physical)
                val stateAfter = StandardSeekResume.reportedState(kindAfter, physical)
                if (playWhenReadyAfter != playWhenReadyBefore || stateAfter != stateBefore) {
                    onReportedChanged(
                        playWhenReadyAfter.takeIf { it != playWhenReadyBefore },
                        stateAfter.takeIf { it != stateBefore }
                    )
                }
                // The media session and the notification read the same values
                // (ReportedSessionPlayer.requestKept, seekHolds): told at once.
                analytics()?.sessionPlayer?.refresh()
            }
        }
    }
    // The reported track's progress, as currentIndex (rule 13): while another track loads, the
    // reported one's as the player left it (ReportedTrackProgress).
    override val positionMs: Long
        get() = reportedProgress().positionMs
    override val durationMs: Long
        get() = reportedProgress().durationMs
    override val bufferedMs: Long
        get() = reportedProgress().bufferedMs

    /** The player's own item's progress (a seek, a backend switch's snapshot act on that item). */
    private fun liveProgress() = TrackProgress(
        logicalPlaybackState.positionMs(player.position),
        logicalPlaybackState.durationMs(player.duration),
        logicalPlaybackState.bufferedMs(player.bufferedPosition)
    )

    private fun reportedProgress(): TrackProgress = progress.read(failedLoads.reported, player.currentItem, liveProgress())
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
        // The active track the app reads and its position (rule 13), as iOS: while another track
        // loads or after its load failed, the reported one at its last position (before: the
        // player's own item, which a switch then loaded, and the carried request played).
        val index = currentIndex.takeIf { it in queue.indices }
        return PlaybackBackendSnapshot(
            queueIds = queue.map { it.track.queueId.toString() },
            activeIndex = index,
            activeTrackId = index?.let { queue[it].track.queueId.toString() },
            positionMs = reportedProgress().positionMs.coerceAtLeast(0L),
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
        // A snapshot with tracks and no active one (the logical idle): the player loads nothing,
        // so no queue change loads either (an idle ExoPlayer stays idle), as iOS and crossfade.
        val idle = queue.isNotEmpty() && (snapshot.activeIndex == null || snapshot.activeIndex < 0)
        if (!isAuthoritative || queueChanged) {
            player.stop()
            player.clear()
            if (idle) player.addWithoutPreparing(queue, null) else player.add(queue)
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

    /** The player's own play-when-ready before [beginHandoffQuiescence], for its rollback. */
    private var quiescedPlayerPlayWhenReady: Boolean? = null

    override suspend fun beginHandoffQuiescence(): PlaybackBackendSnapshot {
        settleActiveTransition()
        // The request the app reads goes to the new backend (a failure's kept one included, as
        // crossfade's snapshot carries its playWhenReady; before: the player's own, false); the
        // new backend hands it to its player (activateAfterCommit). iOS: the same.
        val logicalPlayWhenReady = playWhenReady
        quiescedPlayerPlayWhenReady = player.playWhenReady
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
        // Back as it was: the player's own request, not the carried one (a kept request stays
        // kept, StandardSeekResume unchanged: a stopped or held player does not start).
        val playerPlayWhenReady = quiescedPlayerPlayWhenReady ?: snapshot.playWhenReady
        quiescedPlayerPlayWhenReady = null
        player.volume = snapshot.volume
        player.playWhenReady = playerPlayWhenReady
        if (playerPlayWhenReady) player.play() else player.pause()
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
        // The hand-off: the carried request (the previous backend's, a failure's kept one
        // included) is this player's own from now on (a new backend keeps nothing:
        // StandardSeekResume NONE), so it plays the restored track.
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
        // No production caller (the facade rolls back with cancelHandoffQuiescence); aligned with
        // it, as iOS: back as it was, the player's own request (a kept one stays kept), not the
        // carried one, which activateAfterCommit would play.
        isAuthoritative = true
        queueStore.replaceWith(queueState.rollback())
        onCommitted(player)
        cancelHandoffQuiescence(snapshot)
        resumeControlSurface(snapshot)
    }

    override suspend fun play() {
        // A new load: a failure of it no command waits for is reported again.
        commandLoads.failureCleared()
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            loadActiveTrackAfterFailedLoad()
            // The player's request is the request again (a failure's kept one included).
            seekResume.handedToPlayer()
            player.play()
        }
    }
    override fun pause() = reporting {
        // A pause ends the play request a failure kept, and a seek holding the player paused.
        seekResume.paused()
        // As iOS (cancelPendingSeeks): a pause, stop, load or relative seek ends a seek in progress.
        seekGate.cancel("pause")
        // As crossfade's pause: a skip or load still waiting ends cancelled and does not take effect.
        leaveCancelledLoad(commandLoads.cancel(), positionMs = null)
        player.pause()
    }
    override suspend fun seekTo(positionMs: Long) {
        // A newer command, as a crossfade seek: a skip or load still waiting ends cancelled, and
        // does not take effect: the seek acts on the active track, also after a failed skip and
        // while a natural advance loads (owner decision, 2026-11-17, LOAD-06).
        val cancelledWait = commandLoads.cancel()
        // After a failed load the seek goes back to the active track and plays there when
        // playback was requested before the failure, as crossfade's seek after a failed skip (its
        // failure keeps playWhenReady; a give-up stops this player's, kept here).
        // The player goes back paused and plays once the latest seek is done, as iOS (SwiftAudioEx
        // issues a seek once the item loaded); any number of seeks in a row (a scrubber drag) keep
        // that request ([StandardSeekResume]).
        // A failure kept the request (a give-up's error, a failed seek, a seek in progress): the
        // seek holds the player paused and plays once done, also on the track the player is on
        // (a seek after a seek that gave up, as crossfade's seek after a failure).
        val afterFailedLoad = failedLoads.phase is FailedLoadRule.Phase.Failed
        val playerPlaying = player.playWhenReady
        failedLoads.command()
        val seek = reporting {
            val left = leaveCancelledLoad(cancelledWait, positionMs, actsOnReportedTrack = true)
            seekResume.seekBegan(
                returnsToActiveTrack = left is StandardCancelledLoad.ReturnsTo,
                afterFailedLoad = afterFailedLoad,
                cancelledWait = cancelledWait,
                playerPlaying = playerPlaying
            )
        }
        // No active track (none reported when the cancel stopped the load, or a logical idle):
        // nothing to seek in, nothing loads, and the seek resolves, as crossfade's seek with no
        // active track (nothing to resume either).
        if (logicalPlaybackState.isIdle) {
            reporting { seekResume.seekEnded(seek, succeeded = false) }
            seekGate.cancel("seek")
            return
        }
        var succeeded = false
        try {
            // As a crossfade seek that gives up: the player stops loading and is in error.
            seekGate.seekOrGiveUp(seekPlayer, positionMs) { error ->
                androidXfadeLog("standard load abandoned (seek ${error.message}) positionMs=${player.position}")
                reporting {
                    seekResume.gaveUp(playing = player.playWhenReady)
                    player.failLoad(PlaybackError(error.code, error.message, fromHost = true), report = false)
                }
                // Its track failed (again): the next play loads the active track, as after a failed
                // load (FailedLoadRule.failed changes nothing on the loaded track).
                failLoadedTrack()
            }
            succeeded = true
        } catch (error: RejectionException) {
            // The seek found its track failed to load (a player error): it stays failed.
            if (error.code == STANDARD_SEEK_UNAVAILABLE_CODE && player.currentItem != null) failLoadedTrack()
            throw error
        } finally {
            // After a failure the latest seek plays once done, as requested; one that failed keeps
            // the request (iOS: StandardLoadCoordinator.seekFinished).
            reporting {
                if (seekResume.seekEnded(seek, succeeded) && !disposed && !playerReleased) player.play()
            }
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
        // The media session reads the reported track (its index) while held, and a give-up's
        // error (ReportedSessionPlayer, rule 13), live.
        collector.sessionPlayer?.let { session ->
            session.reportedIndex = { reportedIndex().takeIf { it >= 0 } }
            session.hostError = ::hostSessionError
            // The play request and the state the app reads (StandardSeekResume, rule 13).
            session.requestKept = { !logicalPlaybackState.isIdle && seekResume.requestsPlay }
            session.seekHolds = {
                seekResume.kind == StandardSeekResume.Kind.RESUMES_AFTER_SEEK &&
                    playbackState == AudioPlayerState.LOADING
            }
        }
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
                if (oldPosition.mediaItemIndex != newPosition.mediaItemIndex) {
                    lastItemPositionMs = oldPosition.positionMs
                    progress.left(player.items.getOrNull(oldPosition.mediaItemIndex), oldPosition.positionMs)
                }
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
            .also {
                // At every player event: the reported track's progress is kept while the player
                // is on it, and the notification follows the reported track.
                reportedProgress()
                followNowPlaying()
            }
    }

    /**
     * The notification shows the reported track ([ReportedNowPlaying]); only the authoritative
     * backend's. While held, the media session and the notification also read the reported
     * track's progress, not playing ([ReportedSessionPlayer], rule 13; iOS: the lock screen at its
     * last position, rate 0), set before the notification is told to show it.
     */
    private fun followNowPlaying() {
        if (!isAuthoritative || disposed || playerReleased) return
        val change = nowPlaying.follow(failedLoads.reported, player.currentItem)
        analytics()?.sessionPlayer?.hold(if (nowPlaying.isHeld) reportedProgress() else null)
        change?.let { onNowPlaying(indexOfItem(it.item), it.held) }
    }

    /**
     * The play request a failure keeps ([StandardSeekResume]: kept by a give-up ([giveUpLoad], a
     * seek's), whose stop ends ExoPlayer's play-when-ready, or a failed resuming seek; resumed once
     * the latest seek is done, or by the next command that loads a track). A pause or stop ends
     * it. iOS: the same, in StandardLoadCoordinator.
     */
    private val seekResume = StandardSeekResume()

    /** The player is in a give-up's error (until the next command). */
    private fun isInGiveUp(): Boolean = player.playbackError?.fromHost == true && player.playerState == AudioPlayerState.ERROR

    /** The give-up the player is in (a load or seek the host gave up), as an ExoPlayer error. */
    private var hostSessionErrorOf: Pair<PlaybackError, com.google.android.exoplayer2.PlaybackException>? = null

    private fun hostSessionError(): com.google.android.exoplayer2.PlaybackException? {
        if (!isInGiveUp()) return null
        val error = player.playbackError ?: return null
        hostSessionErrorOf?.let { (of, exception) -> if (of === error) return exception }
        return com.google.android.exoplayer2.PlaybackException(error.message, null, com.google.android.exoplayer2.PlaybackException.ERROR_CODE_TIMEOUT)
            .also { hostSessionErrorOf = error to it }
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
        followNowPlaying()
    }

    private fun report(change: FailedLoadRule.Report, lastIndex: Int? = indexOfItem(change.from)) {
        val lastItem = change.from as? TrackAudioItem
        onActiveTrackChanged(indexOfItem(change.to), lastIndex, lastItem, lastItemPositionMs)
        followNowPlaying()
    }

    /**
     * The reported track left the queue: no active track, reported at once (as the crossfade
     * path's queue change); the player's next track is reported once it loaded.
     */
    private fun reportRemovedTrack(before: List<Any?>) {
        val reported = failedLoads.reported ?: return
        if (indexOfItem(reported) != null) return
        activeTrackRemoved()
        val lastIndex = before.indexOfFirst { it === reported }.takeIf { it >= 0 }
        failedLoads.removed(reported)?.let { report(it, lastIndex) }
    }

    /**
     * The active track left the queue: the request a failure kept ends, reported, as crossfade's
     * queue change without the active track (its playWhenReady false); iOS: the same
     * (StandardLoadCoordinator.activeTrackRemoved).
     */
    private fun activeTrackRemoved() {
        reporting { seekResume.paused() }
    }

    /**
     * A seek, pause or stop that cancelled a command's wait while its track loads
     * ([standardCancelledLoad]): the cancelled command does not take effect, as crossfade's
     * operation cancelled while it loads, and its track is never reported.
     * - Back to the reported track, paused (after a failed load a seek then plays once done, when
     *   playback was asked to: [StandardSeekResume]), at [positionMs]
     *   (null: where the player left that track); the cancelled track's source is released (ExoPlayer would keep it prepared while
     *   its item is in the playlist, and an HLS source would go on fetching its playlists), so
     *   nothing of it loads any more, as iOS (the asset's loading cancelled) and crossfade.
     * - None reported: the player stops (which releases every source: nothing of the cancelled
     *   track loads any more) and has no active track (logical idle, crossfade's active index -1).
     */
    private fun leaveCancelledLoad(
        cancelledWait: Boolean,
        positionMs: Long?,
        actsOnReportedTrack: Boolean = false
    ): StandardCancelledLoad {
        val left = standardCancelledLoad(cancelledWait, player.currentItem, failedLoads.reported, actsOnReportedTrack)
        when (left) {
            StandardCancelledLoad.Stays -> Unit
            is StandardCancelledLoad.ReturnsTo -> {
                val index = indexOfItem(left.item) ?: return StandardCancelledLoad.Stays
                val position = positionMs ?: reportedProgress().positionMs
                val cancelled = player.currentIndex
                // Paused (a cancelled operation; after a failed load a seek plays once done:
                // [StandardSeekResume]), as iOS.
                player.jumpToItem(index, playWhenReady = false)
                player.seek(position, TimeUnit.MILLISECONDS)
                // Its source is released: nothing of the cancelled track loads any more, not even
                // a playlist (as iOS and crossfade, whose engine drops it).
                player.releaseSource(cancelled)
            }
            StandardCancelledLoad.StopsInIdle -> {
                player.stop()
                logicalPlaybackState.enterIdle(player.items.size)
            }
        }
        return left
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
        reporting {
            seekResume.gaveUp(playing = player.playWhenReady)
            player.failLoad(
                PlaybackError(PREPARE_TIMEOUT_CODE, message, fromHost = true),
                report = !commandLoads.waitsFor(item)
            )
        }
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
                when {
                    it == AudioPlayerState.ERROR && player.playbackError?.fromHost == true -> AudioPlayerState.STOPPED
                    // An ExoPlayer error ExoPlayer no longer has (prepared again: a seek that went
                    // back to the active track after a failed skip): KotlinAudio's state follows a
                    // message later.
                    it == AudioPlayerState.ERROR && analytics()?.player?.let { exo ->
                        exo.playerError == null && exo.playbackState != com.google.android.exoplayer2.Player.STATE_IDLE
                    } == true -> AudioPlayerState.BUFFERING
                    else -> it
                }
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
        // A new queue's first track is selected, and loads (LOAD-07). Otherwise adding loads
        // nothing, as crossfade's queue change: a player with no active track (the logical idle),
        // stopped, or failed stays as it is (upstream's add prepares the player, which loads its
        // current item: a cancelled skip's track, a failed one).
        if (player.items.isEmpty()) {
            if (atIndex == null) player.add(items) else player.add(items, atIndex)
        } else {
            player.addWithoutPreparing(items, atIndex)
        }
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
        if (player.items.isEmpty()) {
            // Every track left, the active one with them.
            activeTrackRemoved()
            forgetReportedTrack()
        } else {
            reportRemovedTrack(before)
        }
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
        player.items.getOrNull(index)?.let {
            failedLoads.replaced(it, item)
            progress.replaced(it, item)
        }
        if (observedItem === player.items.getOrNull(index)) observedItem = item
        player.replaceItem(index, item)
        queueStore.replaceWith(player.items.map { it as TrackAudioItem })
    }

    /** The track a command waits for left the queue: its wait ends cancelled. */
    private fun cancelCommandLoadOfRemovedTrack() {
        if (commandLoads.isWaiting && player.items.none { commandLoads.waitsFor(it) }) commandLoads.cancel()
    }

    override fun replaceQueue(items: List<TrackAudioItem>) {
        // A failure's kept request plays the new queue's first track (as a skip's). Not reported:
        // the player's own request is set at once (a command that takes the request over reads
        // true throughout; the new track's states are the player's events). An empty queue has
        // no track to play: the request ends, reported (as crossfade's setQueue with no active
        // track, and a clear), so the getter and the event agree (rule 13).
        // Handed over only once the player's own request is set (below): the session reads the
        // kept one meanwhile, never false (forgetReportedTrack and the clear tell it at once).
        val takesOver = items.isNotEmpty()
        val kept = takesOver && seekResume.requestsPlay
        reporting {
            if (items.isEmpty()) seekResume.paused()
            commandLoads.cancel()
            forgetReportedTrack()
            player.clear()
            // With no active track (the logical idle) a new queue has none either and loads nothing,
            // as crossfade's setQueue with no active track: the next play, skip or load selects one.
            // Otherwise its first track is selected (LOAD-07).
            if (logicalPlaybackState.isIdle) {
                player.addWithoutPreparing(items, null)
            } else {
                player.add(items)
                if (kept && items.isNotEmpty()) player.playWhenReady = true
            }
            logicalPlaybackState.onQueueSizeChanged(items.size)
            queueStore.replaceWith(items)
        }
        if (takesOver) seekResume.handedToPlayer()
        // The new queue ended a give-up's error, the request is the player's: the session is told.
        analytics()?.sessionPlayer?.refresh()
    }

    override fun clearQueue() {
        reporting {
            // As crossfade's clear (its stop): the request a failure kept ends.
            seekResume.paused()
            commandLoads.cancel()
            forgetReportedTrack()
            player.clear()
            logicalPlaybackState.onQueueCleared()
            queueStore.clear()
            // Clearing the queue ended a give-up's error: the media session is told.
            analytics()?.sessionPlayer?.refresh()
        }
    }

    override suspend fun load(item: TrackAudioItem) {
        commandLoads.cancel()
        failedLoads.skipped()
        // A failure's kept request plays the loaded track (as a skip's).
        val kept = seekResume.handedToPlayer()
        seekGate.cancel("load")
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            player.load(item)
            if (kept) player.playWhenReady = true
            queueStore.replaceWith(player.items.map { it as TrackAudioItem })
        }
        awaitCommandLoad()
    }

    override suspend fun skip(index: Int) {
        if (index !in player.items.indices) {
            throw IndexOutOfBoundsException("The track index is out of bounds: $index")
        }
        commandLoads.cancel()
        // As crossfade's skip (wasPlaying read before it cancels a seek): a failure's kept
        // request plays the new track (seventh review, 1).
        val kept = seekResume.handedToPlayer()
        seekGate.cancel("skip")
        failedLoads.skipped()
        runActivatingOperation(
            publishLogicalActivation = index == player.currentIndex
        ) { _ ->
            player.jumpToItem(index)
            if (kept) player.playWhenReady = true
        }
        awaitCommandLoad()
    }
    override suspend fun skipToNext() {
        commandLoads.cancel()
        val kept = seekResume.handedToPlayer()
        moveToNext()
        if (kept) player.playWhenReady = true
        awaitCommandLoad()
    }
    private suspend fun moveToNext() {
        seekGate.cancel("skip")
        // After a failed load, next is relative to the active (previous) track, as iOS.
        // While a track loads or after it failed, next is relative to the active one, as iOS.
        if (failedLoads.isPending(player.currentItem)) {
            val active = reportedIndex()
            failedLoads.skipped()
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
            activateCurrentPhysicalItem(publish = true)
            return
        }
        player.next()
    }
    override suspend fun skipToPrevious() {
        if (logicalPlaybackState.shouldIgnorePrevious()) return
        commandLoads.cancel()
        val kept = seekResume.handedToPlayer()
        moveToPrevious()
        if (kept) player.playWhenReady = true
        awaitCommandLoad()
    }
    private fun moveToPrevious() {
        seekGate.cancel("skip")
        if (failedLoads.isPending(player.currentItem)) {
            val active = reportedIndex()
            failedLoads.skipped()
            if (active - 1 >= 0) {
                player.jumpToItem(active - 1)
                return
            }
        }
        player.previous()
    }
    // A waited seek with the same limits, as on iOS (it ends a seek in progress, as any seek),
    // relative to the position the app reads (rule 13: the reported track's, also while another
    // track loads; the seek then acts on the reported track, the skip cancelled), as crossfade's.
    override suspend fun seekBy(offsetMs: Long) = seekTo(maxOf(0L, positionMs + offsetMs))
    override suspend fun retry() {
        commandLoads.failureCleared()
        runActivatingOperation(publishLogicalActivation = true) { wasIdle ->
            if (wasIdle) selectFirstPhysicalItemIfNeeded()
            loadActiveTrackAfterFailedLoad()
            // A failure's kept request plays the track the retry loads.
            if (seekResume.handedToPlayer()) player.playWhenReady = true
            player.prepare()
        }
    }
    override fun stop() {
        reporting {
            seekResume.paused()
            val cancelledWait = commandLoads.cancel()
            failedLoads.command()
            seekGate.cancel("stop")
            // As crossfade's stop: a skip or load still waiting does not take effect, and after a
            // failed skip the player stops on the active track (owner decision, 2026-11-17, LOAD-06).
            leaveCancelledLoad(cancelledWait, positionMs = null, actsOnReportedTrack = true)
            player.stop()
            // The stop ended a give-up's error: the media session is told (no player event follows).
            analytics()?.sessionPlayer?.refresh()
        }
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
        if (wasIdle) activateCurrentPhysicalItem(publishLogicalActivation)
    }

    /**
     * A command with no active track (the logical idle) activated the player's item: it loads and
     * is reported once it loaded, as crossfade's play with no active track (never a track that
     * fails to load; FailedLoadRule.activating). With no load watch (nothing tells when it loaded)
     * it is published at once ([publish]: the play, retry, load and next that select it).
     */
    private fun activateCurrentPhysicalItem(publish: Boolean) {
        val index = player.currentIndex.takeIf { it in player.items.indices } ?: return
        if (loadDriver != null) {
            failedLoads.activating(player.currentItem)
            observedItem = player.currentItem
            followNowPlaying()
        } else if (publish) {
            failedLoads.published(player.currentItem)
            observedItem = player.currentItem
            onLogicalActiveItemActivated(index)
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
