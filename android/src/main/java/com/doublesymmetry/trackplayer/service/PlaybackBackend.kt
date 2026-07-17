package com.doublesymmetry.trackplayer.service

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.doublesymmetry.trackplayer.utils.RejectionException
import java.util.concurrent.atomic.AtomicBoolean

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
        val wasActiveOwner = activeOwner === owner
        try {
            // Cleanup is an object-lifetime operation, not an ownership
            // operation. A stale backend must still destroy its own physical
            // surface after a replacement has become the registry owner.
            physicalDeactivation()
        } finally {
            if (wasActiveOwner && activeOwner === owner) {
                activeOwner = null
            }
        }
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
    /** Fallible readiness work. Must keep the candidate muted and unobservable. */
    suspend fun prepareActivation(snapshot: PlaybackBackendSnapshot) = Unit
    /**
     * Settles transitions and atomically pauses/mutes playback without clearing
     * the active item. The returned snapshot preserves the logical PWR/volume
     * that must be transferred or resumed.
     */
    suspend fun beginHandoffQuiescence(): PlaybackBackendSnapshot
    /** Reverses [beginHandoffQuiescence] without rebuilding the queue/player. */
    suspend fun cancelHandoffQuiescence(snapshot: PlaybackBackendSnapshot)
    suspend fun stopAndMute()
    suspend fun suspendControlSurface() = Unit
    suspend fun resumeControlSurface(snapshot: PlaybackBackendSnapshot) = Unit
    fun activateInitialControlSurface() = Unit
    fun relinquishExclusiveControlSurfaceBeforeCommit() = Unit
    /**
     * Finalizes already-restored state immediately before facade pointer
     * publication. Implementations must not throw: every fallible operation
     * belongs before the commit point.
     */
    fun commitQueue(snapshot: PlaybackBackendSnapshot)
    /** Non-failing publication of state already validated by prepareActivation. */
    suspend fun activateAfterCommit(snapshot: PlaybackBackendSnapshot) = Unit
    /** Reactivates the existing authoritative state without publishing candidate staging. */
    suspend fun reactivateAfterRollback(snapshot: PlaybackBackendSnapshot) = activateAfterCommit(snapshot)
    suspend fun play()
    fun pause()
    suspend fun seekTo(positionMs: Long)
    suspend fun startTransition(request: PlaybackTransitionRequest)
    suspend fun dispose()
}

fun interface PlaybackBackendFactory {
    suspend fun create(type: PlaybackBackendType, identity: Any): PlaybackBackend
}

internal class PhysicalRemoteTicket internal constructor(
    internal val sourceIdentity: Any,
    internal val backendGeneration: Long,
    internal val handoff: Any?
) {
    internal val consumed = AtomicBoolean(false)
}

internal class PlaybackBackendFacade(
    initialBackend: PlaybackBackend,
    private val factory: PlaybackBackendFactory,
    private val onCleanupDiagnostic: (PlaybackBackendCleanupDiagnostic) -> Unit = {},
    private val authority: AndroidPlaybackBackendAuthority = AndroidPlaybackBackendAuthority(),
    private val diagnosticScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
) {
    private data class VersionedSnapshot(
        val snapshot: PlaybackBackendSnapshot,
        val version: Long
    )

    private sealed class SnapshotDecision {
        data class Captured(val value: VersionedSnapshot) : SnapshotDecision()
        data class Wait(val signal: Deferred<Unit>) : SnapshotDecision()
    }

    private sealed class CommitDecision {
        data class Failed(val error: Exception) : CommitDecision()
        data class Ready(val physicalHandoff: PhysicalHandoffState) : CommitDecision()
    }

    private sealed class BackendLeaseDecision {
        data class Captured(val backend: PlaybackBackend) : BackendLeaseDecision()
        data class Wait(val signal: Deferred<Unit>) : BackendLeaseDecision()
        object Rejected : BackendLeaseDecision()
    }

    private class PhysicalHandoffState(
        val signal: CompletableDeferred<Unit>,
        val previousGeneration: Long,
        val previousRemoteSource: Any?,
        val candidateRemoteSource: Any?
    ) {
        val acceptedRemoteSources = listOfNotNull(previousRemoteSource, candidateRemoteSource)
        var resultGeneration: Long? = null
        var committed = false
    }

    private val admissionMutex = Mutex()
    private val swapMutex = Mutex()
    @Volatile
    private var backend = initialBackend
    private var nextOperationId = 0L
    private var commandVersion = 0L
    private var activeCommandLeases = 0
    private var leaseDrainSignal = CompletableDeferred(Unit)
    private var physicalHandoff: PhysicalHandoffState? = null
    private var completedPhysicalHandoff: PhysicalHandoffState? = null
    private var backendGeneration = 0L
    private var candidateRemoteProxy: Any? = null

    init {
        authority.publish(initialBackend)
        initialBackend.activateInitialControlSurface()
    }

    fun currentBackend(): PlaybackBackend = backend

    suspend fun <T> withCurrentBackend(
        operation: suspend (PlaybackBackend) -> T
    ): T {
        val captured = acquireCurrentBackendLease(mutating = true)
        return try {
            operation(captured)
        } finally {
            releaseCommandLease()
        }
    }

    suspend fun <T> withCurrentBackendRead(
        operation: suspend (PlaybackBackend) -> T
    ): T {
        val captured = acquireCurrentBackendLease(mutating = false)
        return try {
            operation(captured)
        } finally {
            releaseCommandLease()
        }
    }

    suspend fun routeIfAuthoritative(
        expectedIdentity: Any,
        operation: suspend (PlaybackBackend) -> Unit
    ): Boolean {
        val captured = acquireAuthoritativeBackendLease(expectedIdentity) ?: return false
        return try {
            operation(captured)
            true
        } finally {
            releaseCommandLease()
        }
    }

    suspend fun capturePhysicalRemoteTicket(sourceIdentity: Any): PhysicalRemoteTicket? =
        admissionMutex.withLock {
            val current = backend
            val currentStandard = current.type == PlaybackBackendType.STANDARD &&
                current.identity === sourceIdentity &&
                authority.isAuthoritative(PlaybackBackendType.STANDARD, sourceIdentity)
            val candidateProxy = candidateRemoteProxy === sourceIdentity
            val handoff = physicalHandoff?.takeIf { state ->
                state.acceptedRemoteSources.any { it === sourceIdentity }
            }
            if (!currentStandard && !candidateProxy && handoff == null) return@withLock null
            PhysicalRemoteTicket(
                sourceIdentity,
                handoff?.previousGeneration ?: backendGeneration,
                handoff
            )
        }

    suspend fun routePhysicalRemote(
        ticket: PhysicalRemoteTicket,
        operation: suspend (PlaybackBackend) -> Unit
    ): Boolean {
        if (!ticket.consumed.compareAndSet(false, true)) return false
        val ticketHandoff = ticket.handoff as? PhysicalHandoffState
        if (ticketHandoff != null) {
            ticketHandoff.signal.await()
            val captured = admissionMutex.withLock {
                if (!canRouteAfterHandoff(ticket, ticketHandoff)) return@withLock null
                acquireCommandLease(mutating = true)
                backend
            } ?: return false
            return try {
                operation(captured)
                true
            } finally {
                releaseCommandLease()
            }
        }

        while (true) {
            var promotedHandoff: PhysicalHandoffState? = null
            when (val decision = admissionMutex.withLock {
                val handoff = physicalHandoff
                val validCurrent = isAcceptedRemoteSource(ticket.sourceIdentity)
                if (handoff != null) {
                    if (validCurrent || handoff.acceptedRemoteSources.any { it === ticket.sourceIdentity }) {
                        promotedHandoff = handoff
                        return@withLock BackendLeaseDecision.Wait(handoff.signal)
                    }
                    return@withLock BackendLeaseDecision.Rejected
                }
                if (!validCurrent || ticket.backendGeneration != backendGeneration) {
                    val completedHandoff = completedPhysicalHandoff
                    val canPromoteAcrossCompletedHandoff = completedHandoff != null &&
                        ticket.backendGeneration == completedHandoff.previousGeneration &&
                        backendGeneration == completedHandoff.resultGeneration &&
                        completedHandoff.acceptedRemoteSources.any { it === ticket.sourceIdentity }
                    if (!canPromoteAcrossCompletedHandoff) {
                        return@withLock BackendLeaseDecision.Rejected
                    }
                }
                acquireCommandLease(mutating = true)
                BackendLeaseDecision.Captured(backend)
            }) {
                is BackendLeaseDecision.Captured -> return try {
                    operation(decision.backend)
                    true
                } finally {
                    releaseCommandLease()
                }
                is BackendLeaseDecision.Wait -> {
                    decision.signal.await()
                    val handoff = promotedHandoff ?: return false
                    val captured = admissionMutex.withLock {
                        if (!canRouteAfterHandoff(ticket, handoff)) return@withLock null
                        acquireCommandLease(mutating = true)
                        backend
                    } ?: return false
                    return try {
                        operation(captured)
                        true
                    } finally {
                        releaseCommandLease()
                    }
                }
                BackendLeaseDecision.Rejected -> return false
            }
        }
    }

    suspend fun setPlaybackBackend(type: PlaybackBackendType): PlaybackBackendTransactionResult =
        swapMutex.withLock swap@{
            nextOperationId += 1
            val operationId = nextOperationId
            val previous = admissionMutex.withLock { backend }
            if (previous.type == type) {
                return@swap PlaybackBackendTransactionResult(
                    type,
                    operationId,
                    captureSameTargetSnapshot(previous)
                )
            }

            var replacement: PlaybackBackend? = null
            var candidateIdentity: Any? = null
            val logicallyCommitted = AtomicBoolean(false)
            val candidateCleanupClaimed = AtomicBoolean(false)
            try {
                val captured = captureVersionedSnapshot(previous)
                val identity = Any()
                candidateIdentity = identity
                if (type == PlaybackBackendType.STANDARD) {
                    // This invariant is snapshot-only and can be rejected
                    // before the physical barrier without constructing
                    // KotlinAudio's eagerly-active MediaSession candidate.
                    StandardPlaybackActivationSnapshotValidator.validate(captured.snapshot)
                    admissionMutex.withLock {
                        candidateRemoteProxy = identity
                    }
                }
                // KotlinAudio constructs and activates MediaSessionCompat in the
                // QueuedAudioPlayer constructor. A Standard candidate therefore
                // stays fully lazy until the old surface is suspended behind the
                // physical handoff barrier.
                if (type != PlaybackBackendType.STANDARD) {
                    replacement = createReplacement(type, identity, candidateCleanupClaimed)
                    replacement.prepareSilently(captured.snapshot)
                    replacement.restore(captured.snapshot)
                    replacement.prepareActivation(captured.snapshot)
                }

                val decision = admissionMutex.withLock admission@{
                    if (physicalHandoff != null || backend !== previous) {
                        return@admission CommitDecision.Failed(busyError())
                    }
                    val handoff = PhysicalHandoffState(
                        signal = CompletableDeferred(),
                        previousGeneration = backendGeneration,
                        previousRemoteSource = previous.identity.takeIf {
                            previous.type == PlaybackBackendType.STANDARD
                        },
                        candidateRemoteSource = candidateRemoteProxy
                    )
                    // Publishing the barrier closes command admission before
                    // waiting for already-issued leases to drain. Natural
                    // playback may still advance on the authoritative backend,
                    // so the final snapshot is deliberately captured afterward.
                    physicalHandoff = handoff
                    CommitDecision.Ready(handoff)
                }

                when (decision) {
                    is CommitDecision.Failed -> throw decision.error
                    is CommitDecision.Ready -> {
                        // From this point the handoff owns rollback and
                        // reactivation of the previous control surface.
                        val committedSnapshot = performPhysicalHandoff(
                            previous,
                            replacement,
                            type,
                            identity,
                            captured.snapshot,
                            decision.physicalHandoff,
                            logicallyCommitted,
                            candidateCleanupClaimed
                        )
                        return@swap PlaybackBackendTransactionResult(
                            type,
                            operationId,
                            committedSnapshot
                        )
                    }
                }
            } finally {
                if (!logicallyCommitted.get()) {
                    withContext(NonCancellable) {
                        replacement?.let {
                            cleanupUncommittedOnce(it, candidateCleanupClaimed)
                        }
                        clearCandidateRemoteProxy(candidateIdentity)
                    }
                }
            }
        }

    private suspend fun performPhysicalHandoff(
        previous: PlaybackBackend,
        preparedReplacement: PlaybackBackend?,
        replacementType: PlaybackBackendType,
        replacementIdentity: Any,
        initialSnapshot: PlaybackBackendSnapshot,
        handoff: PhysicalHandoffState,
        logicallyCommitted: AtomicBoolean,
        candidateCleanupClaimed: AtomicBoolean
    ): PlaybackBackendSnapshot {
        var rollbackSnapshot = initialSnapshot
        var surfaceSuspensionStarted = false
        var quiescenceStarted = false
        var replacement = preparedReplacement
        try {
            awaitCommandLeasesToDrain(previous, handoff)
            surfaceSuspensionStarted = true
            previous.suspendControlSurface()
            quiescenceStarted = true
            val snapshot = previous.beginHandoffQuiescence()
            rollbackSnapshot = snapshot
            val finalReplacement = replacement ?: createReplacement(
                replacementType,
                replacementIdentity,
                candidateCleanupClaimed
            ).also { replacement = it }
            // Queue state can change while the candidate is warming. Restage
            // from Tfinal before the final restore/readiness pass.
            finalReplacement.prepareSilently(snapshot)
            finalReplacement.restore(snapshot)
            finalReplacement.prepareActivation(snapshot)
            previous.relinquishExclusiveControlSurfaceBeforeCommit()
            admissionMutex.withLock {
                check(physicalHandoff === handoff)
                check(backend === previous)
                finalReplacement.commitQueue(snapshot)
                backend = finalReplacement
                authority.publish(finalReplacement)
                backendGeneration += 1
                handoff.resultGeneration = backendGeneration
                handoff.committed = true
                if (candidateRemoteProxy === finalReplacement.identity) candidateRemoteProxy = null
                logicallyCommitted.set(true)
            }

            withContext(NonCancellable) {
                finalReplacement.activateAfterCommit(snapshot)
            }
            return snapshot
        } catch (error: Exception) {
            if (!logicallyCommitted.get()) {
                replacement?.let { cleanupUncommittedOnce(it, candidateCleanupClaimed) }
                rollbackHandoffQuiescence(
                    previous,
                    rollbackSnapshot,
                    quiescenceStarted,
                    surfaceSuspensionStarted
                )
            }
            throw error
        } finally {
            withContext(NonCancellable) {
                admissionMutex.withLock {
                    if (physicalHandoff === handoff) physicalHandoff = null
                    if (logicallyCommitted.get()) completedPhysicalHandoff = handoff
                    handoff.signal.complete(Unit)
                }
                if (logicallyCommitted.get()) scheduleCommittedCleanup(previous)
            }
        }
    }

    private suspend fun createReplacement(
        type: PlaybackBackendType,
        identity: Any,
        candidateCleanupClaimed: AtomicBoolean
    ): PlaybackBackend {
        val replacement = factory.create(type, identity)
        try {
            check(replacement.identity === identity) {
                "Playback backend factory must preserve the pre-admitted candidate identity."
            }
        } catch (error: Exception) {
            cleanupUncommittedOnce(replacement, candidateCleanupClaimed)
            throw error
        }
        return replacement
    }

    private suspend fun rollbackHandoffQuiescence(
        previous: PlaybackBackend,
        snapshot: PlaybackBackendSnapshot,
        quiescenceStarted: Boolean,
        surfaceSuspensionStarted: Boolean
    ) {
        withContext(NonCancellable) {
            var rollbackFailed = false
            if (quiescenceStarted) {
                try {
                    previous.cancelHandoffQuiescence(snapshot)
                } catch (_: Exception) {
                    rollbackFailed = true
                }
            }
            if (surfaceSuspensionStarted) {
                try {
                    // Implementations drain quarantined producer events before
                    // publishing their canonical rollback surface.
                    previous.resumeControlSurface(snapshot)
                } catch (_: Exception) {
                    rollbackFailed = true
                }
            }
            if (rollbackFailed) {
                throw RejectionException(
                    "The previous playback backend could not be fully reactivated.",
                    "playback_backend_rollback_failed"
                )
            }
        }
    }

    private suspend fun awaitCommandLeasesToDrain(
        previous: PlaybackBackend,
        handoff: PhysicalHandoffState
    ) {
        while (true) {
            val signal = admissionMutex.withLock {
                check(physicalHandoff === handoff)
                check(backend === previous)
                if (activeCommandLeases == 0) null else leaseDrainSignal
            }
            if (signal == null) return
            signal.await()
        }
    }

    private suspend fun captureSameTargetSnapshot(
        previous: PlaybackBackend
    ): PlaybackBackendSnapshot {
        repeat(MAXIMUM_PREPARATION_ATTEMPTS) {
            val decision = admissionMutex.withLock {
                physicalHandoff?.let { return@withLock SnapshotDecision.Wait(it.signal) }
                check(backend === previous)
                if (activeCommandLeases != 0) {
                    SnapshotDecision.Wait(leaseDrainSignal)
                } else {
                    SnapshotDecision.Captured(VersionedSnapshot(previous.snapshot(), commandVersion))
                }
            }
            when (decision) {
                is SnapshotDecision.Captured -> return decision.value.snapshot
                is SnapshotDecision.Wait -> decision.signal.await()
            }
        }
        throw busyError()
    }

    private suspend fun captureVersionedSnapshot(previous: PlaybackBackend): VersionedSnapshot {
        repeat(MAXIMUM_PREPARATION_ATTEMPTS) {
            val decision = admissionMutex.withLock {
                physicalHandoff?.let { return@withLock SnapshotDecision.Wait(it.signal) }
                check(backend === previous) { "The authoritative playback backend changed unexpectedly." }
                previous.settleActiveTransition()
                if (activeCommandLeases != 0) {
                    SnapshotDecision.Wait(leaseDrainSignal)
                } else {
                    SnapshotDecision.Captured(VersionedSnapshot(previous.snapshot(), commandVersion))
                }
            }
            when (decision) {
                is SnapshotDecision.Captured -> return decision.value
                is SnapshotDecision.Wait -> decision.signal.await()
            }
        }
        throw busyError()
    }

    private suspend fun acquireCurrentBackendLease(mutating: Boolean): PlaybackBackend {
        while (true) {
            when (val decision = admissionMutex.withLock {
                physicalHandoff?.let { return@withLock BackendLeaseDecision.Wait(it.signal) }
                acquireCommandLease(mutating)
                BackendLeaseDecision.Captured(backend)
            }) {
                is BackendLeaseDecision.Captured -> return decision.backend
                is BackendLeaseDecision.Wait -> decision.signal.await()
                BackendLeaseDecision.Rejected -> error("Unexpected rejected backend admission.")
            }
        }
    }

    private suspend fun acquireAuthoritativeBackendLease(
        expectedIdentity: Any
    ): PlaybackBackend? {
        while (true) {
            when (val decision = admissionMutex.withLock {
                physicalHandoff?.let { return@withLock BackendLeaseDecision.Wait(it.signal) }
                val current = backend
                if (current.identity !== expectedIdentity ||
                    !authority.isAuthoritative(current.type, expectedIdentity)
                ) return@withLock BackendLeaseDecision.Rejected
                acquireCommandLease(mutating = true)
                BackendLeaseDecision.Captured(current)
            }) {
                is BackendLeaseDecision.Captured -> return decision.backend
                is BackendLeaseDecision.Wait -> decision.signal.await()
                BackendLeaseDecision.Rejected -> return null
            }
        }
    }

    private fun acquireCommandLease(mutating: Boolean) {
        if (mutating) commandVersion += 1
        if (activeCommandLeases == 0) leaseDrainSignal = CompletableDeferred()
        activeCommandLeases += 1
    }

    private suspend fun releaseCommandLease() {
        withContext(NonCancellable) {
            admissionMutex.withLock {
                activeCommandLeases -= 1
                if (activeCommandLeases == 0) leaseDrainSignal.complete(Unit)
            }
        }
    }

    private suspend fun cleanupUncommitted(replacement: PlaybackBackend) {
        withContext(NonCancellable) {
            admissionMutex.withLock {
                if (candidateRemoteProxy === replacement.identity) candidateRemoteProxy = null
            }
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
    }

    private suspend fun cleanupUncommittedOnce(
        replacement: PlaybackBackend,
        cleanupClaimed: AtomicBoolean
    ) {
        if (cleanupClaimed.compareAndSet(false, true)) cleanupUncommitted(replacement)
    }

    private suspend fun clearCandidateRemoteProxy(identity: Any?) {
        if (identity == null) return
        admissionMutex.withLock {
            if (candidateRemoteProxy === identity) candidateRemoteProxy = null
        }
    }

    private suspend fun resumeAuthoritativeControlSurface(
        previous: PlaybackBackend,
        snapshot: PlaybackBackendSnapshot
    ) {
        withContext(NonCancellable) {
            try {
                previous.resumeControlSurface(snapshot)
            } catch (_: Exception) {
                // Rollback keeps the old backend authoritative even if UI refresh fails.
            }
        }
    }

    private fun busyError(): RejectionException = RejectionException(
        "The playback backend remained busy while preparing a replacement.",
        "playback_backend_busy"
    )

    private fun reportDiagnostic(diagnostic: PlaybackBackendCleanupDiagnostic) {
        diagnosticScope.launch {
            try {
                onCleanupDiagnostic(diagnostic)
            } catch (_: Exception) {
                // Diagnostics are observational and must never change a committed
                // transaction result.
            }
        }
    }

    private fun scheduleCommittedCleanup(previous: PlaybackBackend) {
        diagnosticScope.launch {
            try {
                previous.dispose()
            } catch (_: Exception) {
                reportDiagnostic(PlaybackBackendCleanupDiagnostic())
            }
        }
    }

    private fun isAcceptedRemoteSource(sourceIdentity: Any): Boolean {
        val current = backend
        return (current.type == PlaybackBackendType.STANDARD &&
            current.identity === sourceIdentity &&
            authority.isAuthoritative(PlaybackBackendType.STANDARD, sourceIdentity)) ||
            candidateRemoteProxy === sourceIdentity
    }

    private fun canRouteAfterHandoff(
        ticket: PhysicalRemoteTicket,
        handoff: PhysicalHandoffState
    ): Boolean {
        if (handoff.committed) {
            return ticket.backendGeneration == handoff.previousGeneration &&
                backendGeneration == handoff.resultGeneration &&
                handoff.acceptedRemoteSources.any { it === ticket.sourceIdentity }
        }

        val previousSource = handoff.previousRemoteSource ?: return false
        val current = backend
        return previousSource === ticket.sourceIdentity &&
            ticket.backendGeneration == handoff.previousGeneration &&
            backendGeneration == handoff.previousGeneration &&
            current.type == PlaybackBackendType.STANDARD &&
            current.identity === previousSource &&
            authority.isAuthoritative(PlaybackBackendType.STANDARD, previousSource)
    }

    companion object {
        const val MAXIMUM_PREPARATION_ATTEMPTS = 8
    }
}
