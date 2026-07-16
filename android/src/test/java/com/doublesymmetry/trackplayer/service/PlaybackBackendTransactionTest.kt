package com.doublesymmetry.trackplayer.service

import kotlinx.coroutines.async
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackBackendTransactionTest {
    private val snapshot = PlaybackBackendSnapshot(
        queueIds = listOf("first", "second"),
        activeIndex = 1,
        activeTrackId = "second",
        positionMs = 12_345,
        playWhenReady = true,
        volume = 0.7f,
        rate = 1.25f,
        repeatMode = 2,
        transitionGeneration = 9
    )

    @Test
    fun pausedSwapPreservesSnapshot() = runTest {
        val paused = snapshot.copy(playWhenReady = false)
        val old = FakeBackend(PlaybackBackendType.STANDARD, paused)
        val authority = AndroidPlaybackBackendAuthority()
        val factory = FakeFactory(authority = authority)
        val facade = PlaybackBackendFacade(old, factory, authority = authority)

        assertEquals(PlaybackBackendType.STANDARD, authority.currentType())
        assertSame(old.identity, authority.currentIdentity())

        val result = facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        val replacement = factory.created.single()

        assertEquals(paused, replacement.restoredSnapshot)
        assertEquals(paused.queueIds, replacement.committedQueue)
        assertFalse(replacement.audible)
        assertEquals(null, replacement.authorityAtCommit)
        assertEquals(null, replacement.authorityAtActivation)
        assertSame(replacement.identity, authority.currentIdentity())
        assertEquals(PlaybackBackendType.PING_PONG, result.backend)
        assertEquals(1L, result.operationId)

        val generationSidecar = PlaybackTransitionGenerationSidecar()
        val pingPongGeneration = generationSidecar.observe(paused.transitionGeneration)
        generationSidecar.restore(pingPongGeneration)
        val standardGeneration = generationSidecar.current()
        generationSidecar.restore(standardGeneration)
        assertEquals(paused.transitionGeneration, generationSidecar.observe(0L))
    }

    @Test
    fun playingSwapKeepsOneAudibleOwner() = runTest {
        val audibleCounts = mutableListOf<Int>()
        val all = mutableListOf<FakeBackend>()
        val controlOwners = PlaybackControlOwnerRegistry()
        val old = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            true,
            all,
            audibleCounts,
            controlOwners = controlOwners,
            initiallyOwnsControlSurface = true
        )
        all += old
        val factory = FakeFactory(all, audibleCounts, controlOwners = controlOwners)
        val facade = PlaybackBackendFacade(old, factory)

        facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)

        assertTrue(factory.created.single().audible)
        assertFalse(old.audible)
        assertTrue(audibleCounts.all { it <= 1 })
        assertEquals(1, controlOwners.activeCount())
        assertEquals(1, controlOwners.maximumActiveCount())
    }

    @Test
    fun activeCrossfadeIsSettledBeforeSnapshot() = runTest {
        val old = FakeBackend(PlaybackBackendType.PING_PONG, snapshot)
        val authority = AndroidPlaybackBackendAuthority()
        val facade = PlaybackBackendFacade(old, FakeFactory(), authority = authority)

        assertEquals(PlaybackBackendType.PING_PONG, authority.currentType())
        assertSame(old.identity, authority.currentIdentity())

        facade.setPlaybackBackend(PlaybackBackendType.STANDARD)

        assertTrue(old.calls.indexOf("settle") < old.calls.indexOf("snapshot"))
        assertEquals(1, old.calls.count { it == "settle" })
    }

    @Test
    fun prepareFailureRejectsAndKeepsOldBackend() = runTest {
        val old = FakeBackend(PlaybackBackendType.STANDARD, snapshot, audible = true)
        val authority = AndroidPlaybackBackendAuthority()
        val factory = FakeFactory(failPrepare = true, authority = authority)
        val facade = PlaybackBackendFacade(old, factory, authority = authority)

        expectFailure("prepare") {
            facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        }

        assertSame(old, facade.currentBackend())
        assertSame(old.identity, authority.currentIdentity())
        assertTrue(old.audible)
        assertTrue(factory.created.single().disposed)
    }

    @Test
    fun restoreFailureRejectsAndKeepsOldBackend() = runTest {
        val old = FakeBackend(PlaybackBackendType.STANDARD, snapshot, audible = true)
        val authority = AndroidPlaybackBackendAuthority()
        val factory = FakeFactory(failRestore = true, authority = authority)
        val facade = PlaybackBackendFacade(old, factory, authority = authority)

        expectFailure("restore") {
            facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        }

        assertSame(old, facade.currentBackend())
        assertSame(old.identity, authority.currentIdentity())
        assertTrue(old.audible)
        assertTrue(factory.created.single().disposed)
    }

    @Test
    fun postCommitDisposeFailureResolvesAndEmitsCleanupDiagnostic() = runTest {
        val diagnostics = mutableListOf<PlaybackBackendCleanupDiagnostic>()
        val old = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            audible = true,
            failDispose = true
        )
        val facade = PlaybackBackendFacade(old, FakeFactory(), diagnostics::add)

        val result = facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)

        assertEquals(PlaybackBackendType.PING_PONG, result.backend)
        assertEquals(1, diagnostics.size)
        assertEquals("playback_backend_cleanup_failed", diagnostics.single().code)
        assertFalse(diagnostics.single().message.contains("secret"))
    }

    @Test
    fun concurrentCallsCommitInSerializedOrder() = runTest {
        val old = FakeBackend(PlaybackBackendType.STANDARD, snapshot)
        val barrier = TransactionBarrier()
        val factory = FakeFactory(barrier = barrier)
        val facade = PlaybackBackendFacade(old, factory)

        val first = async { facade.setPlaybackBackend(PlaybackBackendType.PING_PONG) }
        barrier.firstPrepareEntered.await()
        val deferredPlay = async {
            facade.withCurrentBackend { it.play() }
        }
        val deferredCrossfade = async {
            facade.withCurrentBackend {
                if (it.type == PlaybackBackendType.PING_PONG) {
                    it.startTransition(PlaybackTransitionRequest(500, 20, 1f, 0))
                }
            }
        }
        val second = async { facade.setPlaybackBackend(PlaybackBackendType.STANDARD) }
        barrier.releaseFirstPrepare.complete(Unit)

        assertEquals(1L, first.await().operationId)
        deferredPlay.await()
        deferredCrossfade.await()
        assertEquals(2L, second.await().operationId)
        assertEquals(PlaybackBackendType.STANDARD, facade.currentBackend().type)
        assertEquals(listOf(PlaybackBackendType.PING_PONG, PlaybackBackendType.STANDARD), factory.requested)
        assertEquals(1, barrier.maxInFlight)
        assertEquals(0, old.playCalls)
        assertEquals(1, factory.created.first().playCalls)
        assertEquals(1, factory.created.first().transitionCalls)
        assertEquals(0, old.transitionCalls)
        assertEquals(1, listOf(old, *factory.created.toTypedArray()).sumOf { it.playCalls })
        assertEquals(
            listOf("enter:PING_PONG", "exit:PING_PONG", "enter:STANDARD", "exit:STANDARD"),
            barrier.trace
        )
    }

    @Test
    fun initialStandardOwnsExactlyOneMediaSession() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            controlOwners = owners,
            controlTrace = trace,
            initiallyOwnsControlSurface = true
        )

        PlaybackBackendFacade(initial, FakeFactory(controlOwners = owners, controlTrace = trace))

        assertEquals(1, owners.activeCount())
        assertEquals(listOf("S+"), trace)
    }

    @Test
    fun initialPingPongOwnsExactlyOneMediaSession() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            controlOwners = owners,
            controlTrace = trace
        )

        PlaybackBackendFacade(initial, FakeFactory(controlOwners = owners, controlTrace = trace))

        assertEquals(1, owners.activeCount())
        assertEquals(listOf("P+"), trace)
    }

    @Test
    fun standardToPingPongHandsOffOneMediaSession() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            controlOwners = owners,
            controlTrace = trace,
            initiallyOwnsControlSurface = true
        )
        val facade = PlaybackBackendFacade(
            initial,
            FakeFactory(controlOwners = owners, controlTrace = trace)
        )

        facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)

        assertEquals(listOf("S+", "S-", "P+"), trace)
        assertEquals(1, owners.activeCount())
        assertEquals(1, owners.maximumActiveCount())
    }

    @Test
    fun pingPongToStandardHandsOffOneMediaSession() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            controlOwners = owners,
            controlTrace = trace
        )
        val facade = PlaybackBackendFacade(
            initial,
            FakeFactory(controlOwners = owners, controlTrace = trace)
        )

        facade.setPlaybackBackend(PlaybackBackendType.STANDARD)

        assertEquals(listOf("P+", "P-", "S+"), trace)
        assertEquals(1, owners.activeCount())
        assertEquals(1, owners.maximumActiveCount())
    }

    @Test
    fun standardToPingPongRollbackRestoresOneMediaSession() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            audible = true,
            controlOwners = owners,
            controlTrace = trace,
            initiallyOwnsControlSurface = true
        )
        val facade = PlaybackBackendFacade(
            initial,
            FakeFactory(
                failPrepare = true,
                controlOwners = owners,
                controlTrace = trace
            )
        )

        expectFailure("prepare") { facade.setPlaybackBackend(PlaybackBackendType.PING_PONG) }

        assertSame(initial, facade.currentBackend())
        assertEquals(listOf("S+"), trace)
        assertEquals(1, owners.activeCount())
    }

    @Test
    fun pingPongToStandardRollbackRestoresOneMediaSession() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            audible = true,
            controlOwners = owners,
            controlTrace = trace
        )
        val facade = PlaybackBackendFacade(
            initial,
            FakeFactory(
                failRestore = true,
                controlOwners = owners,
                controlTrace = trace
            )
        )

        expectFailure("restore") { facade.setPlaybackBackend(PlaybackBackendType.STANDARD) }

        assertSame(initial, facade.currentBackend())
        assertEquals(listOf("P+", "P-", "S+", "S-", "P+"), trace)
        assertEquals(1, owners.activeCount())
        assertEquals(1, owners.maximumActiveCount())
    }

    @Test
    fun repeatedBackendSelectionIsANoOp() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            controlOwners = owners,
            controlTrace = trace,
            initiallyOwnsControlSurface = true
        )
        val factory = FakeFactory(controlOwners = owners, controlTrace = trace)
        val facade = PlaybackBackendFacade(initial, factory)

        val result = facade.setPlaybackBackend(PlaybackBackendType.STANDARD)

        assertSame(initial, facade.currentBackend())
        assertTrue(factory.created.isEmpty())
        assertEquals(listOf("S+"), trace)
        assertEquals(snapshot, result.snapshot)
    }

    @Test
    fun repeatedBackendSwapsNeverHaveTwoMediaSessions() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val trace = mutableListOf<String>()
        val initial = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            controlOwners = owners,
            controlTrace = trace,
            initiallyOwnsControlSurface = true
        )
        val facade = PlaybackBackendFacade(
            initial,
            FakeFactory(controlOwners = owners, controlTrace = trace)
        )

        facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        facade.setPlaybackBackend(PlaybackBackendType.STANDARD)
        facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)

        assertEquals(listOf("S+", "S-", "P+", "P-", "S+", "S-", "P+"), trace)
        assertEquals(1, owners.activeCount())
        assertEquals(1, owners.maximumActiveCount())
    }

    @Test
    fun authoritativeRemoteRoutesExactlyOnce() = runTest {
        val initial = FakeBackend(PlaybackBackendType.PING_PONG, snapshot)
        val facade = PlaybackBackendFacade(initial, FakeFactory())

        val executed = facade.routeIfAuthoritative(initial.identity) { it.play() }

        assertTrue(executed)
        assertEquals(1, initial.playCalls)
    }

    @Test
    fun staleRemoteFromPriorPingGenerationIsIgnored() = runTest {
        val initial = FakeBackend(PlaybackBackendType.STANDARD, snapshot)
        val factory = FakeFactory()
        val facade = PlaybackBackendFacade(initial, factory)
        facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        val stalePing = factory.created.last()
        facade.setPlaybackBackend(PlaybackBackendType.STANDARD)
        facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        val currentPing = factory.created.last()

        val staleExecuted = facade.routeIfAuthoritative(stalePing.identity) { it.play() }
        val currentExecuted = facade.routeIfAuthoritative(currentPing.identity) { it.play() }

        assertFalse(staleExecuted)
        assertTrue(currentExecuted)
        assertTrue(stalePing.disposed)
        assertEquals(0, stalePing.playCalls)
        assertEquals(1, currentPing.playCalls)
    }

    private suspend fun expectFailure(stage: String, block: suspend () -> Unit) {
        try {
            block()
            fail("Expected $stage failure")
        } catch (error: IllegalStateException) {
            assertEquals("$stage failed", error.message)
        }
    }

    private class FakeFactory(
        private val all: MutableList<FakeBackend> = mutableListOf(),
        private val audibleCounts: MutableList<Int> = mutableListOf(),
        private val failPrepare: Boolean = false,
        private val failRestore: Boolean = false,
        private val barrier: TransactionBarrier? = null,
        private val authority: AndroidPlaybackBackendAuthority? = null,
        private val controlOwners: PlaybackControlOwnerRegistry? = null,
        private val controlTrace: MutableList<String> = mutableListOf()
    ) : PlaybackBackendFactory {
        val created = mutableListOf<FakeBackend>()
        val requested = mutableListOf<PlaybackBackendType>()

        override fun create(type: PlaybackBackendType): PlaybackBackend {
            requested += type
            return FakeBackend(
                type,
                PlaybackBackendSnapshot.empty(),
                all = all,
                audibleCounts = audibleCounts,
                failPrepare = failPrepare,
                failRestore = failRestore,
                barrier = barrier,
                authority = authority,
                controlOwners = controlOwners,
                controlTrace = controlTrace,
                activateControlOnCreation = type == PlaybackBackendType.STANDARD && controlOwners != null
            ).also {
                created += it
                all += it
            }
        }
    }

    private class FakeBackend(
        override val type: PlaybackBackendType,
        private var snapshotValue: PlaybackBackendSnapshot,
        audible: Boolean = false,
        private val all: MutableList<FakeBackend> = mutableListOf(),
        private val audibleCounts: MutableList<Int> = mutableListOf(),
        private val failPrepare: Boolean = false,
        private val failRestore: Boolean = false,
        private val failDispose: Boolean = false,
        private val barrier: TransactionBarrier? = null,
        private val authority: AndroidPlaybackBackendAuthority? = null,
        private val controlOwners: PlaybackControlOwnerRegistry? = null,
        private val controlTrace: MutableList<String> = mutableListOf(),
        private val activateControlOnCreation: Boolean = false,
        initiallyOwnsControlSurface: Boolean = false
    ) : PlaybackBackend {
        val calls = mutableListOf<String>()
        var restoredSnapshot: PlaybackBackendSnapshot? = null
        var committedQueue: List<String>? = null
        var disposed = false
        var playCalls = 0
        var transitionCalls = 0
        var authorityAtCommit: Any? = null
        var authorityAtActivation: Any? = null
        var audible = audible
            private set

        init {
            if (initiallyOwnsControlSurface || activateControlOnCreation) activateControlSurface()
        }

        override suspend fun settleActiveTransition() {
            calls += "settle"
        }

        override suspend fun snapshot(): PlaybackBackendSnapshot {
            calls += "snapshot"
            return snapshotValue
        }

        override suspend fun prepareSilently(snapshot: PlaybackBackendSnapshot) {
            calls += "prepare"
            setAudible(false)
            barrier?.enter(type)
            if (failPrepare) throw IllegalStateException("prepare failed")
        }

        override suspend fun restore(snapshot: PlaybackBackendSnapshot) {
            calls += "restore"
            if (failRestore) throw IllegalStateException("restore failed")
            snapshotValue = snapshot
            restoredSnapshot = snapshot
            barrier?.exit(type)
        }

        override suspend fun stopAndMute() {
            calls += "stopAndMute"
            setAudible(false)
        }

        override suspend fun suspendControlSurface() {
            if (type == PlaybackBackendType.PING_PONG) deactivateControlSurface()
        }

        override suspend fun resumeControlSurface(snapshot: PlaybackBackendSnapshot) {
            if (type == PlaybackBackendType.PING_PONG) activateControlSurface()
        }

        override fun activateInitialControlSurface() {
            if (type == PlaybackBackendType.PING_PONG) activateControlSurface()
        }

        override fun relinquishExclusiveControlSurfaceBeforeCommit() {
            calls += "relinquishControl"
            deactivateControlSurface()
        }

        override fun commitQueue(snapshot: PlaybackBackendSnapshot) {
            calls += "commitQueue"
            authorityAtCommit = authority?.currentIdentity()
            committedQueue = snapshot.queueIds
        }

        override fun activateAfterCommit(snapshot: PlaybackBackendSnapshot) {
            calls += "activate"
            authorityAtActivation = authority?.currentIdentity()
            if (type == PlaybackBackendType.PING_PONG) activateControlSurface()
            setAudible(snapshot.playWhenReady)
        }

        override suspend fun play() { playCalls += 1; setAudible(true) }
        override fun pause() { setAudible(false) }
        override suspend fun seekTo(positionMs: Long) { snapshotValue = snapshotValue.copy(positionMs = positionMs) }
        override suspend fun startTransition(request: PlaybackTransitionRequest) {
            transitionCalls += 1
        }

        override suspend fun dispose() {
            disposed = true
            calls += "dispose"
            deactivateControlSurface()
            if (failDispose) throw IllegalStateException("secret disposal detail")
        }

        private fun activateControlSurface() {
            controlOwners?.activate(identity) {
                controlTrace += if (type == PlaybackBackendType.STANDARD) "S+" else "P+"
            }
        }

        private fun deactivateControlSurface() {
            controlOwners?.deactivate(identity) {
                controlTrace += if (type == PlaybackBackendType.STANDARD) "S-" else "P-"
            }
        }

        private fun setAudible(value: Boolean) {
            audible = value
            if (all.isNotEmpty()) audibleCounts += all.count { it.audible }
        }
    }

    private class TransactionBarrier {
        val firstPrepareEntered = kotlinx.coroutines.CompletableDeferred<Unit>()
        val releaseFirstPrepare = kotlinx.coroutines.CompletableDeferred<Unit>()
        val trace = mutableListOf<String>()
        var maxInFlight = 0
        private var inFlight = 0
        private var first = true

        suspend fun enter(type: PlaybackBackendType) {
            inFlight += 1
            maxInFlight = maxOf(maxInFlight, inFlight)
            trace += "enter:$type"
            if (first) {
                first = false
                firstPrepareEntered.complete(Unit)
                releaseFirstPrepare.await()
            }
        }

        fun exit(type: PlaybackBackendType) {
            trace += "exit:$type"
            inFlight -= 1
        }
    }
}
