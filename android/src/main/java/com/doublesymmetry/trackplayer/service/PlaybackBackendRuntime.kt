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
import kotlinx.coroutines.withTimeoutOrNull

internal data class StandardPlaybackReadinessObservation(
    val state: AudioPlayerState,
    val currentIndex: Int,
    val positionMs: Long
)

internal object StandardPlaybackActivationSnapshotValidator {
    fun validate(snapshot: PlaybackBackendSnapshot) {
        if (snapshot.queueIds.isNotEmpty() && snapshot.activeIndex == null) {
            throw RejectionException(
                "The standard playback candidate requires an active track for a non-empty queue.",
                "playback_backend_activation_not_ready"
            )
        }
    }
}

internal class StandardPlaybackReadinessGate(
    private val timeoutMs: Long = 5_000L,
    private val pollIntervalMs: Long = 25L,
    private val positionToleranceMs: Long = 750L
) {
    init {
        require(timeoutMs > 0L)
        require(pollIntervalMs > 0L)
        require(positionToleranceMs >= 0L)
    }

    suspend fun await(
        expectedIndex: Int,
        expectedPositionMs: Long,
        observe: () -> StandardPlaybackReadinessObservation
    ) {
        val ready = withTimeoutOrNull(timeoutMs) {
            while (true) {
                val current = observe()
                if (current.state == AudioPlayerState.ERROR) throw notReadyError()
                val positionDelta = kotlin.math.abs(
                    current.positionMs.coerceAtLeast(0L) - expectedPositionMs.coerceAtLeast(0L)
                )
                if (current.state.isPreparedForActivation() &&
                    current.currentIndex == expectedIndex &&
                    positionDelta <= positionToleranceMs
                ) {
                    return@withTimeoutOrNull true
                }
                delay(pollIntervalMs)
            }
        }
        if (ready != true) throw notReadyError()
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
