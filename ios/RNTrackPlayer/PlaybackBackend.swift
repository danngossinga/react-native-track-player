import Foundation

enum PlaybackBackendKind: String {
    case standard
    case pingPong
}

struct PlaybackBackendSnapshot: Equatable {
    let queueIDs: [String]
    let activeIndex: Int?
    let activeTrackID: String?
    let position: Double
    let playWhenReady: Bool
    let volume: Float
    let rate: Float
    let repeatMode: Int
    let transitionGeneration: Int

    static let empty = PlaybackBackendSnapshot(
        queueIDs: [],
        activeIndex: nil,
        activeTrackID: nil,
        position: 0,
        playWhenReady: false,
        volume: 1,
        rate: 1,
        repeatMode: 0,
        transitionGeneration: 0
    )

    func with(playWhenReady: Bool) -> PlaybackBackendSnapshot {
        return PlaybackBackendSnapshot(
            queueIDs: queueIDs,
            activeIndex: activeIndex,
            activeTrackID: activeTrackID,
            position: position,
            playWhenReady: playWhenReady,
            volume: volume,
            rate: rate,
            repeatMode: repeatMode,
            transitionGeneration: transitionGeneration
        )
    }

    func with(position: Double) -> PlaybackBackendSnapshot {
        return PlaybackBackendSnapshot(
            queueIDs: queueIDs,
            activeIndex: activeIndex,
            activeTrackID: activeTrackID,
            position: position,
            playWhenReady: playWhenReady,
            volume: volume,
            rate: rate,
            repeatMode: repeatMode,
            transitionGeneration: transitionGeneration
        )
    }

    func withIntent(playWhenReady: Bool, volume: Float) -> PlaybackBackendSnapshot {
        return PlaybackBackendSnapshot(
            queueIDs: queueIDs,
            activeIndex: activeIndex,
            activeTrackID: activeTrackID,
            position: position,
            playWhenReady: playWhenReady,
            volume: volume,
            rate: rate,
            repeatMode: repeatMode,
            transitionGeneration: transitionGeneration
        )
    }
}

struct PlaybackTransitionRequest {
    let duration: Double
    let interval: Double
    let targetVolume: Float
    let waitUntil: Double
}

struct PlaybackBackendTransactionResult {
    let backend: PlaybackBackendKind
    let operationID: Int
    let snapshot: PlaybackBackendSnapshot
}

struct PlaybackBackendCleanupDiagnostic {
    let code: String
    let message: String

    static let disposalFailed = PlaybackBackendCleanupDiagnostic(
        code: "playback_backend_cleanup_failed",
        message: "The previous playback backend could not be fully disposed."
    )
}

func playbackBackendQueueForRestore<Item: AnyObject>(
    incoming: [Item]?,
    current: () -> [Item]
) -> [Item] {
    return incoming ?? current()
}

func playbackBackendQueueForRestore<Item: AnyObject>(
    incomingProvider: (() -> [Item])?,
    current: () -> [Item]
) -> [Item] {
    return incomingProvider?() ?? current()
}

func validateStandardPlaybackActivationSnapshot(
    _ snapshot: PlaybackBackendSnapshot,
    queueCount: Int
) throws {
    guard queueCount == 0 || snapshot.activeIndex != nil else {
        throw NSError(
            domain: "RNTrackPlayer.PlaybackBackend",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The standard playback candidate has a non-empty queue but no active track.",
                "code": "playback_backend_activation_not_ready"
            ]
        )
    }
}

func performPlaybackBackendOnMainSync<Value>(
    _ operation: () throws -> Value
) throws -> Value {
    if Thread.isMainThread { return try operation() }

    var value: Value?
    var failure: Error?
    DispatchQueue.main.sync {
        do {
            value = try operation()
        } catch {
            failure = error
        }
    }
    if let failure = failure { throw failure }
    return value!
}

protocol PlaybackBackend: AnyObject {
    var kind: PlaybackBackendKind { get }
    var identity: AnyObject { get }
    func settleActiveTransition() throws
    func snapshot() throws -> PlaybackBackendSnapshot
    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws
    func restore(_ snapshot: PlaybackBackendSnapshot) throws
    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws
    func stopAndMute() throws
    func suspendEventDeliveryForHandoff() throws
    func resumeEventDeliveryAfterHandoff(_ snapshot: PlaybackBackendSnapshot)
    func suspendControlSurface() throws
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot)
    func activateInitialControlSurface()
    func relinquishExclusiveControlSurfaceBeforeCommit() throws
    func commitQueue(_ snapshot: PlaybackBackendSnapshot)
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot)
    func reactivateAfterRollback(_ snapshot: PlaybackBackendSnapshot)
    func play() throws
    func pause()
    func seek(to position: Double) throws
    func startTransition(_ request: PlaybackTransitionRequest) throws
    func dispose() throws
}

extension PlaybackBackend {
    var identity: AnyObject { return self }
    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot { return try snapshot() }
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws {}
    func suspendEventDeliveryForHandoff() throws {}
    func resumeEventDeliveryAfterHandoff(_ snapshot: PlaybackBackendSnapshot) {
        resumeControlSurface(snapshot)
    }
    func suspendControlSurface() throws {}
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {}
    func activateInitialControlSurface() {}
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {}
    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws {}
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {}
    func reactivateAfterRollback(_ snapshot: PlaybackBackendSnapshot) {
        resumeControlSurface(snapshot)
    }
}

protocol PlaybackBackendFactory: AnyObject {
    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend
}

final class PlaybackBackendAuthority {
    private struct Owner {
        let kind: PlaybackBackendKind
        let identity: ObjectIdentifier
    }

    private let lock = NSLock()
    private var owner: Owner?

    func publish(_ backend: PlaybackBackend?) {
        lock.lock()
        owner = backend.map { Owner(kind: $0.kind, identity: ObjectIdentifier($0.identity)) }
        lock.unlock()
    }

    func clear() {
        publish(nil)
    }

    func isAuthoritative(_ kind: PlaybackBackendKind, identity: AnyObject) -> Bool {
        return isAuthoritative(kind, identity: ObjectIdentifier(identity))
    }

    func isAuthoritative(_ kind: PlaybackBackendKind, identity: ObjectIdentifier) -> Bool {
        lock.lock()
        let result = owner?.kind == kind && owner?.identity == identity
        lock.unlock()
        return result
    }

    var currentKind: PlaybackBackendKind? {
        lock.lock()
        let result = owner?.kind
        lock.unlock()
        return result
    }

    var currentIdentity: ObjectIdentifier? {
        lock.lock()
        let result = owner?.identity
        lock.unlock()
        return result
    }
}

final class PlaybackTransitionGenerationSidecar {
    private let lock = NSLock()
    private var generation = 0

    func observe(_ observedGeneration: Int) -> Int {
        lock.lock()
        generation = max(generation, max(0, observedGeneration))
        let result = generation
        lock.unlock()
        return result
    }

    func restore(_ snapshotGeneration: Int) {
        _ = observe(snapshotGeneration)
    }

    var current: Int {
        lock.lock()
        let result = generation
        lock.unlock()
        return result
    }
}

final class PlaybackBackendCommandCompletion<Value> {
    private let lock = NSLock()
    private var resolved = false
    private let resolveOnce: (Result<Value, Error>) -> Void

    init(resolve: @escaping (Result<Value, Error>) -> Void) {
        resolveOnce = resolve
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        resolveOnce(result)
    }
}

final class PlaybackBackendExclusiveCommandSlot<Value> {
    private let lock = NSLock()
    private var current: PlaybackBackendCommandCompletion<Value>?

    var isOccupied: Bool {
        lock.lock()
        let result = current != nil
        lock.unlock()
        return result
    }

    func begin(
        resolve: @escaping (Result<Value, Error>) -> Void
    ) -> PlaybackBackendCommandCompletion<Value>? {
        lock.lock()
        guard current == nil else {
            lock.unlock()
            return nil
        }
        let completion = PlaybackBackendCommandCompletion<Value>(resolve: resolve)
        current = completion
        lock.unlock()
        return completion
    }

    func complete(
        _ completion: PlaybackBackendCommandCompletion<Value>,
        result: Result<Value, Error>
    ) {
        takeResolver(completion, result: result)?()
    }

    func takeResolver(
        _ completion: PlaybackBackendCommandCompletion<Value>,
        result: Result<Value, Error>
    ) -> (() -> Void)? {
        lock.lock()
        guard current === completion else {
            lock.unlock()
            return nil
        }
        current = nil
        lock.unlock()
        return { completion.resolve(result) }
    }

    func cancelCurrent(with error: Error) {
        takeCurrentResolver(result: .failure(error))?()
    }

    func takeCurrentResolver(result: Result<Value, Error>) -> (() -> Void)? {
        lock.lock()
        let completion = current
        current = nil
        lock.unlock()
        guard let completion else { return nil }
        return { completion.resolve(result) }
    }
}

final class PlaybackBackendEventToken {
    private enum State: Equatable {
        case pending
        case active
        case invalid
    }

    private let lock = NSLock()
    private var state = State.pending

    func activate() {
        lock.lock()
        if state == .pending { state = .active }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        state = .invalid
        lock.unlock()
    }

    var acceptsDelivery: Bool {
        lock.lock()
        let result = state == .active
        lock.unlock()
        return result
    }
}

final class PlaybackBackendOperationTicket {
    fileprivate let generation: UInt64
    private let lock = NSLock()
    private var cancelled = false
    private let onCancel: (String) -> Void

    fileprivate init(generation: UInt64, onCancel: @escaping (String) -> Void) {
        self.generation = generation
        self.onCancel = onCancel
    }

    fileprivate func cancel(reason: String) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        onCancel(reason)
    }
}

final class PlaybackBackendOperationRegistry {
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var current: PlaybackBackendOperationTicket?
    private var mutationDepth = 0
    private var afterMutationActions: [() -> Void] = []

    func begin(onCancel: @escaping (String) -> Void) -> PlaybackBackendOperationTicket {
        lock.lock()
        let previous = current
        generation &+= 1
        let ticket = PlaybackBackendOperationTicket(generation: generation, onCancel: onCancel)
        current = ticket
        lock.unlock()
        previous?.cancel(reason: "superseded")
        return ticket
    }

    func invalidateAll(reason: String) {
        lock.lock()
        let invalidated = current
        current = nil
        lock.unlock()
        invalidated?.cancel(reason: reason)
    }

    func isCurrent(_ ticket: PlaybackBackendOperationTicket) -> Bool {
        lock.lock()
        let result = current === ticket
        lock.unlock()
        return result
    }

    @discardableResult
    func performIfCurrent(
        _ ticket: PlaybackBackendOperationTicket,
        perform: () -> Void
    ) -> Bool {
        lock.lock()
        guard current === ticket else {
            lock.unlock()
            return false
        }
        mutationDepth += 1
        perform()
        mutationDepth -= 1
        let actions = drainAfterMutationActionsIfNeeded()
        lock.unlock()
        actions.forEach { $0() }
        return true
    }

    @discardableResult
    func complete(
        _ ticket: PlaybackBackendOperationTicket,
        perform: () -> Void = {}
    ) -> Bool {
        lock.lock()
        guard current === ticket else {
            lock.unlock()
            return false
        }
        current = nil
        mutationDepth += 1
        perform()
        mutationDepth -= 1
        let actions = drainAfterMutationActionsIfNeeded()
        lock.unlock()
        actions.forEach { $0() }
        return true
    }

    /// Runs `action` only after the outermost registry mutation has released its lock.
    /// This keeps synchronous engine callbacks from invoking command completions while
    /// a registry mutation is still in progress.
    func performAfterCurrentMutation(_ action: @escaping () -> Void) {
        lock.lock()
        guard mutationDepth > 0 else {
            lock.unlock()
            action()
            return
        }
        afterMutationActions.append(action)
        lock.unlock()
    }

    func finish(_ ticket: PlaybackBackendOperationTicket) {
        _ = complete(ticket)
    }

    private func drainAfterMutationActionsIfNeeded() -> [() -> Void] {
        guard mutationDepth == 0 else { return [] }
        let actions = afterMutationActions
        afterMutationActions.removeAll()
        return actions
    }
}

final class PlaybackBackendQueueState<Item> {
    private let lock = NSLock()
    private var pendingValues: [Item]
    private var authoritativeValues: [Item]

    init(_ initial: [Item] = []) {
        pendingValues = initial
        authoritativeValues = initial
    }

    func captureAuthoritative(_ values: [Item]) {
        lock.lock()
        authoritativeValues = values
        lock.unlock()
    }

    func stage(_ values: [Item]) {
        lock.lock()
        pendingValues = values
        lock.unlock()
    }

    var pending: [Item] {
        lock.lock()
        let result = pendingValues
        lock.unlock()
        return result
    }

    var authoritative: [Item] {
        lock.lock()
        let result = authoritativeValues
        lock.unlock()
        return result
    }

    @discardableResult
    func commit() -> [Item] {
        lock.lock()
        authoritativeValues = pendingValues
        let result = authoritativeValues
        lock.unlock()
        return result
    }

    func rollback() -> [Item] {
        lock.lock()
        pendingValues = authoritativeValues
        let result = authoritativeValues
        lock.unlock()
        return result
    }
}

final class PlaybackBackendFacade {
    static let maximumPreparationAttempts = 8

    private struct VersionedSnapshot {
        let snapshot: PlaybackBackendSnapshot
        let version: UInt64
    }

    private enum CommitDecision {
        case readyForHandoff
        case stale
        case wait(DispatchSemaphore)
        case failed(Error)
    }

    private let admissionQueue = DispatchQueue(label: "com.doublesymmetry.trackplayer.playback-backend.admission")
    private let swapQueue = DispatchQueue(label: "com.doublesymmetry.trackplayer.playback-backend.swap")
    private let cleanupDiagnosticQueue = DispatchQueue(
        label: "com.doublesymmetry.trackplayer.playback-backend.cleanup-diagnostic"
    )
    private let factory: PlaybackBackendFactory
    private let authority: PlaybackBackendAuthority
    private let onCleanupDiagnostic: (PlaybackBackendCleanupDiagnostic) -> Void
    private let backendLock = NSLock()
    private var backend: PlaybackBackend
    private var nextOperationID = 0
    private var commandVersion: UInt64 = 0
    private var activeCommandLeases = 0
    private var leaseDrainWaiters: [DispatchSemaphore] = []
    private var physicalHandoffActive = false
    private var pendingCommandAdmissions: [() -> Void] = []

    init(
        initial: PlaybackBackend,
        factory: PlaybackBackendFactory,
        authority: PlaybackBackendAuthority = PlaybackBackendAuthority(),
        onCleanupDiagnostic: @escaping (PlaybackBackendCleanupDiagnostic) -> Void = { _ in }
    ) {
        backend = initial
        self.factory = factory
        self.authority = authority
        self.onCleanupDiagnostic = onCleanupDiagnostic
        authority.publish(initial)
        initial.activateInitialControlSurface()
    }

    var currentBackend: PlaybackBackend {
        backendLock.lock()
        let result = backend
        backendLock.unlock()
        return result
    }

    func withCurrentBackendAsync<Value>(
        timeout: TimeInterval = 30,
        _ operation: @escaping (
            PlaybackBackend,
            @escaping (Result<Value, Error>) -> Void
        ) throws -> Void,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        // Kept for source compatibility. A native command is never reported as
        // timed out while it can still mutate a backend; its lease ends only
        // when the native operation resolves or is explicitly cancelled.
        _ = timeout
        admissionQueue.async {
            self.admitCommand(operation, completion: completion)
        }
    }

    func setPlaybackBackend(
        _ kind: PlaybackBackendKind,
        completion: @escaping (Result<PlaybackBackendTransactionResult, Error>) -> Void
    ) {
        swapQueue.async {
            self.nextOperationID += 1
            let operationID = self.nextOperationID

            do {
                let sameTarget: PlaybackBackend? = self.admissionQueue.sync {
                    let previous = self.backend
                    guard previous.kind == kind else { return nil }
                    return previous
                }
                if let sameTarget {
                    let snapshot = try self.captureSameTargetSnapshot(of: sameTarget)
                    completion(.success(PlaybackBackendTransactionResult(
                        backend: kind,
                        operationID: operationID,
                        snapshot: snapshot
                    )))
                    return
                }

                let previous = self.admissionQueue.sync { self.backend }
                for _ in 0..<Self.maximumPreparationAttempts {
                    let captured = try self.captureVersionedSnapshot(of: previous)
                    let replacement = self.factory.create(kind)
                    do {
                        try replacement.prepareSilently(captured.snapshot)
                        try replacement.restore(captured.snapshot)
                        try replacement.prepareActivation(captured.snapshot)
                    } catch {
                        self.cleanupUncommitted(replacement)
                        completion(.failure(error))
                        return
                    }

                    var admissionWaitCount = 0
                    while true {
                        let decision = self.admissionQueue.sync {
                            guard self.backend === previous else {
                                return CommitDecision.failed(self.busyError())
                            }
                            guard self.activeCommandLeases == 0 else {
                                let waiter = DispatchSemaphore(value: 0)
                                self.leaseDrainWaiters.append(waiter)
                                return CommitDecision.wait(waiter)
                            }
                            guard self.commandVersion == captured.version else {
                                return CommitDecision.stale
                            }

                            self.physicalHandoffActive = true
                            return CommitDecision.readyForHandoff
                        }

                        switch decision {
                        case .wait(let waiter):
                            admissionWaitCount += 1
                            waiter.wait()
                            if admissionWaitCount >= Self.maximumPreparationAttempts {
                                self.cleanupUncommitted(replacement)
                                completion(.failure(self.busyError()))
                                return
                            }
                            continue
                        case .stale:
                            self.cleanupUncommitted(replacement)
                        case .failed(let error):
                            self.cleanupUncommitted(replacement)
                            completion(.failure(error))
                            return
                        case .readyForHandoff:
                            var eventDeliverySuspended = false
                            var quiescenceStarted = false
                            var finalSnapshot: PlaybackBackendSnapshot?
                            do {
                                // From this point until finishPhysicalHandoff(), new commands
                                // are queued. Physical playback and its public event surface are
                                // therefore quarantined while the final snapshot is frozen.
                                eventDeliverySuspended = true
                                try previous.suspendEventDeliveryForHandoff()
                                quiescenceStarted = true
                                let quiescedSnapshot = try previous.beginHandoffQuiescence()
                                finalSnapshot = quiescedSnapshot

                                // Re-read the old backend's live queue and playback state. Both
                                // may have advanced naturally while the candidate was warming up.
                                try replacement.prepareSilently(quiescedSnapshot)
                                try replacement.restore(quiescedSnapshot)
                                try replacement.prepareActivation(quiescedSnapshot)
                                try previous.suspendControlSurface()
                                try previous.relinquishExclusiveControlSurfaceBeforeCommit()

                                let commitResult: Result<Void, Error> = self.admissionQueue.sync {
                                    guard self.physicalHandoffActive,
                                          self.backend === previous,
                                          self.activeCommandLeases == 0,
                                          self.commandVersion == captured.version else {
                                        return .failure(self.busyError())
                                    }
                                    replacement.commitQueue(quiescedSnapshot)
                                    self.backendLock.lock()
                                    self.backend = replacement
                                    self.backendLock.unlock()
                                    self.authority.publish(replacement)
                                    return .success(())
                                }
                                try commitResult.get()

                                replacement.activateAfterCommit(quiescedSnapshot)
                                self.finishPhysicalHandoff()
                                completion(.success(PlaybackBackendTransactionResult(
                                    backend: kind,
                                    operationID: operationID,
                                    snapshot: quiescedSnapshot
                                )))
                                self.disposeCommittedBackend(previous)
                                return
                            } catch {
                                var completionError = error
                                self.cleanupUncommitted(replacement)
                                let rollbackSnapshot = finalSnapshot ??
                                    (try? previous.snapshot()) ?? captured.snapshot
                                if quiescenceStarted {
                                    do {
                                        try previous.cancelHandoffQuiescence(rollbackSnapshot)
                                    } catch {
                                        completionError = self.rollbackFailedError()
                                    }
                                }
                                if eventDeliverySuspended {
                                    previous.resumeEventDeliveryAfterHandoff(rollbackSnapshot)
                                }
                                self.finishPhysicalHandoff()
                                completion(.failure(completionError))
                                return
                            }
                        }
                        break
                    }
                }

                completion(.failure(self.busyError()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func admitCommand<Value>(
        _ operation: @escaping (
            PlaybackBackend,
            @escaping (Result<Value, Error>) -> Void
        ) throws -> Void,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        if physicalHandoffActive {
            pendingCommandAdmissions.append { [weak self] in
                self?.admitCommand(operation, completion: completion)
            }
            return
        }

        let capturedBackend = backend
        commandVersion &+= 1
        activeCommandLeases += 1
        let commandCompletion = PlaybackBackendCommandCompletion<Value> { result in
            self.admissionQueue.async {
                self.activeCommandLeases -= 1
                if self.activeCommandLeases == 0 {
                    let waiters = self.leaseDrainWaiters
                    self.leaseDrainWaiters.removeAll()
                    waiters.forEach { $0.signal() }
                }
                completion(result)
            }
        }
        do {
            try operation(capturedBackend, commandCompletion.resolve)
        } catch {
            commandCompletion.resolve(.failure(error))
        }
    }

    private func finishPhysicalHandoff() {
        admissionQueue.sync {
            physicalHandoffActive = false
            let admissions = pendingCommandAdmissions
            pendingCommandAdmissions.removeAll()
            admissions.forEach { admission in
                admissionQueue.async(execute: admission)
            }
        }
    }

    private func captureSameTargetSnapshot(
        of expectedBackend: PlaybackBackend
    ) throws -> PlaybackBackendSnapshot {
        for _ in 0..<Self.maximumPreparationAttempts {
            let decision: (Result<PlaybackBackendSnapshot, Error>?, DispatchSemaphore?) = try admissionQueue.sync {
                guard backend === expectedBackend else {
                    return (.failure(busyError()), nil)
                }
                guard activeCommandLeases == 0 else {
                    let waiter = DispatchSemaphore(value: 0)
                    leaseDrainWaiters.append(waiter)
                    return (nil, waiter)
                }
                return (.success(try expectedBackend.snapshot()), nil)
            }
            if let result = decision.0 { return try result.get() }
            decision.1!.wait()
        }
        throw busyError()
    }

    private func captureVersionedSnapshot(
        of expectedBackend: PlaybackBackend
    ) throws -> VersionedSnapshot {
        for _ in 0..<Self.maximumPreparationAttempts {
            let decision: (Result<VersionedSnapshot, Error>?, DispatchSemaphore?) = try admissionQueue.sync {
                guard backend === expectedBackend else {
                    return (.failure(busyError()), nil)
                }
                try expectedBackend.settleActiveTransition()
                guard activeCommandLeases == 0 else {
                    let waiter = DispatchSemaphore(value: 0)
                    leaseDrainWaiters.append(waiter)
                    return (nil, waiter)
                }
                return (.success(VersionedSnapshot(
                    snapshot: try expectedBackend.snapshot(),
                    version: commandVersion
                )), nil)
            }

            if let capture = decision.0 {
                return try capture.get()
            }
            decision.1!.wait()
        }
        throw busyError()
    }

    private func cleanupUncommitted(_ replacement: PlaybackBackend) {
        try? replacement.stopAndMute()
        try? replacement.dispose()
    }

    private func disposeCommittedBackend(_ previous: PlaybackBackend) {
        let observer = onCleanupDiagnostic
        cleanupDiagnosticQueue.async {
            do {
                try previous.dispose()
            } catch {
                observer(.disposalFailed)
            }
        }
    }

    private func busyError() -> Error {
        return NSError(
            domain: "RNTrackPlayer.PlaybackBackend",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "The playback backend remained busy while preparing a replacement.",
                "code": "playback_backend_busy"
            ]
        )
    }

    private func rollbackFailedError() -> Error {
        return NSError(
            domain: "RNTrackPlayer.PlaybackBackend",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The previous playback backend could not be resumed after a failed handoff.",
                "code": "playback_backend_rollback_failed"
            ]
        )
    }
}
