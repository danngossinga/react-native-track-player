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
    val durationMs: Long = 0L
)

/**
 * Waits for a standard backend seek to complete, as iOS does: done once the player is no longer
 * loading or buffering and is at the target; fails when the buffered position does not grow for
 * `stallTimeoutMs`, or after `standardSeekTimeoutMs` in all (`standard_seek_timeout`).
 */
internal class StandardSeekGate(
    private val timeoutMs: () -> Long,
    private val stallTimeoutMs: () -> Long,
    private val pollIntervalMs: Long = 25L,
    private val positionToleranceMs: Long = 750L,
    private val nowMs: () -> Long = ::monotonicNowMs
) {
    suspend fun await(targetMs: Long, observe: () -> StandardSeekObservation) {
        var current: StandardSeekObservation? = null
        val verdict = awaitWhileProgressing(
            stallTimeoutMs = stallTimeoutMs(),
            totalTimeoutMs = timeoutMs(),
            pollIntervalMs = pollIntervalMs,
            nowMs = nowMs,
            pause = { delay(it) },
            readings = { longArrayOf(current?.bufferedPositionMs ?: 0L) }
        ) {
            val observed = observe().also { current = it }
            if (observed.state == AudioPlayerState.ERROR) {
                throw RejectionException("The active track failed to load.", "standard_seek_unavailable")
            }
            val target = targetMs.coerceAtLeast(0L).let { if (observed.durationMs > 0L) minOf(it, observed.durationMs) else it }
            observed.state == AudioPlayerState.ENDED ||
                (observed.state != AudioPlayerState.LOADING &&
                    observed.state != AudioPlayerState.BUFFERING &&
                    kotlin.math.abs(observed.positionMs - target) <= positionToleranceMs)
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
