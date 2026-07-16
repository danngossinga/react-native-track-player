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
        factory.prepareHook = {
            XCTAssertTrue(facade.currentBackend === old)
            let callbackFinished = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                XCTAssertNil(authority.currentKind)
                facade.withCurrentBackendAsync({ backend, completion in
                    backend.pause()
                    completion(.success(backend.kind))
                }) { result in
                    queuedCommandBackend = try? result.get()
                    queuedCommandFinished.fulfill()
                }
                callbackFinished.signal()
            }
            XCTAssertEqual(callbackFinished.wait(timeout: .now() + 1), .success)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }
        wait(for: [queuedCommandFinished], timeout: 1)
        guard let replacement = factory.created.first else {
            XCTFail("replacement backend was not created")
            return
        }

        XCTAssertEqual(replacement.restoredSnapshot, paused)
        XCTAssertEqual(replacement.committedQueue, paused.queueIDs)
        XCTAssertFalse(replacement.audible)
        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(try? result.get().operationID, 1)
        XCTAssertEqual(queuedCommandBackend, .pingPong)

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
            sharedResource: shared,
            mutateSharedOnRestore: true
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
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true, failDispose: true)
        let facade = PlaybackBackendFacade(
            initial: old,
            factory: FakeFactory(),
            onCleanupDiagnostic: { diagnostics.append($0) }
        )

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.code, "playback_backend_cleanup_failed")
        XCTAssertFalse(diagnostics.first?.message.contains("secret") == true)
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
        XCTAssertEqual(barrier.trace, ["enter:pingPong", "exit:pingPong", "enter:standard", "exit:standard"])

        let timedOut = expectation(description: "routed command timeout")
        var deferredCompletion: ((Result<Void, Error>) -> Void)?
        var routedCompletionCount = 0
        var routedCommandTimedOut = false
        facade.withCurrentBackendAsync(timeout: 0.01, { _, completion in
            deferredCompletion = completion
        }) { (result: Result<Void, Error>) in
            routedCompletionCount += 1
            if case .failure = result {
                routedCommandTimedOut = true
            }
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 1)
        deferredCompletion?(.success(()))
        XCTAssertTrue(routedCommandTimedOut)
        XCTAssertEqual(routedCompletionCount, 1)
    }

    func test_initialBackendActivatesAndPublishesExactIdentity() {
        let initial = FakeBackend(kind: .standard, snapshot: snapshot)
        let authority = PlaybackBackendAuthority()

        _ = PlaybackBackendFacade(
            initial: initial,
            factory: FakeFactory(),
            authority: authority
        )

        XCTAssertEqual(initial.calls, ["activateInitialControlSurface"])
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: initial))
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

    func test_restoreRollbackRepublishesExactPreviousGeneration() {
        let previous = FakeBackend(kind: .pingPong, snapshot: snapshot, initiallyAuthoritative: true)
        let factory = FakeFactory(failRestore: true)
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: previous, factory: factory, authority: authority)

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: previous))
        XCTAssertFalse(authority.isAuthoritative(.standard, identity: factory.created[0]))
        XCTAssertTrue(previous.calls.contains("resumeControlSurface"))
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
            prepareHook: prepareHook
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
    private var capturedSharedQueue: [AnyObject] = []
    private var isAuthoritative: Bool
    private(set) var calls: [String] = []
    private(set) var restoredSnapshot: PlaybackBackendSnapshot?
    private(set) var committedQueue: [String]?
    private(set) var disposed = false
    private(set) var audible: Bool

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
        prepareHook: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.snapshotValue = snapshot
        self.audible = audible
        self.registry = registry
        self.failPrepare = failPrepare
        self.failRestore = failRestore
        self.failDispose = failDispose
        self.barrier = barrier
        self.sharedResource = sharedResource
        self.mutateSharedOnRestore = mutateSharedOnRestore
        self.isAuthoritative = initiallyAuthoritative
        self.prepareHook = prepareHook
    }

    func settleActiveTransition() throws { calls.append("settle") }
    func activateInitialControlSurface() { calls.append("activateInitialControlSurface") }
    func suspendControlSurface() throws { calls.append("suspendControlSurface") }
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("resumeControlSurface")
    }
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {
        calls.append("relinquishExclusiveControlSurfaceBeforeCommit")
    }
    func snapshot() throws -> PlaybackBackendSnapshot {
        calls.append("snapshot")
        capturedSharedQueue = sharedResource?.queue ?? []
        return snapshotValue
    }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("prepare")
        setAudible(false)
        prepareHook?()
        barrier?.enter(kind)
        if failPrepare { throw FakeError.prepare }
    }
    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("restore")
        if mutateSharedOnRestore && !isAuthoritative {
            sharedResource?.queue = []
        }
        if failRestore { throw FakeError.restore }
        if isAuthoritative {
            sharedResource?.queue = capturedSharedQueue
        }
        snapshotValue = snapshot
        restoredSnapshot = snapshot
        barrier?.exit(kind)
    }
    func stopAndMute() throws { calls.append("stopAndMute"); setAudible(false) }
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("commitQueue")
        committedQueue = snapshot.queueIDs
        setAudible(snapshot.playWhenReady)
        isAuthoritative = true
    }
    func play() throws { setAudible(true) }
    func pause() { setAudible(false) }
    func seek(to position: Double) throws { snapshotValue = snapshotValue.with(position: position) }
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {
        disposed = true
        isAuthoritative = false
        calls.append("dispose")
        if failDispose { throw FakeError.secretDisposalDetail }
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

private enum FakeError: Error {
    case prepare
    case restore
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
