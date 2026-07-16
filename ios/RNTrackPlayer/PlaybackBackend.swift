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

final class PlaybackBackendFacade {
    private let transactionQueue = DispatchQueue(label: "com.doublesymmetry.trackplayer.playback-backend")
    private let factory: PlaybackBackendFactory
    private let authority: PlaybackBackendAuthority
    private let onCleanupDiagnostic: (PlaybackBackendCleanupDiagnostic) -> Void
    private let backendLock = NSLock()
    private var backend: PlaybackBackend
    private var nextOperationID = 0

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
        transactionQueue.async {
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var captured: Result<Value, Error>?
            var acceptingResult = true
            do {
                try operation(self.backend) { result in
                    lock.lock()
                    guard acceptingResult else {
                        lock.unlock()
                        return
                    }
                    acceptingResult = false
                    captured = result
                    lock.unlock()
                    semaphore.signal()
                }
                if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                    lock.lock()
                    acceptingResult = false
                    lock.unlock()
                    completion(.failure(NSError(
                        domain: "RNTrackPlayer.PlaybackBackend",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "The playback backend command timed out.",
                            "code": "playback_backend_command_timeout"
                        ]
                    )))
                    return
                }
                lock.lock()
                let result = captured
                lock.unlock()
                completion(result!)
            } catch {
                lock.lock()
                acceptingResult = false
                lock.unlock()
                completion(.failure(error))
            }
        }
    }

    func setPlaybackBackend(
        _ kind: PlaybackBackendKind,
        completion: @escaping (Result<PlaybackBackendTransactionResult, Error>) -> Void
    ) {
        transactionQueue.async {
            self.nextOperationID += 1
            let operationID = self.nextOperationID
            let previous = self.backend

            do {
                try previous.settleActiveTransition()
                let snapshot = try previous.snapshot()
                if previous.kind == kind {
                    completion(.success(PlaybackBackendTransactionResult(
                        backend: kind,
                        operationID: operationID,
                        snapshot: snapshot
                    )))
                    return
                }

                try previous.suspendControlSurface()
                self.authority.clear()
                let replacement = self.factory.create(kind)
                do {
                    try replacement.prepareSilently(snapshot)
                    try replacement.restore(snapshot)
                } catch {
                    self.cleanupUncommitted(replacement)
                    self.authority.publish(previous)
                    self.restoreAuthoritativeBackend(previous, snapshot: snapshot)
                    previous.resumeControlSurface(snapshot)
                    completion(.failure(error))
                    return
                }

                do {
                    try previous.stopAndMute()
                } catch {
                    self.cleanupUncommitted(replacement)
                    self.authority.publish(previous)
                    self.restoreAuthoritativeBackend(previous, snapshot: snapshot)
                    previous.resumeControlSurface(snapshot)
                    completion(.failure(error))
                    return
                }

                do {
                    try previous.relinquishExclusiveControlSurfaceBeforeCommit()
                } catch {
                    self.cleanupUncommitted(replacement)
                    self.authority.publish(previous)
                    self.restoreAuthoritativeBackend(previous, snapshot: snapshot)
                    previous.resumeControlSurface(snapshot)
                    completion(.failure(error))
                    return
                }

                // Atomic facade-reference replacement is the only commit point.
                // commitQueue is deliberately non-throwing for both adapters.
                self.backendLock.lock()
                self.backend = replacement
                self.backendLock.unlock()
                replacement.commitQueue(snapshot)
                self.authority.publish(replacement)

                do {
                    try previous.dispose()
                } catch {
                    self.onCleanupDiagnostic(.disposalFailed)
                }

                completion(.success(PlaybackBackendTransactionResult(
                    backend: kind,
                    operationID: operationID,
                    snapshot: snapshot
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func cleanupUncommitted(_ replacement: PlaybackBackend) {
        try? replacement.stopAndMute()
        try? replacement.dispose()
    }

    private func restoreAuthoritativeBackend(
        _ previous: PlaybackBackend,
        snapshot: PlaybackBackendSnapshot
    ) {
        try? previous.restore(snapshot)
        previous.commitQueue(snapshot)
    }
}
