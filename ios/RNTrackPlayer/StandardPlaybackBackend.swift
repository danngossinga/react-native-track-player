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
    var publicPlaybackError: IOSPlaybackErrorSnapshot? { get }
    var currentIndex: Int { get }
    var position: Double { get }
    var duration: Double { get }
    var bufferedPosition: Double { get }
    var publicVolume: Float { get }
    var publicRate: Float { get }
    var publicPlayWhenReady: Bool { get }
    var publicRepeatMode: Int { get }
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

struct IOSPlaybackErrorSnapshot: Equatable {
    let message: String?
    let code: String?

    var dictionary: Dictionary<String, Any> {
        var body: Dictionary<String, Any> = [:]
        if let message = message {
            body["message"] = message
        }
        if let code = code {
            body["code"] = code
        }
        return body
    }
}

func iosPlaybackErrorSnapshot(
    from error: AudioPlayerError.PlaybackError?
) -> IOSPlaybackErrorSnapshot? {
    switch error {
    case .some(.failedToLoadKeyValue):
        return IOSPlaybackErrorSnapshot(
            message: "Failed to load resource",
            code: "ios_failed_to_load_resource"
        )
    case .some(.invalidSourceUrl):
        return IOSPlaybackErrorSnapshot(
            message: "The source url was invalid",
            code: "ios_invalid_source_url"
        )
    case .some(.notConnectedToInternet):
        return IOSPlaybackErrorSnapshot(
            message: "A network resource was requested, but an internet connection has not been established and can’t be established automatically.",
            code: "ios_not_connected_to_internet"
        )
    case .some(.playbackFailed):
        return IOSPlaybackErrorSnapshot(
            message: "Playback of the track failed",
            code: "ios_playback_failed"
        )
    case .some(.itemWasUnplayable):
        return IOSPlaybackErrorSnapshot(
            message: "The track could not be played",
            code: "ios_track_unplayable"
        )
    case .none:
        return nil
    }
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
    private let onIdleTrackActivationWillBegin: (QueuedAudioPlayer) -> Void
    private let onIdleTrackActivated: (QueuedAudioPlayer, Int?) -> Void
    private let waitForActivationReadiness: (QueuedAudioPlayer, PlaybackBackendSnapshot) throws -> Void
    private let queueState = PlaybackBackendQueueState<Track>()
    private var pendingSnapshot = PlaybackBackendSnapshot.empty
    private var idleWithoutActiveTrack = false
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
        onIdleTrackActivationWillBegin: @escaping (QueuedAudioPlayer) -> Void = { _ in },
        onIdleTrackActivated: @escaping (QueuedAudioPlayer, Int?) -> Void = { _, _ in },
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
        self.onIdleTrackActivationWillBegin = onIdleTrackActivationWillBegin
        self.onIdleTrackActivated = onIdleTrackActivated
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

    var playbackState: State {
        return idleWithoutActiveTrack ? .none : State.fromPlayerState(state: player.playerState)
    }
    var publicPlaybackError: IOSPlaybackErrorSnapshot? {
        return iosPlaybackErrorSnapshot(from: player.playbackError)
    }
    var currentIndex: Int { return idleWithoutActiveTrack ? -1 : player.currentIndex }
    var position: Double { return idleWithoutActiveTrack ? 0 : player.currentTime }
    var duration: Double { return idleWithoutActiveTrack ? 0 : player.duration }
    var bufferedPosition: Double { return idleWithoutActiveTrack ? 0 : player.bufferedPosition }
    var publicVolume: Float { return player.volume }
    var publicRate: Float { return player.rate }
    var publicPlayWhenReady: Bool { return !idleWithoutActiveTrack && player.playWhenReady }
    var publicRepeatMode: Int { return player.repeatMode.rawValue }
    var queue: [Track] { return queueProvider() }

    func settleActiveTransition() throws {}

    func snapshot() throws -> PlaybackBackendSnapshot {
        let queue = queueProvider()
        queueState.captureAuthoritative(queue)
        let index = queue.indices.contains(currentIndex) ? currentIndex : nil
        return PlaybackBackendSnapshot(
            queueIDs: queue.map(playbackBackendTrackID),
            activeIndex: index,
            activeTrackID: index.map { playbackBackendTrackID(queue[$0]) },
            position: max(0, position),
            playWhenReady: publicPlayWhenReady,
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
        idleWithoutActiveTrack = snapshot.activeIndex == nil && !queue.isEmpty
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
        player.playWhenReady = !idleWithoutActiveTrack && snapshot.playWhenReady
        if player.playWhenReady {
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

    func play() throws {
        let wasIdle = idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        if wasIdle { idleWithoutActiveTrack = false }
        player.play()
        publishIdleTrackActivationIfNeeded(wasIdle)
    }
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
        if player.items.isEmpty { idleWithoutActiveTrack = false }
    }

    func move(from: Int, to: Int) throws {
        try player.moveItem(fromIndex: from, toIndex: to)
    }

    func removeUpcomingTracks() {
        guard !idleWithoutActiveTrack else { return }
        player.removeUpcomingItems()
    }

    func replaceQueue(_ tracks: [Track]) throws {
        player.clear()
        try player.add(items: tracks)
        if tracks.isEmpty { idleWithoutActiveTrack = false }
    }

    func clearQueue() {
        player.clear()
        idleWithoutActiveTrack = false
    }

    func load(_ track: Track, completion: @escaping (Result<Int, Error>) -> Void) {
        let wasIdle = idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        if wasIdle { idleWithoutActiveTrack = false }
        player.load(item: track)
        publishIdleTrackActivationIfNeeded(wasIdle)
        completion(.success(player.currentIndex))
    }

    func skip(to index: Int, initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        let wasIdle = idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        do {
            if wasIdle { idleWithoutActiveTrack = false }
            try player.jumpToItem(atIndex: index, playWhenReady: player.playerState == .playing)
            if initialTime >= 0 { player.seek(to: initialTime) }
            publishIdleTrackActivationIfNeeded(wasIdle)
            completion(.success(()))
        } catch {
            if wasIdle { idleWithoutActiveTrack = true }
            cancelIdleTrackActivationIfNeeded(wasIdle)
            completion(.failure(error))
        }
    }

    func skipToNext(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        if idleWithoutActiveTrack {
            beginIdleTrackActivationIfNeeded(true)
            do {
                idleWithoutActiveTrack = false
                try player.jumpToItem(atIndex: 0, playWhenReady: false)
                if initialTime >= 0 { player.seek(to: initialTime) }
                publishIdleTrackActivationIfNeeded(true)
                completion(.success(()))
            } catch {
                idleWithoutActiveTrack = true
                cancelIdleTrackActivationIfNeeded(true)
                completion(.failure(error))
            }
            return
        }
        player.next()
        if initialTime >= 0 { player.seek(to: initialTime) }
        completion(.success(()))
    }

    func skipToPrevious(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !idleWithoutActiveTrack else {
            completion(.failure(playbackBackendError(
                code: "index_out_of_bounds",
                message: "The previous track index is out of bounds."
            )))
            return
        }
        player.previous()
        if initialTime >= 0 { player.seek(to: initialTime) }
        completion(.success(()))
    }

    func play(completion: @escaping (Result<Void, Error>) -> Void) {
        let wasIdle = idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        if wasIdle { idleWithoutActiveTrack = false }
        player.play()
        publishIdleTrackActivationIfNeeded(wasIdle)
        completion(.success(()))
    }

    func stop() { player.stop() }

    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let wasIdle = value && idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        if wasIdle { idleWithoutActiveTrack = false }
        player.playWhenReady = value
        publishIdleTrackActivationIfNeeded(wasIdle)
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
    func retry() {
        let wasIdle = idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        if wasIdle { idleWithoutActiveTrack = false }
        player.reload(startFromCurrentTime: true)
        publishIdleTrackActivationIfNeeded(wasIdle)
    }
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

    private func publishIdleTrackActivationIfNeeded(_ wasIdle: Bool) {
        guard wasIdle else { return }
        onIdleTrackActivated(player, player.currentIndex >= 0 ? player.currentIndex : nil)
    }

    private func beginIdleTrackActivationIfNeeded(_ wasIdle: Bool) {
        if wasIdle { onIdleTrackActivationWillBegin(player) }
    }

    private func cancelIdleTrackActivationIfNeeded(_ wasIdle: Bool) {
        if wasIdle { onIdleTrackActivated(player, nil) }
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
