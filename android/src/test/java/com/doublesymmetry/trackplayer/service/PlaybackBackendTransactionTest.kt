package com.doublesymmetry.trackplayer.service

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertNull
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
        lateinit var facade: PlaybackBackendFacade
        var facadeBackendAtCommit: PlaybackBackend? = null
        factory.commitHook = { facadeBackendAtCommit = facade.currentBackend() }
        facade = PlaybackBackendFacade(old, factory, authority = authority)

        assertEquals(PlaybackBackendType.STANDARD, authority.currentType())
        assertSame(old.identity, authority.currentIdentity())

        val result = facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        val replacement = factory.created.single()

        assertEquals(paused, replacement.restoredSnapshot)
        assertEquals(paused.queueIds, replacement.committedQueue)
        assertFalse(replacement.audible)
        assertSame(old.identity, replacement.authorityAtCommit)
        assertSame(old, facadeBackendAtCommit)
        assertSame(replacement.identity, replacement.authorityAtActivation)
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
        val owners = PlaybackControlOwnerRegistry()
        val old = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            audible = true,
            throwPhysicalDeactivation = true,
            controlOwners = owners,
            initiallyOwnsControlSurface = true
        )
        val facade = PlaybackBackendFacade(
            old,
            FakeFactory(controlOwners = owners),
            diagnostics::add
        )

        val result = facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)

        assertEquals(PlaybackBackendType.PING_PONG, result.backend)
        assertEquals(1, diagnostics.size)
        assertEquals("playback_backend_cleanup_failed", diagnostics.single().code)
        assertFalse(diagnostics.single().message.contains("secret"))
        assertEquals(1, (facade.currentBackend() as FakeBackend).activationCalls)
        assertEquals(1, owners.activeCount())
        assertEquals(1, owners.maximumActiveCount())
    }

    @Test
    fun postCommitActivationFailureResolvesWithCommittedAuthorityAndDiagnostic() = runTest {
        val diagnostics = mutableListOf<PlaybackBackendCleanupDiagnostic>()
        val authority = AndroidPlaybackBackendAuthority()
        val old = FakeBackend(PlaybackBackendType.STANDARD, snapshot, audible = true)
        val factory = FakeFactory(failActivate = true, authority = authority)
        val facade = PlaybackBackendFacade(old, factory, diagnostics::add, authority)

        val result = facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        val replacement = factory.created.single()

        assertEquals(PlaybackBackendType.PING_PONG, result.backend)
        assertSame(replacement, facade.currentBackend())
        assertSame(replacement.identity, authority.currentIdentity())
        assertEquals(1, replacement.activationCalls)
        assertEquals(1, diagnostics.size)
        assertEquals("playback_backend_activation_failed", diagnostics.single().code)
        assertFalse(diagnostics.single().message.contains("secret"))
    }

    @Test
    fun commandsDuringPreparationRunOnOldOwnerAndForceReprepare() = runTest {
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
        assertEquals(2, factory.created.first().calls.count { it == "prepare" })
        assertEquals(1, old.playCalls)
        assertEquals(0, factory.created.first().playCalls)
        assertEquals(0, factory.created.first().transitionCalls)
        assertEquals(0, old.transitionCalls)
        assertEquals(1, listOf(old, *factory.created.toTypedArray()).sumOf { it.playCalls })
        assertEquals(
            listOf(
                "enter:PING_PONG",
                "exit:PING_PONG",
                "enter:PING_PONG",
                "exit:PING_PONG",
                "enter:STANDARD",
                "exit:STANDARD"
            ),
            barrier.trace
        )
    }

    @Test
    fun longTransitionLeaseDoesNotBlockInterruptivePause() = runTest {
        val transition = TransitionBarrier()
        val old = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            audible = true,
            transitionBarrier = transition
        )
        val facade = PlaybackBackendFacade(old, FakeFactory())

        val runningTransition = async {
            facade.withCurrentBackend {
                it.startTransition(PlaybackTransitionRequest(5_000, 20, 1f, 0))
            }
        }
        transition.entered.await()
        val pause = async { facade.withCurrentBackend { it.pause() } }
        runCurrent()

        assertTrue(pause.isCompleted)
        assertEquals(1, old.pauseCalls)
        pause.await()
        runningTransition.await()
        assertTrue(runningTransition.isCompleted)
        assertEquals(
            PlaybackBackendType.STANDARD,
            facade.setPlaybackBackend(PlaybackBackendType.STANDARD).backend
        )
    }

    @Test
    fun cancelledCommandReleasesLeaseSoBackendSwapCanComplete() = runTest {
        val old = FakeBackend(PlaybackBackendType.STANDARD, snapshot, audible = true)
        val facade = PlaybackBackendFacade(old, FakeFactory())
        val entered = CompletableDeferred<Unit>()
        val command = async {
            facade.withCurrentBackend {
                entered.complete(Unit)
                awaitCancellation()
            }
        }
        entered.await()

        command.cancelAndJoin()

        val result = withTimeout(1_000) {
            facade.setPlaybackBackend(PlaybackBackendType.PING_PONG)
        }
        assertEquals(PlaybackBackendType.PING_PONG, result.backend)
    }

    @Test
    fun cancelledSwapDuringPrecommitFinalizesRollbackAndReopensAdmission() = runTest {
        val handoffBarrier = PrecommitHandoffBarrier()
        val authority = AndroidPlaybackBackendAuthority()
        val old = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            audible = true,
            precommitHandoffBarrier = handoffBarrier,
            authority = authority
        )
        val factory = FakeFactory(authority = authority)
        val facade = PlaybackBackendFacade(old, factory, authority = authority)
        val swap = async { facade.setPlaybackBackend(PlaybackBackendType.PING_PONG) }
        handoffBarrier.entered.await()

        swap.cancelAndJoin()

        assertTrue(swap.isCancelled)
        assertSame(old, facade.currentBackend())
        assertSame(old.identity, authority.currentIdentity())
        assertTrue(factory.created.single().disposed)
        withTimeout(1_000) {
            facade.withCurrentBackend { it.pause() }
        }
        assertEquals(1, old.pauseCalls)
    }

    @Test
    fun cancelledSwapAfterLogicalCommitFinishesActivationWithoutDisposingReplacement() = runTest {
        val disposal = DisposalBarrier()
        val old = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            audible = true,
            disposalBarrier = disposal
        )
        val factory = FakeFactory()
        val facade = PlaybackBackendFacade(old, factory)
        val swap = async { facade.setPlaybackBackend(PlaybackBackendType.PING_PONG) }
        disposal.entered.await()
        val replacement = factory.created.single()

        swap.cancel()
        runCurrent()

        assertSame(replacement, facade.currentBackend())
        assertFalse(replacement.disposed)
        disposal.release.complete(Unit)
        swap.cancelAndJoin()
        assertTrue(old.disposed)
        assertFalse(replacement.disposed)
        assertEquals(1, replacement.activationCalls)
        withTimeout(1_000) {
            facade.withCurrentBackend { it.pause() }
        }
        assertEquals(1, replacement.pauseCalls)
    }

    @Test
    fun cancelledSwapWaitingForPostPrepareLeaseCleansCandidateAndResumesOldSurface() = runTest {
        val preparation = TransactionBarrier()
        val transition = TransitionBarrier(releaseOnSettle = false)
        val old = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            audible = true,
            transitionBarrier = transition
        )
        val factory = FakeFactory(barrier = preparation)
        val facade = PlaybackBackendFacade(old, factory)
        val swap = async { facade.setPlaybackBackend(PlaybackBackendType.STANDARD) }
        preparation.firstPrepareEntered.await()
        val runningTransition = async {
            facade.withCurrentBackend {
                it.startTransition(PlaybackTransitionRequest(5_000, 20, 1f, 0))
            }
        }
        transition.entered.await()
        preparation.releaseFirstPrepare.complete(Unit)
        runCurrent()

        swap.cancelAndJoin()

        val candidate = factory.created.single()
        assertTrue(swap.isCancelled)
        assertTrue(candidate.disposed)
        assertEquals(1, candidate.calls.count { it == "dispose" })
        assertSame(old, facade.currentBackend())
        assertTrue(old.calls.contains("suspendControlSurface"))
        assertTrue(old.calls.contains("resumeControlSurface"))
        assertNull(facade.capturePhysicalRemoteTicket(candidate.identity))

        facade.withCurrentBackend { it.pause() }
        runningTransition.await()
        assertEquals(1, old.pauseCalls)
    }

    @Test
    fun failedSurfaceSuspensionAfterEffectResumesOldSurface() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val old = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            audible = true,
            controlOwners = owners,
            failSuspendAfterEffect = true
        )
        val factory = FakeFactory(controlOwners = owners)
        val facade = PlaybackBackendFacade(old, factory)

        expectFailure("suspend") {
            facade.setPlaybackBackend(PlaybackBackendType.STANDARD)
        }

        assertSame(old, facade.currentBackend())
        assertTrue(factory.created.isEmpty())
        assertEquals(
            listOf("suspendControlSurface", "resumeControlSurface"),
            old.calls.filter { it.endsWith("ControlSurface") }
        )
        assertEquals(1, owners.activeCount())
    }

    @Test
    fun sameTargetWaitsForCoherentSnapshotWithoutSettlingTransition() = runTest {
        val transition = TransitionBarrier(releaseOnSettle = false)
        val old = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            transitionBarrier = transition
        )
        val facade = PlaybackBackendFacade(old, FakeFactory())
        val runningTransition = async {
            facade.withCurrentBackend {
                it.startTransition(PlaybackTransitionRequest(5_000, 20, 1f, 0))
            }
        }
        transition.entered.await()

        val sameTarget = async { facade.setPlaybackBackend(PlaybackBackendType.PING_PONG) }
        runCurrent()
        assertFalse(sameTarget.isCompleted)
        assertFalse(old.calls.contains("settle"))

        transition.release.complete(Unit)
        runningTransition.await()
        assertEquals(snapshot, sameTarget.await().snapshot)
        assertFalse(old.calls.contains("settle"))
    }

    @Test
    fun remoteCapturedDuringPhysicalHandoffRunsExactlyOnceOnReplacement() = runTest {
        val disposal = DisposalBarrier()
        val old = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            audible = true,
            disposalBarrier = disposal
        )
        val authority = AndroidPlaybackBackendAuthority()
        val factory = FakeFactory(authority = authority)
        val facade = PlaybackBackendFacade(old, factory, authority = authority)

        val swap = async { facade.setPlaybackBackend(PlaybackBackendType.PING_PONG) }
        disposal.entered.await()
        val replacement = factory.created.single()
        assertSame(replacement, facade.currentBackend())
        val ticket = requireNotNull(facade.capturePhysicalRemoteTicket(old.identity))
        var routedBackend: PlaybackBackend? = null
        val routed = async {
            facade.routePhysicalRemote(ticket) {
                routedBackend = it
                it.pause()
            }
        }
        runCurrent()
        assertFalse(routed.isCompleted)

        disposal.release.complete(Unit)
        swap.await()
        assertTrue(routed.await())
        assertSame(replacement, routedBackend)
        assertEquals(1, replacement.pauseCalls)
        assertFalse(facade.routePhysicalRemote(ticket) { it.pause() })
        assertEquals(1, replacement.pauseCalls)
        assertNull(facade.capturePhysicalRemoteTicket(old.identity))
    }

    @Test
    fun candidateRemoteCapturedBeforeRollbackIsRejectedWithoutRouting() = runTest {
        val restoreBarrier = RestoreFailureBarrier()
        val old = FakeBackend(PlaybackBackendType.PING_PONG, snapshot, audible = true)
        val factory = FakeFactory(restoreFailureBarrier = restoreBarrier)
        val facade = PlaybackBackendFacade(old, factory)

        supervisorScope {
            val swap = async { facade.setPlaybackBackend(PlaybackBackendType.STANDARD) }
            restoreBarrier.entered.await()
            val candidate = factory.created.single()
            val ticket = requireNotNull(facade.capturePhysicalRemoteTicket(candidate.identity))
            restoreBarrier.release.complete(Unit)
            expectFailure("restore") { swap.await() }

            assertFalse(facade.routePhysicalRemote(ticket) { it.play() })
            assertEquals(0, old.playCalls)
            assertEquals(0, candidate.playCalls)
            assertNull(facade.capturePhysicalRemoteTicket(candidate.identity))
            assertSame(old, facade.currentBackend())
        }
    }

    @Test
    fun candidateRemoteIdentityIsAdmittedBeforeStandardFactoryReturns() = runTest {
        val creation = CandidateCreationBarrier()
        val old = FakeBackend(PlaybackBackendType.PING_PONG, snapshot, audible = true)
        val factory = FakeFactory(creationBarrier = creation)
        val facade = PlaybackBackendFacade(old, factory)
        val swap = async { facade.setPlaybackBackend(PlaybackBackendType.STANDARD) }

        val candidateIdentity = creation.entered.await()
        val routesOldTicket = requireNotNull(facade.capturePhysicalRemoteTicket(candidateIdentity))
        val promotesAfterCommitTicket = requireNotNull(
            facade.capturePhysicalRemoteTicket(candidateIdentity)
        )
        assertTrue(facade.routePhysicalRemote(routesOldTicket) { it.pause() })
        assertEquals(1, old.pauseCalls)
        creation.release.complete(Unit)
        swap.await()
        val candidate = factory.created.single()

        assertSame(candidateIdentity, candidate.identity)
        assertEquals(2, candidate.calls.count { it == "prepare" })
        assertFalse(requireNotNull(candidate.restoredSnapshot).playWhenReady)
        assertTrue(facade.routePhysicalRemote(promotesAfterCommitTicket) { it.play() })
        assertEquals(1, candidate.playCalls)
        assertEquals(1, old.pauseCalls)
        assertFalse(facade.routePhysicalRemote(routesOldTicket) { it.play() })
    }

    @Test
    fun candidateRemoteCapturedDuringFailedHandoffIsRejectedWithoutRouting() = runTest {
        val handoffBarrier = PrecommitHandoffBarrier()
        val old = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            audible = true,
            failRelinquish = true,
            precommitHandoffBarrier = handoffBarrier
        )
        val factory = FakeFactory()
        val facade = PlaybackBackendFacade(old, factory)

        supervisorScope {
            val swap = async { facade.setPlaybackBackend(PlaybackBackendType.STANDARD) }
            handoffBarrier.entered.await()
            val candidate = factory.created.single()
            val ticket = requireNotNull(facade.capturePhysicalRemoteTicket(candidate.identity))
            handoffBarrier.release.complete(Unit)
            expectFailure("relinquish") { swap.await() }

            assertFalse(facade.routePhysicalRemote(ticket) { it.play() })
            assertEquals(0, old.playCalls)
            assertEquals(0, candidate.playCalls)
            assertSame(old, facade.currentBackend())
        }
    }

    @Test
    fun remoteCapturedBeforePhysicalHandoffRoutesAfterCommitExactlyOnce() = runTest {
        val disposal = DisposalBarrier()
        val old = FakeBackend(
            PlaybackBackendType.STANDARD,
            snapshot,
            audible = true,
            disposalBarrier = disposal
        )
        val authority = AndroidPlaybackBackendAuthority()
        val factory = FakeFactory(authority = authority)
        val facade = PlaybackBackendFacade(old, factory, authority = authority)
        val ticket = requireNotNull(facade.capturePhysicalRemoteTicket(old.identity))

        val swap = async { facade.setPlaybackBackend(PlaybackBackendType.PING_PONG) }
        disposal.entered.await()
        disposal.release.complete(Unit)
        swap.await()
        val replacement = factory.created.single()

        assertTrue(facade.routePhysicalRemote(ticket) { it.pause() })
        assertEquals(1, replacement.pauseCalls)
        assertEquals(0, old.pauseCalls)
        assertFalse(facade.routePhysicalRemote(ticket) { it.pause() })
        assertEquals(1, replacement.pauseCalls)
    }

    @Test
    fun rollbackAfterPrecommitFailureReactivatesOldPlayback() = runTest {
        val owners = PlaybackControlOwnerRegistry()
        val old = FakeBackend(
            PlaybackBackendType.PING_PONG,
            snapshot,
            audible = true,
            controlOwners = owners,
            initiallyOwnsControlSurface = false,
            failRelinquish = true
        )
        val facade = PlaybackBackendFacade(
            old,
            FakeFactory(controlOwners = owners)
        )

        expectFailure("relinquish") {
            facade.setPlaybackBackend(PlaybackBackendType.STANDARD)
        }

        assertSame(old, facade.currentBackend())
        assertTrue(old.audible)
        assertEquals(1, owners.activeCount())
        assertTrue(old.calls.indexOf("restore") < old.calls.indexOf("activate"))
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
        assertFalse(initial.calls.contains("settle"))
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
        private val failActivate: Boolean = false,
        private val restoreFailureBarrier: RestoreFailureBarrier? = null,
        private val creationBarrier: CandidateCreationBarrier? = null,
        private val barrier: TransactionBarrier? = null,
        private val authority: AndroidPlaybackBackendAuthority? = null,
        private val controlOwners: PlaybackControlOwnerRegistry? = null,
        private val controlTrace: MutableList<String> = mutableListOf()
    ) : PlaybackBackendFactory {
        val created = mutableListOf<FakeBackend>()
        val requested = mutableListOf<PlaybackBackendType>()
        var commitHook: (() -> Unit)? = null

        override suspend fun create(type: PlaybackBackendType, identity: Any): PlaybackBackend {
            requested += type
            if (type == PlaybackBackendType.STANDARD) {
                creationBarrier?.let {
                    it.entered.complete(identity)
                    it.release.await()
                }
            }
            return FakeBackend(
                type,
                PlaybackBackendSnapshot.empty(),
                all = all,
                audibleCounts = audibleCounts,
                failPrepare = failPrepare,
                failRestore = failRestore,
                failActivate = failActivate,
                restoreFailureBarrier = restoreFailureBarrier,
                barrier = barrier,
                authority = authority,
                controlOwners = controlOwners,
                controlTrace = controlTrace,
                activateControlOnCreation = type == PlaybackBackendType.STANDARD && controlOwners != null,
                commitHook = { commitHook?.invoke() },
                identity = identity
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
        private val failActivate: Boolean = false,
        private val failDispose: Boolean = false,
        private val failRelinquish: Boolean = false,
        private val throwPhysicalDeactivation: Boolean = false,
        private val failSuspendAfterEffect: Boolean = false,
        private val barrier: TransactionBarrier? = null,
        private val transitionBarrier: TransitionBarrier? = null,
        private val restoreFailureBarrier: RestoreFailureBarrier? = null,
        private val precommitHandoffBarrier: PrecommitHandoffBarrier? = null,
        private val disposalBarrier: DisposalBarrier? = null,
        private val authority: AndroidPlaybackBackendAuthority? = null,
        private val controlOwners: PlaybackControlOwnerRegistry? = null,
        private val controlTrace: MutableList<String> = mutableListOf(),
        private val activateControlOnCreation: Boolean = false,
        initiallyOwnsControlSurface: Boolean = false,
        private val commitHook: (() -> Unit)? = null,
        override val identity: Any = Any()
    ) : PlaybackBackend {
        val calls = mutableListOf<String>()
        var restoredSnapshot: PlaybackBackendSnapshot? = null
        var committedQueue: List<String>? = null
        var disposed = false
        var playCalls = 0
        var transitionCalls = 0
        var pauseCalls = 0
        var activationCalls = 0
        var authorityAtCommit: Any? = null
        var authorityAtActivation: Any? = null
        var audible = audible
            private set

        init {
            if (initiallyOwnsControlSurface || activateControlOnCreation) activateControlSurface()
        }

        override suspend fun settleActiveTransition() {
            calls += "settle"
            if (transitionBarrier?.releaseOnSettle == true) {
                transitionBarrier.release.complete(Unit)
            }
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
            restoreFailureBarrier?.let {
                it.entered.complete(Unit)
                it.release.await()
                throw IllegalStateException("restore failed")
            }
            if (failRestore) throw IllegalStateException("restore failed")
            snapshotValue = snapshot
            restoredSnapshot = snapshot
            barrier?.exit(type)
        }

        override suspend fun stopAndMute() {
            calls += "stopAndMute"
            setAudible(false)
            precommitHandoffBarrier?.let {
                it.entered.complete(Unit)
                it.release.await()
            }
        }

        override suspend fun suspendControlSurface() {
            calls += "suspendControlSurface"
            if (type == PlaybackBackendType.PING_PONG) deactivateControlSurface()
            if (failSuspendAfterEffect) throw IllegalStateException("suspend failed")
        }

        override suspend fun resumeControlSurface(snapshot: PlaybackBackendSnapshot) {
            calls += "resumeControlSurface"
            if (type == PlaybackBackendType.PING_PONG) activateControlSurface()
        }

        override fun activateInitialControlSurface() {
            if (type == PlaybackBackendType.PING_PONG) activateControlSurface()
        }

        override fun relinquishExclusiveControlSurfaceBeforeCommit() {
            calls += "relinquishControl"
            if (type == PlaybackBackendType.PING_PONG) deactivateControlSurface()
            if (failRelinquish) throw IllegalStateException("relinquish failed")
        }

        override fun commitQueue(snapshot: PlaybackBackendSnapshot) {
            calls += "commitQueue"
            commitHook?.invoke()
            authorityAtCommit = authority?.currentIdentity()
            committedQueue = snapshot.queueIds
        }

        override fun activateAfterCommit(snapshot: PlaybackBackendSnapshot) {
            calls += "activate"
            activationCalls += 1
            authorityAtActivation = authority?.currentIdentity()
            if (type == PlaybackBackendType.PING_PONG) activateControlSurface()
            setAudible(snapshot.playWhenReady)
            if (failActivate) throw IllegalStateException("secret activation detail")
        }

        override suspend fun play() {
            playCalls += 1
            snapshotValue = snapshotValue.copy(playWhenReady = true)
            setAudible(true)
        }
        override fun pause() {
            pauseCalls += 1
            snapshotValue = snapshotValue.copy(playWhenReady = false)
            setAudible(false)
            transitionBarrier?.release?.complete(Unit)
        }
        override suspend fun seekTo(positionMs: Long) { snapshotValue = snapshotValue.copy(positionMs = positionMs) }
        override suspend fun startTransition(request: PlaybackTransitionRequest) {
            transitionCalls += 1
            transitionBarrier?.entered?.complete(Unit)
            transitionBarrier?.release?.await()
        }

        override suspend fun dispose() {
            disposalBarrier?.entered?.complete(Unit)
            disposalBarrier?.release?.await()
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
                if (throwPhysicalDeactivation) {
                    throw IllegalStateException("physical deactivation failed")
                }
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

    private class TransitionBarrier(val releaseOnSettle: Boolean = true) {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
    }

    private class DisposalBarrier {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
    }

    private class RestoreFailureBarrier {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
    }

    private class CandidateCreationBarrier {
        val entered = CompletableDeferred<Any>()
        val release = CompletableDeferred<Unit>()
    }

    private class PrecommitHandoffBarrier {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
    }
}
