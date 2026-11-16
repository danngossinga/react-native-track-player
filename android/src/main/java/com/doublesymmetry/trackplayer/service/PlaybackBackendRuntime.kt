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
    private val positionToleranceMs: Long = 750L,
    /** A monotonic clock in milliseconds (tests pass their virtual time). */
    private val nowMs: () -> Long = ::monotonicNowMs
) {
    init {
        require(pollIntervalMs > 0L)
        require(positionToleranceMs >= 0L)
    }

    suspend fun await(
        expectedIndex: Int,
        expectedPositionMs: Long,
        observe: () -> StandardPlaybackReadinessObservation
    ) {
        var current: StandardPlaybackReadinessObservation? = null
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
                positionDelta <= positionToleranceMs
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
    val rate: Float = 1f
)

/**
 * Waits for a standard backend seek to complete, as iOS does: done once the player is no longer
 * loading or buffering and is at the target; fails when the buffered position does not grow for
 * `stallTimeoutMs`, or after `standardSeekTimeoutMs` in all (`standard_seek_timeout`). With no
 * item it fails at once (`standard_seek_unavailable`, also when the item fails to load); a newer
 * seek, a skip ([cancel]) or another item (an auto-advance) ends it at once
 * (`standard_seek_cancelled`), as on iOS. Main thread.
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
