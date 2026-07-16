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

protocol PlaybackBackend: AnyObject {
    var kind: PlaybackBackendKind { get }
    var identity: AnyObject { get }
    func settleActiveTransition() throws
    func snapshot() throws -> PlaybackBackendSnapshot
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws
    func restore(_ snapshot: PlaybackBackendSnapshot) throws
    func stopAndMute() throws
    func suspendControlSurface() throws
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot)
    func activateInitialControlSurface()
    func relinquishExclusiveControlSurfaceBeforeCommit() throws
    func commitQueue(_ snapshot: PlaybackBackendSnapshot)
    func play() throws
    func pause()
    func seek(to position: Double) throws
    func startTransition(_ request: PlaybackTransitionRequest) throws
    func dispose() throws
}

extension PlaybackBackend {
    var identity: AnyObject { return self }
    func suspendControlSurface() throws {}
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {}
    func activateInitialControlSurface() {}
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {}
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

final class PlaybackBackendFacade {
    static let maximumPreparationAttempts = 8

    private struct VersionedSnapshot {
        let snapshot: PlaybackBackendSnapshot
        let version: UInt64
    }

    private enum CommitDecision {
        case committed
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
        initial.activateInitialControlSurface()
        authority.publish(initial)
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

                            do {
                                try previous.stopAndMute()
                                try previous.relinquishExclusiveControlSurfaceBeforeCommit()
                                replacement.commitQueue(captured.snapshot)
                                self.backendLock.lock()
                                self.backend = replacement
                                self.backendLock.unlock()
                                self.authority.publish(replacement)
                                self.physicalHandoffActive = true
                                return CommitDecision.committed
                            } catch {
                                self.restoreAuthoritativeBackend(previous, snapshot: captured.snapshot)
                                previous.resumeControlSurface(captured.snapshot)
                                self.authority.publish(previous)
                                return CommitDecision.failed(error)
                            }
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
                        case .committed:
                            do {
                                try previous.dispose()
                            } catch {
                                self.reportCleanupDiagnostic(.disposalFailed)
                            }
                            self.finishPhysicalHandoff()
                            completion(.success(PlaybackBackendTransactionResult(
                                backend: kind,
                                operationID: operationID,
                                snapshot: captured.snapshot
                            )))
                            return
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

    private func reportCleanupDiagnostic(_ diagnostic: PlaybackBackendCleanupDiagnostic) {
        let observer = onCleanupDiagnostic
        cleanupDiagnosticQueue.async {
            observer(diagnostic)
        }
    }

    private func restoreAuthoritativeBackend(
        _ previous: PlaybackBackend,
        snapshot: PlaybackBackendSnapshot
    ) {
        try? previous.restore(snapshot)
        previous.commitQueue(snapshot)
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
}
