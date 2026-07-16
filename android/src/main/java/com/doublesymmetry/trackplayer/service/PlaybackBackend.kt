package com.doublesymmetry.trackplayer.service

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class PlaybackBackendType {
    STANDARD,
    PING_PONG
}

data class PlaybackBackendSnapshot(
    val queueIds: List<String>,
    val activeIndex: Int?,
    val activeTrackId: String?,
    val positionMs: Long,
    val playWhenReady: Boolean,
    val volume: Float,
    val rate: Float,
    val repeatMode: Int,
    val transitionGeneration: Long
) {
    companion object {
        fun empty() = PlaybackBackendSnapshot(
            queueIds = emptyList(),
            activeIndex = null,
            activeTrackId = null,
            positionMs = 0,
            playWhenReady = false,
            volume = 1f,
            rate = 1f,
            repeatMode = 0,
            transitionGeneration = 0
        )
    }
}

data class PlaybackTransitionRequest(
    val durationMs: Long,
    val intervalMs: Long,
    val targetVolume: Float,
    val waitUntilMs: Long
)

data class PlaybackBackendTransactionResult(
    val backend: PlaybackBackendType,
    val operationId: Long,
    val snapshot: PlaybackBackendSnapshot
)

data class PlaybackBackendCleanupDiagnostic(
    val code: String = "playback_backend_cleanup_failed",
    val message: String = "The previous playback backend could not be fully disposed."
)

internal class PlaybackTransitionGenerationSidecar(initialGeneration: Long = 0L) {
    private var generation = initialGeneration.coerceAtLeast(0L)

    @Synchronized
    fun observe(observedGeneration: Long): Long {
        generation = maxOf(generation, observedGeneration.coerceAtLeast(0L))
        return generation
    }

    @Synchronized
    fun restore(snapshotGeneration: Long) {
        generation = maxOf(generation, snapshotGeneration.coerceAtLeast(0L))
    }

    @Synchronized
    fun current(): Long = generation
}

internal class AndroidPlaybackBackendAuthority(initialType: PlaybackBackendType? = null) {
    private data class Owner(val type: PlaybackBackendType, val identity: Any)

    @Volatile
    private var owner: Owner? = initialType?.let { Owner(it, it) }

    fun publish(backend: PlaybackBackend?) {
        owner = backend?.let { Owner(it.type, it.identity) }
    }

    fun clear() {
        owner = null
    }

    fun isAuthoritative(type: PlaybackBackendType, identity: Any): Boolean =
        owner?.let { it.type == type && it.identity === identity } == true

    fun currentType(): PlaybackBackendType? = owner?.type

    fun currentIdentity(): Any? = owner?.identity
}

internal class PlaybackControlOwnerRegistry {
    private var activeOwner: Any? = null
    private var maximumActiveCount = 0

    @Synchronized
    fun <T> activate(owner: Any, physicalActivation: () -> T): T {
        check(activeOwner == null || activeOwner === owner) {
            "Only one playback control surface may be active."
        }
        val result = physicalActivation()
        activeOwner = owner
        maximumActiveCount = maxOf(maximumActiveCount, activeCount())
        return result
    }

    @Synchronized
    fun activate(owner: Any) {
        activate(owner) { Unit }
    }

    @Synchronized
    fun deactivate(owner: Any, physicalDeactivation: () -> Unit) {
        if (activeOwner !== owner) return
        physicalDeactivation()
        activeOwner = null
    }

    @Synchronized
    fun deactivate(owner: Any) {
        deactivate(owner) { Unit }
    }

    @Synchronized
    fun activeCount(): Int = if (activeOwner == null) 0 else 1

    @Synchronized
    fun maximumActiveCount(): Int = maximumActiveCount
}

interface PlaybackBackend {
    val type: PlaybackBackendType
    val identity: Any
        get() = this
    suspend fun settleActiveTransition()
    suspend fun snapshot(): PlaybackBackendSnapshot
    suspend fun prepareSilently(snapshot: PlaybackBackendSnapshot)
    suspend fun restore(snapshot: PlaybackBackendSnapshot)
    suspend fun stopAndMute()
    suspend fun suspendControlSurface() = Unit
    suspend fun resumeControlSurface(snapshot: PlaybackBackendSnapshot) = Unit
    fun activateInitialControlSurface() = Unit
    fun relinquishExclusiveControlSurfaceBeforeCommit() = Unit
    /**
     * Publishes already-restored state after the facade swap. Implementations
     * must not throw: every fallible operation belongs before the commit point.
     */
    fun commitQueue(snapshot: PlaybackBackendSnapshot)
    fun activateAfterCommit(snapshot: PlaybackBackendSnapshot) = Unit
    suspend fun play()
    fun pause()
    suspend fun seekTo(positionMs: Long)
    suspend fun startTransition(request: PlaybackTransitionRequest)
    suspend fun dispose()
}

fun interface PlaybackBackendFactory {
    fun create(type: PlaybackBackendType): PlaybackBackend
}

internal class PlaybackBackendFacade(
    initialBackend: PlaybackBackend,
    private val factory: PlaybackBackendFactory,
    private val onCleanupDiagnostic: (PlaybackBackendCleanupDiagnostic) -> Unit = {},
    private val authority: AndroidPlaybackBackendAuthority = AndroidPlaybackBackendAuthority()
) {
    private val transactionMutex = Mutex()
    @Volatile
    private var backend = initialBackend
    private var nextOperationId = 0L

    init {
        initialBackend.activateInitialControlSurface()
        authority.publish(initialBackend)
    }

    fun currentBackend(): PlaybackBackend = backend

    suspend fun <T> withCurrentBackend(
        operation: suspend (PlaybackBackend) -> T
    ): T = transactionMutex.withLock {
        operation(backend)
    }

    suspend fun routeIfAuthoritative(
        expectedIdentity: Any,
        operation: suspend (PlaybackBackend) -> Unit
    ): Boolean = transactionMutex.withLock {
        val current = backend
        if (current.identity !== expectedIdentity ||
            !authority.isAuthoritative(current.type, expectedIdentity)
        ) return@withLock false
        operation(current)
        true
    }

    suspend fun setPlaybackBackend(type: PlaybackBackendType): PlaybackBackendTransactionResult =
        transactionMutex.withLock {
            nextOperationId += 1
            val operationId = nextOperationId
            val previous = backend

            previous.settleActiveTransition()
            val snapshot = previous.snapshot()
            if (previous.type == type) {
                return@withLock PlaybackBackendTransactionResult(type, operationId, snapshot)
            }

            previous.suspendControlSurface()
            authority.clear()
            val replacement = try {
                factory.create(type)
            } catch (error: Exception) {
                authority.publish(previous)
                resumeAuthoritativeControlSurface(previous, snapshot)
                throw error
            }
            try {
                replacement.prepareSilently(snapshot)
                replacement.restore(snapshot)
            } catch (error: Exception) {
                cleanupUncommitted(replacement)
                authority.publish(previous)
                restoreAuthoritativeBackend(previous, snapshot)
                resumeAuthoritativeControlSurface(previous, snapshot)
                throw error
            }

            try {
                previous.stopAndMute()
            } catch (error: Exception) {
                cleanupUncommitted(replacement)
                authority.publish(previous)
                restoreAuthoritativeBackend(previous, snapshot)
                resumeAuthoritativeControlSurface(previous, snapshot)
                throw error
            }

            try {
                previous.relinquishExclusiveControlSurfaceBeforeCommit()
            } catch (error: Exception) {
                cleanupUncommitted(replacement)
                authority.publish(previous)
                restoreAuthoritativeBackend(previous, snapshot)
                resumeAuthoritativeControlSurface(previous, snapshot)
                throw error
            }

            // Single commit point. Queue publication and activation are
            // deliberately non-throwing. Authority remains unpublished until
            // both have completed, so candidate callbacks cannot escape early.
            backend = replacement
            replacement.commitQueue(snapshot)
            replacement.activateAfterCommit(snapshot)
            authority.publish(replacement)

            try {
                previous.dispose()
            } catch (_: Exception) {
                onCleanupDiagnostic(PlaybackBackendCleanupDiagnostic())
            }

            PlaybackBackendTransactionResult(type, operationId, snapshot)
        }

    private suspend fun cleanupUncommitted(replacement: PlaybackBackend) {
        try {
            replacement.stopAndMute()
        } catch (_: Exception) {
            // The candidate was prepared silently and never became authoritative.
        }
        try {
            replacement.dispose()
        } catch (_: Exception) {
            // Pre-commit cleanup never changes the authoritative backend result.
        }
    }

    private suspend fun restoreAuthoritativeBackend(
        previous: PlaybackBackend,
        snapshot: PlaybackBackendSnapshot
    ) {
        try {
            previous.restore(snapshot)
            previous.commitQueue(snapshot)
        } catch (_: Exception) {
            // Preserve the original error and authoritative facade reference.
        }
    }

    private suspend fun resumeAuthoritativeControlSurface(
        previous: PlaybackBackend,
        snapshot: PlaybackBackendSnapshot
    ) {
        try {
            previous.resumeControlSurface(snapshot)
        } catch (_: Exception) {
            // Rollback keeps the old backend authoritative even if UI refresh fails.
        }
    }
}
