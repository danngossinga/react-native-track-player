package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.trackplayer.utils.RejectionException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.selects.select

internal data class StandardPlaybackReadinessObservation(
    val state: AudioPlayerState,
    val currentIndex: Int,
    val positionMs: Long,
    /** The player's buffered position: its growth is the wait's progress. */
    val bufferedPositionMs: Long
)

internal object StandardPlaybackActivationSnapshotValidator {
    fun validate(snapshot: PlaybackBackendSnapshot) {
        val validIdle = snapshot.activeIndex == null &&
            snapshot.activeTrackId == null &&
            !snapshot.playWhenReady
        val activeIndex = snapshot.activeIndex
        val validActive = activeIndex != null &&
            activeIndex in snapshot.queueIds.indices &&
            snapshot.activeTrackId == snapshot.queueIds[activeIndex]
        if (!validIdle && !validActive) {
            throw RejectionException(
                "The standard playback candidate did not restore a coherent active track.",
                "playback_backend_activation_not_ready"
            )
        }
    }
}

internal class StandardPlaybackReadinessGate(
    /**
     * The app's `standardReadyTimeoutMs` (the total limit) and `stallTimeoutMs` (how long the
     * wait may go on with no progress), read at every wait (no defaults: the caller passes them).
     */
    private val timeoutMs: () -> Long,
    private val stallTimeoutMs: () -> Long,
    private val pollIntervalMs: Long = 25L,
    /** The app's `backendSwitchPositionToleranceMs`, read at every wait. */
    private val positionToleranceMs: () -> Long = { DEFAULT_BACKEND_SWITCH_POSITION_TOLERANCE_MS },
    /** A monotonic clock in milliseconds (tests pass their virtual time). */
    private val nowMs: () -> Long = ::monotonicNowMs
) {
    init {
        require(pollIntervalMs > 0L)
    }

    suspend fun await(
        expectedIndex: Int,
        expectedPositionMs: Long,
        observe: () -> StandardPlaybackReadinessObservation
    ) {
        var current: StandardPlaybackReadinessObservation? = null
        val toleranceMs = positionToleranceMs()
        val verdict = awaitWhileProgressing(
            stallTimeoutMs = stallTimeoutMs(),
            totalTimeoutMs = timeoutMs(),
            pollIntervalMs = pollIntervalMs,
            nowMs = nowMs,
            pause = { delay(it) },
            readings = { longArrayOf(current?.bufferedPositionMs ?: 0L) }
        ) {
            val observed = observe().also { current = it }
            if (observed.state == AudioPlayerState.ERROR) throw notReadyError()
            val positionDelta = kotlin.math.abs(
                observed.positionMs.coerceAtLeast(0L) - expectedPositionMs.coerceAtLeast(0L)
            )
            observed.state.isPreparedForActivation() &&
                observed.currentIndex == expectedIndex &&
                positionDelta <= toleranceMs
        }
        if (verdict != null) throw notReadyError()
    }

    private fun notReadyError() = RejectionException(
        "The standard playback candidate did not become ready before activation.",
        "playback_backend_activation_not_ready"
    )

    private fun AudioPlayerState.isPreparedForActivation(): Boolean = when (this) {
        AudioPlayerState.READY,
        AudioPlayerState.PAUSED,
        AudioPlayerState.PLAYING -> true
        else -> false
    }
}

internal data class StandardSeekObservation(
    val state: AudioPlayerState,
    val positionMs: Long,
    val bufferedPositionMs: Long,
    /** The track's duration (0 when unknown): a seek past the end lands at the end. */
    val durationMs: Long = 0L,
    /** The player's current item (compared by identity): another item cancels the seek. */
    val item: Any? = null,
    /** The playback speed: how far the position may have moved past the target since the seek. */
    val rate: Float = 1f,
    /** The player's automatic transitions so far (a track played to its end, repeat-one too). */
    val autoTransitions: Long = 0L
)

/**
 * Counts the standard player's automatic transitions (a track played to its end and the next
 * one, or the same with repeat-one, began): a seek to (or near) the end is done when one happens.
 */
internal class AutoTransitionCounter : com.google.android.exoplayer2.analytics.AnalyticsListener {
    @Volatile
    var count = 0L
        private set

    override fun onPositionDiscontinuity(
        eventTime: com.google.android.exoplayer2.analytics.AnalyticsListener.EventTime,
        oldPosition: com.google.android.exoplayer2.Player.PositionInfo,
        newPosition: com.google.android.exoplayer2.Player.PositionInfo,
        reason: Int
    ) {
        if (reason == com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_AUTO_TRANSITION) count += 1
    }
}

/**
 * Waits for a standard backend seek to complete, as iOS does: done once the player is no longer
 * loading or buffering and is at the target; fails when the buffered position does not grow for
 * `stallTimeoutMs`, or after `standardSeekTimeoutMs` in all (`standard_seek_timeout`). With no
 * item it fails at once (`standard_seek_unavailable`, also when the item fails to load); a newer
 * seek, a skip, a pause, a stop or a load ([cancel]), or another item without an automatic
 * transition, ends it at once (`standard_seek_cancelled`), as on iOS. An automatic transition
 * after the seek (the track played to its end: repeat-one, or the next track began) completes
 * it, as iOS's native seek completes. Main thread.
 */
internal class StandardSeekGate(
    private val timeoutMs: () -> Long,
    private val stallTimeoutMs: () -> Long,
    private val pollIntervalMs: Long = 25L,
    private val nowMs: () -> Long = ::monotonicNowMs
) {
    private var current: PlaybackOperationTicket? = null

    /**
     * At the target: no fixed tolerance. The position may be past the target by as much as
     * playback has played since the seek ([playedMs]), plus one poll; it may be before it by one
     * poll (a position read between two polls).
     */
    private fun isAtSeekTarget(positionMs: Long, targetMs: Long, playedMs: Long): Boolean {
        val slackMs = pollIntervalMs
        return positionMs >= targetMs - slackMs && positionMs <= targetMs + playedMs + slackMs
    }

    /** Ends the seek in progress, if any (`standard_seek_cancelled`). */
    fun cancel(reason: String) {
        current?.cancel(reason)
    }

    /** [item] is the player's item when the seek is issued (null: no active track). */
    suspend fun await(targetMs: Long, item: Any?, observe: () -> StandardSeekObservation) {
        current?.cancel("newer_seek")
        if (item == null) {
            throw RejectionException("No active track is available for seeking.", "standard_seek_unavailable")
        }
        val ticket = PlaybackOperationTicket(0L)
        current = ticket
        // How far playback may have moved the position since the seek: time spent playing, at
        // the observed rate.
        var playedMs = 0.0
        var lastCheckAt = nowMs()
        var transitionsAtStart: Long? = null
        var latest: StandardSeekObservation? = null
        val verdict = try {
            awaitWhileProgressing(
                stallTimeoutMs = stallTimeoutMs(),
                totalTimeoutMs = timeoutMs(),
                pollIntervalMs = pollIntervalMs,
                nowMs = nowMs,
                pause = { ticket.delayOrThrow(it) },
                readings = { longArrayOf(latest?.bufferedPositionMs ?: 0L) }
            ) {
                ticket.ensureActive()
                val observed = observe().also { latest = it }
                // The track played through the target to its end (repeat-one loops, or the next
                // track began): the seek is done, as on iOS where the native seek completed.
                val startTransitions = transitionsAtStart ?: observed.autoTransitions.also { transitionsAtStart = it }
                if (observed.autoTransitions > startTransitions) return@awaitWhileProgressing true
                val checkedAt = nowMs()
                if (observed.state == AudioPlayerState.PLAYING) {
                    playedMs += (checkedAt - lastCheckAt).coerceAtLeast(0L) * observed.rate.coerceAtLeast(0f).toDouble()
                }
                lastCheckAt = checkedAt
                if (observed.item !== item) throw PlaybackOperationCancelledException("item_changed")
                if (observed.state == AudioPlayerState.ERROR) {
                    throw RejectionException("The active track failed to load.", "standard_seek_unavailable")
                }
                val target = targetMs.coerceAtLeast(0L).let { if (observed.durationMs > 0L) minOf(it, observed.durationMs) else it }
                observed.state == AudioPlayerState.ENDED ||
                    (observed.state != AudioPlayerState.LOADING &&
                        observed.state != AudioPlayerState.BUFFERING &&
                        // Not loaded (stopped, never prepared): not at the target yet.
                        observed.state != AudioPlayerState.IDLE &&
                        isAtSeekTarget(observed.positionMs, target, playedMs.toLong()))
            }
        } catch (cancelled: PlaybackOperationCancelledException) {
            throw RejectionException("Playback changed before the native seek completed (${cancelled.reason}).", "standard_seek_cancelled")
        } finally {
            if (current === ticket) current = null
        }
        if (verdict != null) {
            throw RejectionException(
                if (verdict == StallVerdict.STALLED) "The native seek made no progress for ${stallTimeoutMs()} ms."
                else "The native seek did not complete within ${timeoutMs()} ms.",
                "standard_seek_timeout"
            )
        }
    }
}

/**
 * The standard player as a seek sees it. Its state is ExoPlayer's own: prepare and seekTo mask it
 * at once (to buffering), with the position already at the target, while KotlinAudio's state only
 * follows on a later message; read KotlinAudio's, the first check would find the old state at the
 * target and end the seek before it ran.
 */
internal interface StandardSeekPlayer {
    val currentItem: Any?
    /** KotlinAudio's state: set at once by stop() (its item unloaded), late after a seek. */
    val kotlinAudioState: AudioPlayerState
    /** ExoPlayer's own state, error and playing flag (masked at once by prepare and seekTo). */
    val exo: ExoSeekState
    val positionMs: Long
    val bufferedPositionMs: Long
    val durationMs: Long
    val rate: Float
    val autoTransitions: Long
    fun prepare()
    fun seekTo(positionMs: Long)
}

/** What a seek reads of ExoPlayer itself. */
internal interface ExoSeekState {
    /** `Player.STATE_*`. */
    val playbackState: Int
    val hasError: Boolean
    /** Playing now (ready and asked to play): the position moves past the target. */
    val isPlaying: Boolean
}

/** [ExoSeekState] of the captured ExoPlayer ([StandardPlayerAnalytics]; idle until there is one). */
internal class CapturedExoSeekState(private val captured: () -> com.google.android.exoplayer2.Player?) : ExoSeekState {
    private val player: com.google.android.exoplayer2.Player?
        get() = captured()

    override val playbackState: Int
        get() = player?.playbackState ?: com.google.android.exoplayer2.Player.STATE_IDLE
    override val hasError: Boolean
        get() = player?.playerError != null
    override val isPlaying: Boolean
        get() = player?.isPlaying == true
}

/** What a seek wait reads of [StandardSeekPlayer]. */
internal fun StandardSeekPlayer.seekObservation() = StandardSeekObservation(
    state = when {
        exo.hasError || kotlinAudioState == AudioPlayerState.ERROR -> AudioPlayerState.ERROR
        exo.playbackState == com.google.android.exoplayer2.Player.STATE_BUFFERING -> AudioPlayerState.BUFFERING
        exo.playbackState == com.google.android.exoplayer2.Player.STATE_ENDED -> AudioPlayerState.ENDED
        // Playing: the position moves on from the target while the wait polls (rate, late polls).
        exo.playbackState == com.google.android.exoplayer2.Player.STATE_READY && exo.isPlaying -> AudioPlayerState.PLAYING
        exo.playbackState == com.google.android.exoplayer2.Player.STATE_READY -> AudioPlayerState.READY
        else -> AudioPlayerState.IDLE
    },
    positionMs = positionMs,
    bufferedPositionMs = bufferedPositionMs,
    durationMs = durationMs.coerceAtLeast(0L),
    item = currentItem,
    rate = rate,
    autoTransitions = autoTransitions
)

/**
 * A standard seek, as on iOS: a stopped player loads its item again (paused) first; the seek is
 * issued, then waited for with [StandardSeekGate].
 */
internal suspend fun StandardSeekGate.seek(player: StandardSeekPlayer, positionMs: Long) {
    val item = player.currentItem
    if (item != null && player.kotlinAudioState == AudioPlayerState.STOPPED) player.prepare()
    if (item != null) player.seekTo(positionMs)
    await(positionMs, item) { player.seekObservation() }
}

/** What a standard restore does (iOS: the same rule). */
internal data class StandardRestoreSteps(val jump: Boolean, val seek: Boolean)

/**
 * A standard restore: a candidate (not authoritative), a changed queue or another index loads the
 * track again (jump) and seeks; on the same track, a position further off than
 * `backendSwitchPositionToleranceMs` is sought.
 */
internal fun standardRestoreSteps(
    isAuthoritative: Boolean,
    queueChanged: Boolean,
    currentIndex: Int,
    targetIndex: Int,
    positionMs: Long,
    targetPositionMs: Long,
    positionToleranceMs: Long
): StandardRestoreSteps {
    val jump = !isAuthoritative || queueChanged || currentIndex != targetIndex
    val seek = jump || kotlin.math.abs(positionMs - targetPositionMs) > positionToleranceMs
    return StandardRestoreSteps(jump = jump, seek = seek)
}

/**
 * Captures the standard player's ExoPlayer (ExoPlayer hands it to its analytics collector when
 * built), so a seek can read ExoPlayer's own state; KotlinAudio keeps its ExoPlayer private. The
 * player is held weakly: the service's map of these must not keep a released player alive.
 */
internal class StandardPlayerAnalytics(
    clock: com.google.android.exoplayer2.util.Clock = com.google.android.exoplayer2.util.Clock.DEFAULT
) : com.google.android.exoplayer2.analytics.DefaultAnalyticsCollector(clock) {
    @Volatile
    private var captured: java.lang.ref.WeakReference<com.google.android.exoplayer2.Player>? = null
    val player: com.google.android.exoplayer2.Player?
        get() = captured?.get()
    val transitions = AutoTransitionCounter()

    init {
        addListener(transitions)
    }

    override fun setPlayer(player: com.google.android.exoplayer2.Player, looper: android.os.Looper) {
        super.setPlayer(player, looper)
        captured = java.lang.ref.WeakReference(player)
    }

    override fun release() {
        captured = null
        super.release()
    }
}

internal class PlaybackOperationCancelledException(
    val reason: String
) : CancellationException("Playback operation was cancelled by $reason.")

internal class PlaybackOperationTicket internal constructor(
    internal val generation: Long
) {
    private val cancellation = CompletableDeferred<String>()
    private val cancellationCounter = AtomicInteger(0)
    private val cancellationReason = AtomicReference<String?>(null)

    val cancellationCount: Int
        get() = cancellationCounter.get()

    internal fun cancel(reason: String) {
        if (cancellationReason.compareAndSet(null, reason)) {
            cancellationCounter.incrementAndGet()
            cancellation.complete(reason)
        }
    }

    fun ensureActive() {
        cancellationReason.get()?.let { throw PlaybackOperationCancelledException(it) }
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    suspend fun delayOrThrow(durationMs: Long) {
        select<Unit> {
            onTimeout(durationMs.coerceAtLeast(0L)) { }
            cancellation.onAwait { throw PlaybackOperationCancelledException(it) }
        }
        ensureActive()
    }

}

internal class PlaybackOperationController {
    private var generation = 0L
    private var current: PlaybackOperationTicket? = null

    @Synchronized
    fun begin(): PlaybackOperationTicket {
        current?.cancel("superseded")
        generation += 1
        return PlaybackOperationTicket(generation).also { current = it }
    }

    @Synchronized
    fun invalidate(reason: String): PlaybackOperationTicket? {
        val invalidated = current
        invalidated?.cancel(reason)
        current = null
        return invalidated
    }

    @Synchronized
    fun isCurrent(ticket: PlaybackOperationTicket): Boolean = current === ticket

    @Synchronized
    fun finish(ticket: PlaybackOperationTicket) {
        if (current === ticket) current = null
    }
}

internal class PlaybackBackendQueueState<T>(initial: List<T> = emptyList()) {
    private var authoritativeValues = initial.toList()
    private var pendingValues = initial.toList()

    @Synchronized
    fun captureAuthoritative(values: List<T>) {
        authoritativeValues = values.toList()
    }

    @Synchronized
    fun stage(values: List<T>) {
        pendingValues = values.toList()
    }

    @Synchronized
    fun pending(): List<T> = pendingValues.toList()

    @Synchronized
    fun authoritative(): List<T> = authoritativeValues.toList()

    @Synchronized
    fun commit(): List<T> {
        authoritativeValues = pendingValues.toList()
        return authoritativeValues.toList()
    }

    @Synchronized
    fun rollback(): List<T> = authoritativeValues.toList()
}
