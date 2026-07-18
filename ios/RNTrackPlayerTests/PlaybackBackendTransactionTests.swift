import XCTest
@testable import RNTrackPlayerBackendCore

final class PlaybackBackendTransactionTests: XCTestCase {
    private let snapshot = PlaybackBackendSnapshot(
        queueIDs: ["first", "second"],
        activeIndex: 1,
        activeTrackID: "second",
        position: 12.345,
        playWhenReady: true,
        volume: 0.7,
        rate: 1.25,
        repeatMode: 2,
        transitionGeneration: 9
    )

    func test_pausedSwapPreservesSnapshot() {
        let paused = snapshot.with(playWhenReady: false)
        let old = FakeBackend(kind: .standard, snapshot: paused)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let queuedCommandFinished = expectation(description: "main command queued during restore")
        var queuedCommandBackend: PlaybackBackendKind?
        let hookLock = NSLock()
        var didQueueCommand = false
        factory.prepareHook = {
            hookLock.lock()
            let shouldQueueCommand = !didQueueCommand
            didQueueCommand = true
            hookLock.unlock()
            guard shouldQueueCommand else { return }
            XCTAssertTrue(facade.currentBackend === old)
            XCTAssertTrue(authority.isAuthoritative(.standard, identity: old))
            let commandEntered = DispatchSemaphore(value: 0)
            facade.withCurrentBackendAsync({ backend, completion in
                queuedCommandBackend = backend.kind
                backend.pause()
                commandEntered.signal()
                completion(.success(backend.kind))
            }) { _ in
                queuedCommandFinished.fulfill()
            }
            XCTAssertEqual(
                commandEntered.wait(timeout: .now() + 0.05),
                .success,
                "pause must route to the old owner while candidate restore is running"
            )
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }
        wait(for: [queuedCommandFinished], timeout: 1)
        guard let replacement = factory.created.last else {
            XCTFail("replacement backend was not created")
            return
        }

        XCTAssertEqual(replacement.restoredSnapshot, paused)
        XCTAssertEqual(replacement.committedQueue, paused.queueIDs)
        XCTAssertFalse(replacement.audible)
        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(try? result.get().operationID, 1)
        XCTAssertEqual(queuedCommandBackend, .standard)

        let generationSidecar = PlaybackTransitionGenerationSidecar()
        generationSidecar.restore(paused.transitionGeneration)
        let standardGeneration = generationSidecar.current
        generationSidecar.restore(standardGeneration)
        XCTAssertEqual(generationSidecar.observe(0), paused.transitionGeneration)
    }

    func test_playingSwapKeepsOneAudibleOwner() {
        let registry = AudibleRegistry()
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true, registry: registry)
        registry.backends.append(old)
        let factory = FakeFactory(registry: registry)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        _ = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertTrue(factory.created.first?.audible == true)
        XCTAssertFalse(old.audible)
        XCTAssertTrue(registry.counts.allSatisfy { $0 <= 1 })
    }

    func test_activeCrossfadeIsSettledBeforeSnapshot() {
        let old = FakeBackend(kind: .pingPong, snapshot: snapshot)
        let facade = PlaybackBackendFacade(initial: old, factory: FakeFactory())

        _ = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        let settleIndex = old.calls.firstIndex(of: "settle")
        let snapshotIndex = old.calls.firstIndex(of: "snapshot")
        XCTAssertNotNil(settleIndex)
        XCTAssertNotNil(snapshotIndex)
        if let settleIndex = settleIndex, let snapshotIndex = snapshotIndex {
            XCTAssertLessThan(settleIndex, snapshotIndex)
        }
        XCTAssertEqual(old.calls.filter { $0 == "settle" }.count, 1)
    }

    func test_prepareFailureRejectsAndKeepsOldBackend() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory(failPrepare: true)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(old.audible)
        XCTAssertTrue(factory.created.first?.disposed == true)
    }

    func test_restoreFailureRejectsAndKeepsOldBackend() {
        let first = NSObject()
        let second = NSObject()
        let shared = SharedPlaybackResource(queue: [first, second])
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: snapshot,
            audible: true,
            sharedResource: shared,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory(
            failRestore: true,
            sharedResource: shared
        )
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(old.audible)
        XCTAssertTrue(factory.created.first?.disposed == true)
        XCTAssertEqual(shared.queue.count, 2)
        XCTAssertTrue(shared.queue[0] === first)
        XCTAssertTrue(shared.queue[1] === second)
    }

    func test_postCommitDisposeFailureResolvesAndEmitsCleanupDiagnostic() {
        var diagnostics: [PlaybackBackendCleanupDiagnostic] = []
        let diagnosticReceived = expectation(description: "cleanup diagnostic received")
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true, failDispose: true)
        let facade = PlaybackBackendFacade(
            initial: old,
            factory: FakeFactory(),
            onCleanupDiagnostic: {
                diagnostics.append($0)
                diagnosticReceived.fulfill()
            }
        )

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        wait(for: [diagnosticReceived], timeout: 1)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.code, "playback_backend_cleanup_failed")
        XCTAssertFalse(diagnostics.first?.message.contains("secret") == true)
    }

    func test_postCommitDiagnosticObserverCannotBlockCommittedResult() {
        let observerEntered = DispatchSemaphore(value: 0)
        let releaseObserver = DispatchSemaphore(value: 0)
        let observerFinished = expectation(description: "cleanup observer finished")
        let transactionFinished = expectation(description: "transaction finished")
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true, failDispose: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(
            initial: old,
            factory: factory,
            onCleanupDiagnostic: { _ in
                observerEntered.signal()
                releaseObserver.wait()
                observerFinished.fulfill()
            }
        )
        var result: Result<PlaybackBackendTransactionResult, Error>?

        facade.setPlaybackBackend(.pingPong) {
            result = $0
            transactionFinished.fulfill()
        }

        let observerStatus = observerEntered.wait(timeout: .now() + 1)
        let transactionStatus = XCTWaiter.wait(for: [transactionFinished], timeout: 0.2)
        releaseObserver.signal()
        wait(for: [observerFinished], timeout: 1)

        XCTAssertEqual(observerStatus, .success)
        XCTAssertEqual(transactionStatus, .completed)
        XCTAssertEqual(try? result?.get().backend, .pingPong)
        XCTAssertTrue(facade.currentBackend === factory.created.first)
    }

    func test_commitQueueRunsBeforeFacadePointerAndAuthorityPublication() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        var facadeBackendAtCommit: PlaybackBackend?
        var authorityWasOldAtCommit = false
        factory.commitHook = {
            facadeBackendAtCommit = facade.currentBackend
            authorityWasOldAtCommit = authority.isAuthoritative(.standard, identity: old)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertTrue(facadeBackendAtCommit === old)
        XCTAssertTrue(authorityWasOldAtCommit)
        XCTAssertTrue(facade.currentBackend === factory.created.first)
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: factory.created.first!))
    }

    func test_concurrentCallsCommitInSerializedOrder() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot)
        let barrier = TransactionBarrier()
        let factory = FakeFactory(barrier: barrier)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var operationIDs: [Int] = []

        facade.setPlaybackBackend(.pingPong) { result in
            operationIDs.append((try? result.get().operationID) ?? -1)
            first.fulfill()
        }
        XCTAssertEqual(barrier.firstPrepareEntered.wait(timeout: .now() + 1), .success)
        facade.setPlaybackBackend(.standard) { result in
            operationIDs.append((try? result.get().operationID) ?? -1)
            second.fulfill()
        }
        barrier.releaseFirstPrepare.signal()

        wait(for: [first, second], timeout: 2)
        XCTAssertEqual(operationIDs, [1, 2])
        XCTAssertEqual(facade.currentBackend.kind, .standard)
        XCTAssertEqual(factory.requested, [.pingPong, .standard])
        XCTAssertEqual(barrier.maxInFlight, 1)
        XCTAssertEqual(barrier.trace, [
            "enter:pingPong", "exit:pingPong",
            "enter:pingPong", "exit:pingPong",
            "enter:standard", "exit:standard",
            "enter:standard", "exit:standard"
        ])

        let transitionFinished = expectation(description: "long transition finished")
        let pauseFinished = expectation(description: "interruptive pause finished")
        let transitionStarted = DispatchSemaphore(value: 0)
        var deferredCompletion: ((Result<Void, Error>) -> Void)?
        var transitionResult: Result<Void, Error>?
        facade.withCurrentBackendAsync(timeout: 0.5, { _, completion in
            deferredCompletion = completion
            transitionStarted.signal()
        }) { (result: Result<Void, Error>) in
            transitionResult = result
            transitionFinished.fulfill()
        }
        XCTAssertEqual(transitionStarted.wait(timeout: .now() + 1), .success)

        facade.withCurrentBackendAsync({ backend, completion in
            backend.pause()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in
            pauseFinished.fulfill()
        }

        XCTAssertEqual(
            XCTWaiter.wait(for: [pauseFinished], timeout: 0.05),
            .completed,
            "pause must not wait for a long asynchronous transition"
        )
        deferredCompletion?(.success(()))
        wait(for: [transitionFinished], timeout: 1)
        XCTAssertNoThrow(try transitionResult?.get())
    }

    func test_swapSettlesLeaseAndWaitsForItsActualCompletionBeforeSnapshot() {
        let old = FakeBackend(kind: .pingPong, snapshot: snapshot, audible: true)
        let facade = PlaybackBackendFacade(initial: old, factory: FakeFactory())
        let transitionStarted = DispatchSemaphore(value: 0)
        let transitionFinished = expectation(description: "transition lease released")
        var deferredCompletion: ((Result<Void, Error>) -> Void)?
        var transitionCompletionCount = 0

        facade.withCurrentBackendAsync({ _, completion in
            deferredCompletion = completion
            transitionStarted.signal()
        }) { (_: Result<Void, Error>) in
            transitionCompletionCount += 1
            transitionFinished.fulfill()
        }
        XCTAssertEqual(transitionStarted.wait(timeout: .now() + 1), .success)
        old.settleHook = {
            deferredCompletion?(.failure(FakeError.cancelled))
        }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }
        wait(for: [transitionFinished], timeout: 1)

        XCTAssertEqual(try? result.get().backend, .standard)
        XCTAssertEqual(transitionCompletionCount, 1)
        XCTAssertLessThan(old.calls.firstIndex(of: "settle")!, old.calls.firstIndex(of: "snapshot")!)
        let disposalDeadline = Date().addingTimeInterval(1)
        while !old.disposed, Date() < disposalDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(old.disposed)
    }

    func test_nativeCommandCompletionIsResolvedExactlyOnce() {
        var results: [Result<Void, Error>] = []
        let completion = PlaybackBackendCommandCompletion<Void> { results.append($0) }

        completion.resolve(.failure(FakeError.cancelled))
        completion.resolve(.success(()))

        XCTAssertEqual(results.count, 1)
        XCTAssertThrowsError(try results[0].get())
    }

    func test_commandDuringCandidateRestoreRepreparesFromFreshSnapshot() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let pauseEntered = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var didPause = false

        factory.restoreHook = {
            hookLock.lock()
            let shouldPause = !didPause
            didPause = true
            hookLock.unlock()
            guard shouldPause else { return }

            facade.withCurrentBackendAsync({ backend, completion in
                backend.pause()
                pauseEntered.signal()
                completion(.success(()))
            }) { (_: Result<Void, Error>) in }
            XCTAssertEqual(pauseEntered.wait(timeout: .now() + 0.05), .success)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(factory.created.count, 2, "a stale candidate must be discarded and prepared again")
        XCTAssertEqual(factory.created.first?.restoredSnapshot?.playWhenReady, true)
        XCTAssertTrue(factory.created.first?.disposed == true)
        XCTAssertEqual(factory.created.last?.restoredSnapshot?.playWhenReady, false)
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: factory.created.last!))
    }

    func test_naturalPositionDriftDuringPreparationCommitsQuiescedSnapshot() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let advanced = snapshot.with(position: 27)
        var didAdvance = false
        factory.prepareHook = {
            guard !didAdvance else { return }
            didAdvance = true
            old.simulateNaturalSnapshot(advanced)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, advanced)
        XCTAssertEqual(factory.created.first?.restoredSnapshots, [snapshot, advanced])
        XCTAssertTrue(old.calls.contains("beginHandoffQuiescence"))
        XCTAssertFalse(old.calls.contains("stopAndMute"))
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: factory.created.first!))
    }

    func test_naturalTrackAdvanceDuringPreparationDoesNotResurrectOldTrack() {
        let initial = PlaybackBackendSnapshot(
            queueIDs: ["first", "second"],
            activeIndex: 0,
            activeTrackID: "first",
            position: 28,
            playWhenReady: true,
            volume: 0.7,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 4
        )
        let advanced = PlaybackBackendSnapshot(
            queueIDs: initial.queueIDs,
            activeIndex: 1,
            activeTrackID: "second",
            position: 0.321,
            playWhenReady: true,
            volume: initial.volume,
            rate: initial.rate,
            repeatMode: initial.repeatMode,
            transitionGeneration: initial.transitionGeneration
        )
        let old = FakeBackend(kind: .standard, snapshot: initial, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        var didAdvance = false
        factory.prepareHook = {
            guard !didAdvance else { return }
            didAdvance = true
            old.simulateNaturalSnapshot(advanced)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, advanced)
        XCTAssertEqual(factory.created.first?.restoredSnapshots.last, advanced)
        XCTAssertEqual(factory.created.first?.restoredSnapshot?.activeTrackID, "second")
        XCTAssertTrue(old.calls.contains("beginHandoffQuiescence"))
    }

    func test_queueObjectsAndIDsMutatedDuringWarmupAreRebasedBeforeCommit() {
        let oldObject = NSObject()
        let freshFirst = NSObject()
        let freshSecond = NSObject()
        let shared = SharedPlaybackResource(queue: [oldObject])
        let initial = PlaybackBackendSnapshot(
            queueIDs: ["old"],
            activeIndex: 0,
            activeTrackID: "old",
            position: 12,
            playWhenReady: true,
            volume: 0.6,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 2
        )
        let fresh = PlaybackBackendSnapshot(
            queueIDs: ["fresh-first", "fresh-second"],
            activeIndex: 1,
            activeTrackID: "fresh-second",
            position: 0.4,
            playWhenReady: true,
            volume: 0.6,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 3
        )
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: initial,
            audible: true,
            sharedResource: shared,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory(sharedResource: shared)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        var didMutate = false
        factory.prepareHook = {
            guard !didMutate else { return }
            didMutate = true
            shared.queue = [freshFirst, freshSecond]
            old.simulateNaturalSnapshot(fresh)
        }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, fresh)
        let candidate = factory.created.first!
        XCTAssertEqual(candidate.preparedSnapshots, [initial, fresh])
        XCTAssertEqual(candidate.committedQueue, fresh.queueIDs)
        XCTAssertEqual(candidate.preparedSharedQueues.first?.count, 1)
        XCTAssertTrue(candidate.preparedSharedQueues.first?.first === oldObject)
        XCTAssertEqual(candidate.preparedSharedQueues.last?.count, 2)
        XCTAssertTrue(candidate.preparedSharedQueues.last?[0] === freshFirst)
        XCTAssertTrue(candidate.preparedSharedQueues.last?[1] === freshSecond)
    }

    func test_standardCandidateAcceptsIdleNonemptyQueueWithoutActiveIndex() {
        let idle = PlaybackBackendSnapshot(
            queueIDs: ["queued"],
            activeIndex: nil,
            activeTrackID: nil,
            position: 0,
            playWhenReady: false,
            volume: 0.8,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 9
        )
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: idle,
            audible: false,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        factory.activationHook = { _ in
            try validateStandardPlaybackActivationSnapshot(idle, queueCount: 1)
        }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, idle)
        XCTAssertEqual(factory.created.first?.restoredSnapshot, idle)
        XCTAssertEqual(factory.created.first?.committedQueue, ["queued"])
        XCTAssertFalse(factory.created.first?.audible == true)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: factory.created.first!))
    }

    func test_standardActivationValidatorRejectsMissingOrMismatchedActiveTrackIdentity() {
        let missingIdentity = PlaybackBackendSnapshot(
            queueIDs: ["expected"],
            activeIndex: 0,
            activeTrackID: nil,
            position: 0,
            playWhenReady: false,
            volume: 1,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 0
        )
        let mismatchedIdentity = PlaybackBackendSnapshot(
            queueIDs: ["expected"],
            activeIndex: 0,
            activeTrackID: "different",
            position: 0,
            playWhenReady: false,
            volume: 1,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 0
        )

        XCTAssertThrowsError(
            try validateStandardPlaybackActivationSnapshot(missingIdentity, queueCount: 1)
        )
        XCTAssertThrowsError(
            try validateStandardPlaybackActivationSnapshot(mismatchedIdentity, queueCount: 1)
        )
    }

    func test_finalRebaseFailureResumesOldBeforeQueuedCommandRuns() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap rejected")
        let commandFinished = DispatchSemaphore(value: 0)
        var swapResult: Result<PlaybackBackendTransactionResult, Error>?
        var commandBackend: PlaybackBackend?
        var oldWasAudibleWhenCommandStarted = false
        var oldControlWasActiveDuringFinalRebase = false
        var oldControlWasActiveWhenCommandStarted = false
        factory.activationHook = { call in
            guard call == 2 else { return }
            oldControlWasActiveDuringFinalRebase = old.controlSurfaceActive
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
            throw FakeError.restore
        }

        facade.setPlaybackBackend(.pingPong) {
            swapResult = $0
            swapFinished.fulfill()
        }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendAsync({ backend, completion in
            commandBackend = backend
            oldWasAudibleWhenCommandStarted = old.audible
            oldControlWasActiveWhenCommandStarted = old.controlSurfaceActive
            backend.pause()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in
            commandFinished.signal()
        }
        XCTAssertEqual(
            commandFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "admission must remain closed during the final rebase"
        )
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(commandFinished.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(try swapResult?.get())
        XCTAssertTrue(commandBackend === old)
        XCTAssertTrue(oldWasAudibleWhenCommandStarted)
        XCTAssertTrue(oldControlWasActiveDuringFinalRebase)
        XCTAssertTrue(oldControlWasActiveWhenCommandStarted)
        XCTAssertTrue(old.calls.contains("cancelHandoffQuiescence"))
        XCTAssertEqual(old.calls.filter { $0 == "resumeEventDeliveryAfterHandoff" }.count, 1)
        XCTAssertEqual(old.canonicalResumeCount, 1)
        XCTAssertLessThan(
            old.calls.firstIndex(of: "cancelHandoffQuiescence")!,
            old.calls.firstIndex(of: "pause")!
        )
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: old))
        XCTAssertFalse(factory.created.first?.calls.contains("commitQueue") == true)
    }

    func test_commandsStayBlockedDuringFinalRebaseAndRunOnCommittedReplacement() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap committed")
        let commandFinished = DispatchSemaphore(value: 0)
        var commandBackend: PlaybackBackend?
        var oldControlWasActiveDuringFinalRebase = false
        factory.activationHook = { call in
            guard call == 2 else { return }
            oldControlWasActiveDuringFinalRebase = old.controlSurfaceActive
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
        }

        facade.setPlaybackBackend(.pingPong) { _ in swapFinished.fulfill() }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendAsync({ backend, completion in
            commandBackend = backend
            backend.pause()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in
            commandFinished.signal()
        }
        XCTAssertEqual(commandFinished.wait(timeout: .now() + 0.05), .timedOut)
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(commandFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(commandBackend === factory.created.first)
        XCTAssertTrue(facade.currentBackend === factory.created.first)
        XCTAssertTrue(old.calls.contains("beginHandoffQuiescence"))
        XCTAssertTrue(oldControlWasActiveDuringFinalRebase)
    }

    func test_readDuringFinalHandoffWaitsAndRunsOnCommittedReplacement() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap committed")
        let readFinished = DispatchSemaphore(value: 0)
        var readBackend: PlaybackBackendKind?
        factory.activationHook = { call in
            guard call == 2 else { return }
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
        }

        facade.setPlaybackBackend(.pingPong) { _ in swapFinished.fulfill() }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendRead({ $0.kind }) { result in
            readBackend = try? result.get()
            readFinished.signal()
        }
        XCTAssertEqual(readFinished.wait(timeout: .now() + 0.05), .timedOut)
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(readBackend, .pingPong)
    }

    func test_readDoesNotInvalidateCandidatePreparationVersion() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let readFinished = DispatchSemaphore(value: 0)
        var didRead = false
        factory.prepareHook = {
            guard !didRead else { return }
            didRead = true
            facade.withCurrentBackendRead({ $0.kind }) { result in
                XCTAssertEqual(try? result.get(), .standard)
                readFinished.signal()
            }
            XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(factory.created.count, 1)
    }

    func test_readDuringFailedFinalHandoffWaitsAndRunsOnRolledBackBackend() {
        let old = FakeBackend(kind: .pingPong, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap rejected")
        let readFinished = DispatchSemaphore(value: 0)
        var readBackend: PlaybackBackendKind?
        factory.activationHook = { call in
            guard call == 2 else { return }
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
            throw FakeError.restore
        }

        facade.setPlaybackBackend(.standard) { _ in swapFinished.fulfill() }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendRead({ $0.kind }) { result in
            readBackend = try? result.get()
            readFinished.signal()
        }
        XCTAssertEqual(readFinished.wait(timeout: .now() + 0.05), .timedOut)
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(readBackend, .pingPong)
        XCTAssertTrue(facade.currentBackend === old)
    }

    func test_rollbackFailureIsSanitizedAfterCanonicalSurfaceIsRestored() {
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: snapshot,
            audible: true,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        factory.activationHook = { call in
            if call == 2 { throw FakeError.restore }
        }
        old.cancelHook = { throw FakeError.secretDisposalDetail }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertThrowsError(try result.get()) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.userInfo["code"] as? String, "playback_backend_rollback_failed")
            XCTAssertFalse(nsError.localizedDescription.contains("secret"))
        }
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: old))
        XCTAssertTrue(old.controlSurfaceActive)
        XCTAssertEqual(old.canonicalResumeCount, 1)
        XCTAssertEqual(old.calls.filter { $0 == "resumeEventDeliveryAfterHandoff" }.count, 1)
        XCTAssertFalse(factory.created.first?.calls.contains("commitQueue") == true)
    }

    func test_handoffPhaseOrderQuarantinesTransientEventsAndDisposesAfterRelease() {
        let trace = TransactionTrace()
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let disposed = expectation(description: "old backend disposed")
        old.phaseHook = { _, phase in
            trace.append(phase == "eventQuarantine" ? "barrier/eventQuarantine" : "old.\(phase)")
        }
        old.disposeHook = { disposed.fulfill() }
        factory.phaseHook = { _, phase in trace.append("new.\(phase)") }
        factory.postCommitActivationHook = { replacement in
            XCTAssertTrue(facade.currentBackend === replacement)
            XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: replacement))
            trace.append("pointer/authority")
        }

        let result = awaitResult { completion in
            facade.setPlaybackBackend(.pingPong) { transactionResult in
                trace.append("release")
                completion(transactionResult)
            }
        }
        wait(for: [disposed], timeout: 1)

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(trace.values, [
            "old.settle",
            "old.snapshot",
            "new.prepare",
            "new.restore",
            "new.ready",
            "barrier/eventQuarantine",
            "old.quiesce",
            "new.prepare",
            "new.restore",
            "new.ready",
            "old.suspendControl",
            "old.relinquish",
            "new.commitQueue",
            "pointer/authority",
            "new.activate",
            "release",
            "old.dispose"
        ])
        XCTAssertEqual(old.transientEventCount, 0)
        XCTAssertEqual(factory.created.first?.canonicalStateCount, 1)
    }

    func test_continuouslyStalePreparationIsBoundedAndKeepsOldOwner() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let lock = NSLock()
        var position = snapshot.position

        factory.restoreHook = {
            let commandEntered = DispatchSemaphore(value: 0)
            facade.withCurrentBackendAsync({ backend, completion in
                lock.lock()
                position += 1
                let nextPosition = position
                lock.unlock()
                try backend.seek(to: nextPosition)
                commandEntered.signal()
                completion(.success(()))
            }) { (_: Result<Void, Error>) in }
            XCTAssertEqual(commandEntered.wait(timeout: .now() + 0.05), .success)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual((error as NSError).userInfo["code"] as? String, "playback_backend_busy")
        }
        XCTAssertEqual(factory.created.count, 8)
        XCTAssertTrue(factory.created.allSatisfy(\.disposed))
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: old))
        XCTAssertTrue(old.audible)
    }

    func test_initialBackendActivatesAndPublishesExactIdentity() {
        let initial = FakeBackend(kind: .standard, snapshot: snapshot)
        let authority = PlaybackBackendAuthority()
        var authorityWasPublishedAtActivation = false
        initial.initialActivationHook = {
            authorityWasPublishedAtActivation = authority.isAuthoritative(.standard, identity: initial)
        }

        _ = PlaybackBackendFacade(
            initial: initial,
            factory: FakeFactory(),
            authority: authority
        )

        XCTAssertEqual(initial.calls, ["activateInitialControlSurface"])
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: initial))
        XCTAssertTrue(authorityWasPublishedAtActivation)
    }

    func test_authorityRejectsSameKindStaleIdentity() {
        let first = FakeBackend(kind: .standard, snapshot: snapshot)
        let current = FakeBackend(kind: .standard, snapshot: snapshot)
        let authority = PlaybackBackendAuthority()

        authority.publish(first)
        authority.publish(current)

        XCTAssertFalse(authority.isAuthoritative(.standard, identity: first))
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: current))
        XCTAssertEqual(authority.currentIdentity, ObjectIdentifier(current))
    }

    func test_standardPingPongStandardRejectsStaleGenerations() {
        let first = FakeBackend(kind: .standard, snapshot: snapshot)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: first, factory: factory, authority: authority)

        _ = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }
        let pingPong = factory.created[0]
        _ = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }
        let current = factory.created[1]

        XCTAssertFalse(authority.isAuthoritative(.standard, identity: first))
        XCTAssertFalse(authority.isAuthoritative(.pingPong, identity: pingPong))
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: current))
        XCTAssertFalse(first === current)
    }

    func test_restoreFailureKeepsExactPreviousGenerationWithoutRestoringOld() {
        let previous = FakeBackend(kind: .pingPong, snapshot: snapshot, initiallyAuthoritative: true)
        let factory = FakeFactory(failRestore: true)
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: previous, factory: factory, authority: authority)

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: previous))
        XCTAssertFalse(authority.isAuthoritative(.standard, identity: factory.created[0]))
        XCTAssertFalse(previous.calls.contains("restore"))
        XCTAssertFalse(previous.calls.contains("resumeControlSurface"))
    }

    func test_sameTargetIsNoOpAndPreservesGeneration() {
        let initial = FakeBackend(kind: .standard, snapshot: snapshot)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: initial, factory: factory, authority: authority)

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .standard)
        XCTAssertTrue(facade.currentBackend === initial)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: initial))
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertFalse(initial.calls.contains("settle"))
    }

    func test_sameTargetWaitsForActiveLeaseWithoutSettlingIt() {
        let initial = FakeBackend(kind: .pingPong, snapshot: snapshot)
        let facade = PlaybackBackendFacade(initial: initial, factory: FakeFactory())
        let leaseStarted = DispatchSemaphore(value: 0)
        let leaseFinished = expectation(description: "lease finished")
        let sameTargetFinished = DispatchSemaphore(value: 0)
        var deferredCompletion: ((Result<Void, Error>) -> Void)?
        var sameTargetResult: Result<PlaybackBackendTransactionResult, Error>?

        facade.withCurrentBackendAsync({ _, completion in
            deferredCompletion = completion
            leaseStarted.signal()
        }) { (_: Result<Void, Error>) in leaseFinished.fulfill() }
        XCTAssertEqual(leaseStarted.wait(timeout: .now() + 1), .success)
        facade.setPlaybackBackend(.pingPong) {
            sameTargetResult = $0
            sameTargetFinished.signal()
        }

        XCTAssertEqual(sameTargetFinished.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertFalse(initial.calls.contains("settle"))
        deferredCompletion?(.success(()))
        wait(for: [leaseFinished], timeout: 1)
        XCTAssertEqual(sameTargetFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try? sameTargetResult?.get().snapshot, snapshot)
        XCTAssertFalse(initial.calls.contains("settle"))
    }

    func test_commandsDoNotWaitForPostCommitDisposalAndRouteReplacement() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let disposeEntered = DispatchSemaphore(value: 0)
        let releaseDispose = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap finished")
        let commandFinished = expectation(description: "command finished")
        let commandEntered = DispatchSemaphore(value: 0)
        var routedBackend: PlaybackBackend?
        old.disposeHook = {
            disposeEntered.signal()
            releaseDispose.wait()
        }

        facade.setPlaybackBackend(.pingPong) { _ in swapFinished.fulfill() }
        XCTAssertEqual(disposeEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendAsync({ backend, completion in
            routedBackend = backend
            backend.pause()
            commandEntered.signal()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in commandFinished.fulfill() }

        XCTAssertEqual(commandEntered.wait(timeout: .now() + 1), .success)
        wait(for: [swapFinished, commandFinished], timeout: 1)
        XCTAssertTrue(routedBackend === factory.created.first)
        releaseDispose.signal()
    }

    func test_repeatedSwapsPublishOnlyLatestGeneration() {
        let initial = FakeBackend(kind: .standard, snapshot: snapshot)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: initial, factory: factory, authority: authority)

        for index in 0..<12 {
            let kind: PlaybackBackendKind = index.isMultiple(of: 2) ? .pingPong : .standard
            _ = awaitResult { facade.setPlaybackBackend(kind, completion: $0) }
        }

        let current = facade.currentBackend
        let disposalDeadline = Date().addingTimeInterval(1)
        while !factory.created.dropLast().allSatisfy(\.disposed), Date() < disposalDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(current.kind, .standard)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: current.identity))
        XCTAssertEqual(factory.created.count, 12)
        XCTAssertTrue(factory.created.dropLast().allSatisfy { $0.disposed })
    }

    func test_incomingQueueRestorePreservesTrackObjectIdentity() {
        let first = NSObject()
        let second = NSObject()
        let candidateOwnedObject = NSObject()

        let restored = playbackBackendQueueForRestore(
            incoming: [first, second],
            current: { [candidateOwnedObject] }
        )

        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored[0] === first)
        XCTAssertTrue(restored[1] === second)
        XCTAssertFalse(restored.contains { $0 === candidateOwnedObject })
    }

    func test_incomingQueueProviderReadsLatestTrackObjectsForFinalRebase() {
        let initial = NSObject()
        let freshFirst = NSObject()
        let freshSecond = NSObject()
        let candidateOwnedObject = NSObject()
        var incoming = [initial]
        let provider = { incoming }

        let warmup = playbackBackendQueueForRestore(
            incomingProvider: provider,
            current: { [candidateOwnedObject] }
        )
        incoming = [freshFirst, freshSecond]
        let final = playbackBackendQueueForRestore(
            incomingProvider: provider,
            current: { [candidateOwnedObject] }
        )

        XCTAssertEqual(warmup.count, 1)
        XCTAssertTrue(warmup[0] === initial)
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final[0] === freshFirst)
        XCTAssertTrue(final[1] === freshSecond)
        XCTAssertFalse(final.contains { $0 === candidateOwnedObject })
    }

    func test_activationRunsOnlyAfterFacadeAndAuthorityPublication() {
        let old = PhasedBackend(kind: .standard, snapshot: snapshot)
        let factory = PhasedFactory(snapshot: snapshot)
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        var facadeWasReplacementAtActivation = false
        var authorityWasReplacementAtActivation = false
        factory.activationHook = { replacement in
            facadeWasReplacementAtActivation = facade.currentBackend === replacement
            authorityWasReplacementAtActivation = authority.isAuthoritative(
                .pingPong,
                identity: replacement
            )
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(factory.created.first?.activationCalls, 1)
        XCTAssertTrue(facadeWasReplacementAtActivation)
        XCTAssertTrue(authorityWasReplacementAtActivation)
        XCTAssertEqual(factory.created.first?.calls, [
            "prepare", "restore", "prepare", "restore", "commitQueue", "activateAfterCommit"
        ])
    }

    func test_rollbackPreservesPreviousAuthoritativeQueueWithoutCandidateCommit() {
        let old = StatefulIOSBackend(
            kind: .standard,
            snapshot: snapshot,
            authoritativeQueue: snapshot.queueIDs,
            failRelinquish: true
        )
        let facade = PlaybackBackendFacade(
            initial: old,
            factory: StatefulIOSFactory(snapshot: snapshot)
        )

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(old.authoritativeQueue, snapshot.queueIDs)
        XCTAssertEqual(old.commitCalls, 0)
        XCTAssertEqual(old.rollbackCalls, 1)
    }

    func test_uncommittedSharedPlayerCandidateCleanupDoesNotClearOldRemoteCommands() {
        let shared = SharedControlSurface()
        let old = SharedPlayerBackend(
            kind: .standard,
            snapshot: snapshot,
            shared: shared,
            initiallyAuthoritative: true
        )
        let factory = SharedPlayerFactory(snapshot: snapshot, shared: shared, failRestore: true)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(shared.remoteCommandsInstalled)
        XCTAssertTrue(facade.currentBackend === old)
    }

    func test_staleAsyncEventDeliveryCannotCrossListenerTokenGeneration() {
        let stale = PlaybackBackendEventToken()
        stale.activate()
        let queuedDelivery = { stale.acceptsDelivery }
        stale.invalidate()

        let current = PlaybackBackendEventToken()
        current.activate()

        XCTAssertFalse(queuedDelivery())
        XCTAssertTrue(current.acceptsDelivery)
    }

    func test_operationInvalidationResolvesBlockedCallbackExactlyOnce() {
        let registry = PlaybackBackendOperationRegistry()
        var cancellations: [String] = []
        let ticket = registry.begin { reason in cancellations.append(reason) }

        registry.invalidateAll(reason: "pause")
        registry.invalidateAll(reason: "stop")

        XCTAssertFalse(registry.isCurrent(ticket))
        XCTAssertEqual(cancellations, ["pause"])
    }

    func test_operationRegistryAllowsSynchronousTerminalCallbackWithoutDeadlock() {
        let registry = PlaybackBackendOperationRegistry()
        let ticket = registry.begin { _ in XCTFail("ticket should not be cancelled") }

        let entered = registry.performIfCurrent(ticket) {
            XCTAssertTrue(registry.complete(ticket))
        }

        XCTAssertTrue(entered)
        XCTAssertFalse(registry.isCurrent(ticket))
    }

    func test_operationRegistryCompletionCannotEraseReentrantReplacementTicket() {
        let registry = PlaybackBackendOperationRegistry()
        let first = registry.begin { _ in XCTFail("completed ticket should not be cancelled") }
        var second: PlaybackBackendOperationTicket?

        XCTAssertTrue(registry.complete(first) {
            second = registry.begin { _ in }
        })

        XCTAssertNotNil(second)
        XCTAssertTrue(registry.isCurrent(second!))
    }

    func test_operationRegistryRunsDeferredTerminalCallbackOutsideOutermostLock() {
        let registry = PlaybackBackendOperationRegistry()
        let ticket = registry.begin { _ in XCTFail("ticket should not be cancelled") }
        let callbackFinished = expectation(description: "terminal callback")
        var callbackRanDuringMutation = false

        XCTAssertTrue(registry.performIfCurrent(ticket) {
            registry.performAfterCurrentMutation {
                let otherThreadFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = registry.isCurrent(ticket)
                    otherThreadFinished.signal()
                }
                XCTAssertEqual(otherThreadFinished.wait(timeout: .now() + 1), .success)
                callbackFinished.fulfill()
            }
            callbackRanDuringMutation = true
        })

        XCTAssertTrue(callbackRanDuringMutation)
        wait(for: [callbackFinished], timeout: 2)
    }

    func test_operationRegistryCompleteDefersExternalCallbackOutsideLock() {
        let registry = PlaybackBackendOperationRegistry()
        let ticket = registry.begin { _ in XCTFail("ticket should not be cancelled") }
        let callbackFinished = expectation(description: "complete callback")

        XCTAssertTrue(registry.complete(ticket) {
            registry.performAfterCurrentMutation {
                let workerFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = registry.isCurrent(ticket)
                    workerFinished.signal()
                }
                XCTAssertEqual(workerFinished.wait(timeout: .now() + 1), .success)
                callbackFinished.fulfill()
            }
        })

        wait(for: [callbackFinished], timeout: 2)
    }

    func test_exclusiveCommandSlotRejectsSecondWithoutReplacingFirstCompletion() {
        let slot = PlaybackBackendExclusiveCommandSlot<Void>()
        var firstResults = 0
        var secondResults = 0
        let first = slot.begin { _ in firstResults += 1 }

        let rejectedSecond = slot.begin { _ in secondResults += 1 }

        XCTAssertNotNil(first)
        XCTAssertNil(rejectedSecond)
        slot.complete(first!, result: .success(()))
        slot.complete(first!, result: .success(()))
        XCTAssertEqual(firstResults, 1)
        XCTAssertEqual(secondResults, 0)
        XCTAssertFalse(slot.isOccupied)
    }

    func test_exclusiveCommandSlotCompletionCanReenterSlotAfterUnlock() {
        let slot = PlaybackBackendExclusiveCommandSlot<Void>()
        var replacement: PlaybackBackendCommandCompletion<Void>?
        let first = slot.begin { _ in
            replacement = slot.begin { _ in }
        }

        slot.complete(first!, result: .success(()))

        XCTAssertNotNil(replacement)
        XCTAssertTrue(slot.isOccupied)
        slot.complete(replacement!, result: .success(()))
        XCTAssertFalse(slot.isOccupied)
    }

    func test_productionAdapterQueueStateKeepsAuthoritativeQueueOnRollback() {
        let state = PlaybackBackendQueueState(["old-a", "old-b"])
        state.stage(["candidate-a"])

        XCTAssertEqual(state.rollback(), ["old-a", "old-b"])
        XCTAssertEqual(state.authoritative, ["old-a", "old-b"])
    }

    private func awaitResult(
        _ operation: (@escaping (Result<PlaybackBackendTransactionResult, Error>) -> Void) -> Void
    ) -> Result<PlaybackBackendTransactionResult, Error> {
        let finished = expectation(description: "transaction")
        var captured: Result<PlaybackBackendTransactionResult, Error>!
        operation {
            captured = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        return captured
    }
}

private final class PhasedFactory: PlaybackBackendFactory {
    private let snapshot: PlaybackBackendSnapshot
    var activationHook: ((PhasedBackend) -> Void)?
    private(set) var created: [PhasedBackend] = []

    init(snapshot: PlaybackBackendSnapshot) { self.snapshot = snapshot }

    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        let backend = PhasedBackend(kind: kind, snapshot: snapshot)
        backend.activationHook = { [weak self, weak backend] in
            guard let self, let backend else { return }
            self.activationHook?(backend)
        }
        created.append(backend)
        return backend
    }
}

private final class PhasedBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private let snapshotValue: PlaybackBackendSnapshot
    var activationHook: (() -> Void)?
    private(set) var calls: [String] = []
    private(set) var activationCalls = 0

    init(kind: PlaybackBackendKind, snapshot: PlaybackBackendSnapshot) {
        self.kind = kind
        self.snapshotValue = snapshot
    }

    func settleActiveTransition() throws {}
    func snapshot() throws -> PlaybackBackendSnapshot { snapshotValue }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws { calls.append("prepare") }
    func restore(_ snapshot: PlaybackBackendSnapshot) throws { calls.append("restore") }
    func stopAndMute() throws {}
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) { calls.append("commitQueue") }
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("activateAfterCommit")
        activationCalls += 1
        activationHook?()
    }
    func play() throws {}
    func pause() {}
    func seek(to position: Double) throws {}
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {}
}

private final class StatefulIOSFactory: PlaybackBackendFactory {
    private let snapshot: PlaybackBackendSnapshot
    init(snapshot: PlaybackBackendSnapshot) { self.snapshot = snapshot }
    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        StatefulIOSBackend(kind: kind, snapshot: snapshot, authoritativeQueue: [])
    }
}

private final class StatefulIOSBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private let snapshotValue: PlaybackBackendSnapshot
    private let failRelinquish: Bool
    private var pendingQueue: [String] = []
    private(set) var authoritativeQueue: [String]
    private(set) var commitCalls = 0
    private(set) var rollbackCalls = 0

    init(
        kind: PlaybackBackendKind,
        snapshot: PlaybackBackendSnapshot,
        authoritativeQueue: [String],
        failRelinquish: Bool = false
    ) {
        self.kind = kind
        self.snapshotValue = snapshot
        self.authoritativeQueue = authoritativeQueue
        self.failRelinquish = failRelinquish
    }

    func settleActiveTransition() throws {}
    func snapshot() throws -> PlaybackBackendSnapshot { snapshotValue }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws { pendingQueue = snapshot.queueIDs }
    func restore(_ snapshot: PlaybackBackendSnapshot) throws {}
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) { rollbackCalls += 1 }
    func stopAndMute() throws {}
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {
        if failRelinquish { throw FakeError.restore }
    }
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {
        commitCalls += 1
        authoritativeQueue = pendingQueue
    }
    func play() throws {}
    func pause() {}
    func seek(to position: Double) throws {}
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {}
}

private final class SharedControlSurface {
    var remoteCommandsInstalled = true
}

private final class SharedPlayerFactory: PlaybackBackendFactory {
    private let snapshot: PlaybackBackendSnapshot
    private let shared: SharedControlSurface
    private let failRestore: Bool

    init(snapshot: PlaybackBackendSnapshot, shared: SharedControlSurface, failRestore: Bool) {
        self.snapshot = snapshot
        self.shared = shared
        self.failRestore = failRestore
    }

    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        SharedPlayerBackend(
            kind: kind,
            snapshot: snapshot,
            shared: shared,
            failRestore: failRestore
        )
    }
}

private final class SharedPlayerBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private let snapshotValue: PlaybackBackendSnapshot
    private let shared: SharedControlSurface
    private let failRestore: Bool
    private let initiallyAuthoritative: Bool

    init(
        kind: PlaybackBackendKind,
        snapshot: PlaybackBackendSnapshot,
        shared: SharedControlSurface,
        failRestore: Bool = false,
        initiallyAuthoritative: Bool = false
    ) {
        self.kind = kind
        self.snapshotValue = snapshot
        self.shared = shared
        self.failRestore = failRestore
        self.initiallyAuthoritative = initiallyAuthoritative
    }

    func settleActiveTransition() throws {}
    func snapshot() throws -> PlaybackBackendSnapshot { snapshotValue }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws {}
    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        if failRestore { throw FakeError.restore }
    }
    func stopAndMute() throws {}
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {}
    func play() throws {}
    func pause() {}
    func seek(to position: Double) throws {}
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {
        if initiallyAuthoritative { shared.remoteCommandsInstalled = false }
    }
}

private final class AudibleRegistry {
    var backends: [FakeBackend] = []
    var counts: [Int] = []
}

private final class FakeFactory: PlaybackBackendFactory {
    private let registry: AudibleRegistry?
    private let failPrepare: Bool
    private let failRestore: Bool
    private let barrier: TransactionBarrier?
    private let sharedResource: SharedPlaybackResource?
    private let mutateSharedOnRestore: Bool
    private(set) var created: [FakeBackend] = []
    private(set) var requested: [PlaybackBackendKind] = []
    var prepareHook: (() -> Void)?
    var restoreHook: (() -> Void)?
    var commitHook: (() -> Void)?
    var activationHook: ((Int) throws -> Void)?
    var phaseHook: ((PlaybackBackendKind, String) -> Void)?
    var postCommitActivationHook: ((FakeBackend) -> Void)?

    init(
        registry: AudibleRegistry? = nil,
        failPrepare: Bool = false,
        failRestore: Bool = false,
        barrier: TransactionBarrier? = nil,
        sharedResource: SharedPlaybackResource? = nil,
        mutateSharedOnRestore: Bool = false
    ) {
        self.registry = registry
        self.failPrepare = failPrepare
        self.failRestore = failRestore
        self.barrier = barrier
        self.sharedResource = sharedResource
        self.mutateSharedOnRestore = mutateSharedOnRestore
    }

    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        requested.append(kind)
        let backend = FakeBackend(
            kind: kind,
            snapshot: .empty,
            registry: registry,
            failPrepare: failPrepare,
            failRestore: failRestore,
            barrier: barrier,
            sharedResource: sharedResource,
            mutateSharedOnRestore: mutateSharedOnRestore,
            prepareHook: prepareHook,
            restoreHook: restoreHook,
            commitHook: commitHook,
            activationHook: activationHook,
            phaseHook: phaseHook,
            postCommitActivationHook: postCommitActivationHook
        )
        created.append(backend)
        registry?.backends.append(backend)
        return backend
    }
}

private final class FakeBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private var snapshotValue: PlaybackBackendSnapshot
    private let registry: AudibleRegistry?
    private let failPrepare: Bool
    private let failRestore: Bool
    private let failDispose: Bool
    private let barrier: TransactionBarrier?
    private let sharedResource: SharedPlaybackResource?
    private let mutateSharedOnRestore: Bool
    private let prepareHook: (() -> Void)?
    private let restoreHook: (() -> Void)?
    private let commitHook: (() -> Void)?
    private let activationHook: ((Int) throws -> Void)?
    private let postCommitActivationHook: ((FakeBackend) -> Void)?
    private var capturedSharedQueue: [AnyObject] = []
    private var isAuthoritative: Bool
    private(set) var calls: [String] = []
    private(set) var restoredSnapshot: PlaybackBackendSnapshot?
    private(set) var restoredSnapshots: [PlaybackBackendSnapshot] = []
    private(set) var preparedSnapshots: [PlaybackBackendSnapshot] = []
    private(set) var preparedSharedQueues: [[AnyObject]] = []
    private(set) var committedQueue: [String]?
    private(set) var disposed = false
    private(set) var audible: Bool
    private(set) var controlSurfaceActive: Bool
    private(set) var canonicalResumeCount = 0
    private(set) var canonicalStateCount = 0
    private(set) var transientEventCount = 0
    private var activationCallCount = 0
    private var eventDeliverySuspended = false
    var settleHook: (() -> Void)?
    var disposeHook: (() -> Void)?
    var initialActivationHook: (() -> Void)?
    var cancelHook: (() throws -> Void)?
    var phaseHook: ((PlaybackBackendKind, String) -> Void)?

    init(
        kind: PlaybackBackendKind,
        snapshot: PlaybackBackendSnapshot,
        audible: Bool = false,
        registry: AudibleRegistry? = nil,
        failPrepare: Bool = false,
        failRestore: Bool = false,
        failDispose: Bool = false,
        barrier: TransactionBarrier? = nil,
        sharedResource: SharedPlaybackResource? = nil,
        mutateSharedOnRestore: Bool = false,
        initiallyAuthoritative: Bool = false,
        prepareHook: (() -> Void)? = nil,
        restoreHook: (() -> Void)? = nil,
        commitHook: (() -> Void)? = nil,
        activationHook: ((Int) throws -> Void)? = nil,
        phaseHook: ((PlaybackBackendKind, String) -> Void)? = nil,
        postCommitActivationHook: ((FakeBackend) -> Void)? = nil
    ) {
        self.kind = kind
        self.snapshotValue = snapshot
        self.audible = audible
        self.controlSurfaceActive = initiallyAuthoritative
        self.registry = registry
        self.failPrepare = failPrepare
        self.failRestore = failRestore
        self.failDispose = failDispose
        self.barrier = barrier
        self.sharedResource = sharedResource
        self.mutateSharedOnRestore = mutateSharedOnRestore
        self.isAuthoritative = initiallyAuthoritative
        self.prepareHook = prepareHook
        self.restoreHook = restoreHook
        self.commitHook = commitHook
        self.activationHook = activationHook
        self.phaseHook = phaseHook
        self.postCommitActivationHook = postCommitActivationHook
    }

    func settleActiveTransition() throws {
        calls.append("settle")
        phaseHook?(kind, "settle")
        settleHook?()
    }
    func activateInitialControlSurface() {
        calls.append("activateInitialControlSurface")
        controlSurfaceActive = true
        initialActivationHook?()
    }
    func suspendEventDeliveryForHandoff() throws {
        calls.append("suspendEventDeliveryForHandoff")
        eventDeliverySuspended = true
        phaseHook?(kind, "eventQuarantine")
    }
    func resumeEventDeliveryAfterHandoff(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("resumeEventDeliveryAfterHandoff")
        eventDeliverySuspended = false
        phaseHook?(kind, "resumeEventDelivery")
        resumeControlSurface(snapshot)
    }
    func suspendControlSurface() throws {
        calls.append("suspendControlSurface")
        controlSurfaceActive = false
        phaseHook?(kind, "suspendControl")
    }
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("resumeControlSurface")
        controlSurfaceActive = true
        canonicalResumeCount += 1
    }
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {
        calls.append("relinquishExclusiveControlSurfaceBeforeCommit")
        phaseHook?(kind, "relinquish")
    }
    func snapshot() throws -> PlaybackBackendSnapshot {
        calls.append("snapshot")
        phaseHook?(kind, "snapshot")
        capturedSharedQueue = sharedResource?.queue ?? []
        return snapshotValue
    }
    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot {
        calls.append("beginHandoffQuiescence")
        if !eventDeliverySuspended { transientEventCount += 2 }
        phaseHook?(kind, "quiesce")
        setAudible(false)
        return snapshotValue
    }
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("cancelHandoffQuiescence")
        phaseHook?(kind, "cancelQuiescence")
        try cancelHook?()
        snapshotValue = snapshot
        setAudible(snapshot.playWhenReady)
    }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("prepare")
        phaseHook?(kind, "prepare")
        preparedSnapshots.append(snapshot)
        preparedSharedQueues.append(sharedResource?.queue ?? [])
        setAudible(false)
        prepareHook?()
        barrier?.enter(kind)
        if failPrepare { throw FakeError.prepare }
    }
    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("restore")
        phaseHook?(kind, "restore")
        restoreHook?()
        if mutateSharedOnRestore && !isAuthoritative {
            sharedResource?.queue = []
        }
        if failRestore { throw FakeError.restore }
        if isAuthoritative {
            sharedResource?.queue = capturedSharedQueue
        }
        snapshotValue = snapshot
        restoredSnapshot = snapshot
        restoredSnapshots.append(snapshot)
        barrier?.exit(kind)
    }
    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws {
        activationCallCount += 1
        calls.append("prepareActivation")
        phaseHook?(kind, "ready")
        try activationHook?(activationCallCount)
    }
    func stopAndMute() throws { calls.append("stopAndMute"); setAudible(false) }
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("commitQueue")
        phaseHook?(kind, "commitQueue")
        commitHook?()
        committedQueue = snapshot.queueIDs
        isAuthoritative = true
    }
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {
        postCommitActivationHook?(self)
        calls.append("activateAfterCommit")
        canonicalStateCount += 1
        phaseHook?(kind, "activate")
        setAudible(snapshot.playWhenReady)
    }
    func play() throws { setAudible(true) }
    func pause() {
        calls.append("pause")
        snapshotValue = snapshotValue.with(playWhenReady: false)
        setAudible(false)
    }
    func seek(to position: Double) throws { snapshotValue = snapshotValue.with(position: position) }
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {
        phaseHook?(kind, "dispose")
        disposeHook?()
        disposed = true
        isAuthoritative = false
        calls.append("dispose")
        if failDispose { throw FakeError.secretDisposalDetail }
    }

    func simulateNaturalSnapshot(_ snapshot: PlaybackBackendSnapshot) {
        snapshotValue = snapshot
    }

    private func setAudible(_ value: Bool) {
        audible = value
        if let registry = registry {
            registry.counts.append(registry.backends.filter { $0.audible }.count)
        }
    }
}

private final class SharedPlaybackResource {
    var queue: [AnyObject]

    init(queue: [AnyObject]) {
        self.queue = queue
    }
}

private final class TransactionTrace {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        let result = recorded
        lock.unlock()
        return result
    }
}

private enum FakeError: Error {
    case prepare
    case restore
    case cancelled
    case secretDisposalDetail
}

private final class TransactionBarrier {
    let firstPrepareEntered = DispatchSemaphore(value: 0)
    let releaseFirstPrepare = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inFlight = 0
    private var first = true
    private(set) var maxInFlight = 0
    private(set) var trace: [String] = []

    func enter(_ kind: PlaybackBackendKind) {
        lock.lock()
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        trace.append("enter:\(kind.rawValue)")
        let shouldWait = first
        first = false
        lock.unlock()
        if shouldWait {
            firstPrepareEntered.signal()
            releaseFirstPrepare.wait()
        }
    }

    func exit(_ kind: PlaybackBackendKind) {
        lock.lock()
        trace.append("exit:\(kind.rawValue)")
        inFlight -= 1
        lock.unlock()
    }
}
