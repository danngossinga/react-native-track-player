import Foundation
import SwiftAudioEx

struct StandardPlaybackReadinessObservation {
    let state: AudioPlayerState
    let index: Int
    let position: Double
}

enum StandardPlaybackReadinessGate {
    static func wait(
        expectedIndex: Int,
        expectedPosition: Double,
        timeout: TimeInterval = 5,
        observe: () -> StandardPlaybackReadinessObservation,
        waitForNextPoll: () -> Void = { Thread.sleep(forTimeInterval: 0.01) }
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let observation = observe()
            if observation.state == .failed {
                throw playbackBackendError(
                    code: "playback_backend_activation_not_ready",
                    message: "The standard playback candidate failed while restoring playback."
                )
            }
            let isReadyState = observation.state == .ready ||
                observation.state == .paused ||
                observation.state == .playing
            let restoredPosition = max(0, expectedPosition)
            if isReadyState,
               observation.index == expectedIndex,
               abs(observation.position - restoredPosition) <= 0.75 {
                return
            }
            if Date() >= deadline {
                throw playbackBackendError(
                    code: "playback_backend_activation_not_ready",
                    message: "The standard playback candidate timed out while restoring playback."
                )
            }
            waitForNextPoll()
        }
    }
}

private func waitForStandardPlaybackActivation(
    player: QueuedAudioPlayer,
    snapshot: PlaybackBackendSnapshot
) throws {
    guard let expectedIndex = snapshot.activeIndex else { return }
    guard !Thread.isMainThread else {
        throw playbackBackendError(
            code: "playback_backend_activation_not_ready",
            message: "Standard playback readiness cannot wait on the main thread."
        )
    }
    try StandardPlaybackReadinessGate.wait(
        expectedIndex: expectedIndex,
        expectedPosition: snapshot.position,
        observe: {
            StandardPlaybackReadinessObservation(
                state: player.playerState,
                index: player.currentIndex,
                position: player.currentTime
            )
        }
    )
}

protocol IOSPlaybackBackendRouting: PlaybackBackend {
    var playbackState: State { get }
    var currentIndex: Int { get }
    var position: Double { get }
    var duration: Double { get }
    var bufferedPosition: Double { get }
    var publicVolume: Float { get }
    var publicRate: Float { get }
    var publicPlayWhenReady: Bool { get }
    var queue: [Track] { get }

    func syncQueue(_ tracks: [Track])
    func add(_ tracks: [Track], at index: Int) throws
    func remove(at indexes: [Int]) throws
    func move(from: Int, to: Int) throws
    func removeUpcomingTracks()
    func replaceQueue(_ tracks: [Track]) throws
    func clearQueue()
    func load(_ track: Track, completion: @escaping (Result<Int, Error>) -> Void)
    func skip(to index: Int, initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void)
    func skipToNext(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void)
    func skipToPrevious(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void)
    func play(completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    func seek(to position: Double, completion: @escaping (Result<Void, Error>) -> Void)
    func seek(by offset: Double, completion: @escaping (Result<Void, Error>) -> Void)
    func setVolume(_ value: Float)
    func setRate(_ value: Float)
    func retry()
    func setRepeatMode(_ rawValue: Int)
    func prepareCrossfade(
        previous: Bool,
        seekTo: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func crossFade(
        fadeDuration: Double,
        fadeInterval: Double,
        fadeToVolume: Double,
        waitUntil: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

final class StandardPlaybackBackend: IOSPlaybackBackendRouting {
    let kind = PlaybackBackendKind.standard
    var identity: AnyObject { return player }

    private let player: QueuedAudioPlayer
    private let transitionGenerationSidecar: PlaybackTransitionGenerationSidecar
    private let automaticallyUpdateNowPlayingInfo: () -> Bool
    private let incomingQueueProvider: (() -> [Track])?
    private let queueProvider: () -> [Track]
    private let onCommitted: (QueuedAudioPlayer) -> Void
    private let onActivated: (QueuedAudioPlayer) -> Void
    private let onDisposed: (QueuedAudioPlayer) -> Void
    private let waitForActivationReadiness: (QueuedAudioPlayer, PlaybackBackendSnapshot) throws -> Void
    private let queueState = PlaybackBackendQueueState<Track>()
    private var pendingSnapshot = PlaybackBackendSnapshot.empty
    private var isAuthoritative: Bool
    private var controlSurfaceRelinquished = false
    private var disposed = false
    private(set) var queueReloadCount = 0

    init(
        player: QueuedAudioPlayer,
        transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
        automaticallyUpdateNowPlayingInfo: @escaping () -> Bool,
        onCommitted: @escaping (QueuedAudioPlayer) -> Void,
        onActivated: @escaping (QueuedAudioPlayer) -> Void,
        onDisposed: @escaping (QueuedAudioPlayer) -> Void,
        waitForActivationReadiness: @escaping (
            QueuedAudioPlayer,
            PlaybackBackendSnapshot
        ) throws -> Void = waitForStandardPlaybackActivation,
        initiallyAuthoritative: Bool = false,
        incomingQueue: [Track]? = nil,
        incomingQueueProvider: (() -> [Track])? = nil,
        queueProvider: @escaping () -> [Track]
    ) {
        self.player = player
        self.transitionGenerationSidecar = transitionGenerationSidecar
        self.automaticallyUpdateNowPlayingInfo = automaticallyUpdateNowPlayingInfo
        self.onCommitted = onCommitted
        self.onActivated = onActivated
        self.onDisposed = onDisposed
        self.waitForActivationReadiness = waitForActivationReadiness
        self.isAuthoritative = initiallyAuthoritative
        if let incomingQueueProvider = incomingQueueProvider {
            self.incomingQueueProvider = incomingQueueProvider
        } else if let incomingQueue = incomingQueue {
            self.incomingQueueProvider = { incomingQueue }
        } else {
            self.incomingQueueProvider = nil
        }
        self.queueProvider = queueProvider
    }

    var playbackState: State { return State.fromPlayerState(state: player.playerState) }
    var currentIndex: Int { return player.currentIndex }
    var position: Double { return player.currentTime }
    var duration: Double { return player.duration }
    var bufferedPosition: Double { return player.bufferedPosition }
    var publicVolume: Float { return player.volume }
    var publicRate: Float { return player.rate }
    var publicPlayWhenReady: Bool { return player.playWhenReady }
    var queue: [Track] { return queueProvider() }

    func settleActiveTransition() throws {}

    func snapshot() throws -> PlaybackBackendSnapshot {
        let queue = queueProvider()
        queueState.captureAuthoritative(queue)
        let index = queue.indices.contains(player.currentIndex) ? player.currentIndex : nil
        return PlaybackBackendSnapshot(
            queueIDs: queue.map(playbackBackendTrackID),
            activeIndex: index,
            activeTrackID: index.map { playbackBackendTrackID(queue[$0]) },
            position: max(0, player.currentTime),
            playWhenReady: player.playWhenReady,
            volume: player.volume,
            rate: player.rate,
            repeatMode: player.repeatMode.rawValue,
            transitionGeneration: transitionGenerationSidecar.current
        )
    }

    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws {
        let queue = playbackBackendQueueForRestore(
            incomingProvider: incomingQueueProvider,
            current: queueProvider
        )
        try validateStandardPlaybackActivationSnapshot(snapshot, queueCount: queue.count)
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        queueState.stage(queue)
        pendingSnapshot = snapshot
        player.volume = 0
    }

    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        let queue = isAuthoritative ? queueState.authoritative : queueState.pending
        let queueChanged = !samePlaybackBackendTrackObjects(queueProvider(), queue)
        if queueChanged {
            queueReloadCount += 1
            player.stop()
            player.clear()
            try player.add(items: queue)
        }
        player.rate = snapshot.rate
        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        if let index = snapshot.activeIndex,
           queue.indices.contains(index) {
            let indexChanged = player.currentIndex != index
            if queueChanged || indexChanged {
                try player.jumpToItem(atIndex: index, playWhenReady: false)
            }
            if queueChanged || indexChanged ||
                abs(player.currentTime - max(0, snapshot.position)) > 0.75 {
                player.seek(to: snapshot.position)
            }
        }
        player.playWhenReady = false
        player.pause()
    }

    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws {
        guard !disposed else {
            throw playbackBackendError(
                code: "playback_backend_activation_not_ready",
                message: "The standard playback candidate was disposed before activation."
            )
        }
        try validateStandardPlaybackActivationSnapshot(
            snapshot,
            queueCount: queueState.pending.count
        )
        if let index = snapshot.activeIndex,
           !queueState.pending.indices.contains(index) {
            throw playbackBackendError(
                code: "playback_backend_activation_not_ready",
                message: "The standard playback candidate did not restore the active track."
            )
        }
        try waitForActivationReadiness(player, snapshot)
    }

    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot {
        return try performPlaybackBackendOnMainSync {
            let intendedPlayWhenReady = player.playWhenReady
            let intendedVolume = player.volume
            player.volume = 0
            player.pause()
            return try snapshot().withIntent(
                playWhenReady: intendedPlayWhenReady,
                volume: intendedVolume
            )
        }
    }

    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws {
        try performPlaybackBackendOnMainSync {
            player.playWhenReady = snapshot.playWhenReady
            if snapshot.playWhenReady {
                player.play()
            } else {
                player.pause()
            }
            player.volume = snapshot.volume
        }
    }

    func stopAndMute() throws {
        player.volume = 0
        player.stop()
    }

    func suspendEventDeliveryForHandoff() throws {
        onDisposed(player)
    }

    func suspendControlSurface() throws {
        player.remoteCommands = []
        controlSurfaceRelinquished = true
    }

    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {
        controlSurfaceRelinquished = false
        onCommitted(player)
        onActivated(player)
    }

    func activateInitialControlSurface() {
        guard isAuthoritative else { return }
        onCommitted(player)
        onActivated(player)
    }

    func relinquishExclusiveControlSurfaceBeforeCommit() throws {
        if !controlSurfaceRelinquished {
            player.remoteCommands = []
            controlSurfaceRelinquished = true
        }
    }

    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        pendingSnapshot = snapshot
        _ = queueState.commit()
        isAuthoritative = true
    }

    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {
        player.automaticallyUpdateNowPlayingInfo = automaticallyUpdateNowPlayingInfo()
        player.playWhenReady = snapshot.playWhenReady
        if snapshot.playWhenReady {
            player.play()
        } else {
            player.pause()
        }
        controlSurfaceRelinquished = false
        onCommitted(player)
        player.volume = snapshot.volume
        onActivated(player)
    }

    func reactivateAfterRollback(_ snapshot: PlaybackBackendSnapshot) {
        isAuthoritative = true
        _ = queueState.rollback()
        try? cancelHandoffQuiescence(snapshot)
        resumeControlSurface(snapshot)
    }

    func play() throws { player.play() }
    func pause() { player.pause() }
    func seek(to position: Double) throws { player.seek(to: position) }

    func startTransition(_ request: PlaybackTransitionRequest) throws {
        throw playbackBackendError(
            code: "crossfade_disabled",
            message: "The standard playback backend does not own a crossfade engine."
        )
    }

    func dispose() throws {
        if disposed { return }
        disposed = true
        isAuthoritative = false
        if !controlSurfaceRelinquished {
            player.remoteCommands = []
        }
        onDisposed(player)
    }

    func syncQueue(_ tracks: [Track]) {}

    func add(_ tracks: [Track], at index: Int) throws {
        try player.add(items: tracks, at: index)
    }

    func remove(at indexes: [Int]) throws {
        for index in indexes.sorted().reversed() {
            try player.removeItem(at: index)
        }
    }

    func move(from: Int, to: Int) throws {
        try player.moveItem(fromIndex: from, toIndex: to)
    }

    func removeUpcomingTracks() { player.removeUpcomingItems() }

    func replaceQueue(_ tracks: [Track]) throws {
        player.clear()
        try player.add(items: tracks)
    }

    func clearQueue() { player.clear() }

    func load(_ track: Track, completion: @escaping (Result<Int, Error>) -> Void) {
        player.load(item: track)
        completion(.success(player.currentIndex))
    }

    func skip(to index: Int, initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try player.jumpToItem(atIndex: index, playWhenReady: player.playerState == .playing)
            if initialTime >= 0 { player.seek(to: initialTime) }
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func skipToNext(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        player.next()
        if initialTime >= 0 { player.seek(to: initialTime) }
        completion(.success(()))
    }

    func skipToPrevious(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        player.previous()
        if initialTime >= 0 { player.seek(to: initialTime) }
        completion(.success(()))
    }

    func play(completion: @escaping (Result<Void, Error>) -> Void) {
        player.play()
        completion(.success(()))
    }

    func stop() { player.stop() }

    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        player.playWhenReady = value
        completion(.success(()))
    }

    func seek(to position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        player.seek(to: position)
        completion(.success(()))
    }

    func seek(by offset: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        player.seek(by: offset)
        completion(.success(()))
    }

    func setVolume(_ value: Float) { player.volume = value }
    func setRate(_ value: Float) { player.rate = value }
    func retry() { player.reload(startFromCurrentTime: true) }
    func setRepeatMode(_ rawValue: Int) {
        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: rawValue) ?? .off
    }

    func prepareCrossfade(
        previous: Bool,
        seekTo: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.failure(playbackBackendError(
            code: "crossfade_disabled",
            message: "The standard playback backend does not own a crossfade engine."
        )))
    }

    func crossFade(
        fadeDuration: Double,
        fadeInterval: Double,
        fadeToVolume: Double,
        waitUntil: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.failure(playbackBackendError(
            code: "crossfade_disabled",
            message: "The standard playback backend does not own a crossfade engine."
        )))
    }
}

func samePlaybackBackendTrackObjects(_ lhs: [Track], _ rhs: [Track]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { pair in pair.0 === pair.1 }
}

func playbackBackendTrackID(_ track: Track) -> String {
    if let value = track.toObject()["id"] as? String { return value }
    if let value = track.toObject()["id"] as? NSNumber { return value.stringValue }
    return track.getSourceUrl()
}

func playbackBackendError(code: String, message: String) -> Error {
    return NSError(domain: "RNTrackPlayer.PlaybackBackend", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message,
        "code": code
    ])
}
