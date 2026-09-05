import Foundation
import SwiftAudioEx

final class PingPongPlaybackBackend: IOSPlaybackBackendRouting {
    let kind = PlaybackBackendKind.pingPong
    var identity: AnyObject { return orchestrator }

    private let player: QueuedAudioPlayer
    private let orchestrator: IOSPlaybackOrchestrator
    private let transitionGenerationSidecar: PlaybackTransitionGenerationSidecar
    private let queueProvider: () -> [Track]
    private let onCommitted: (IOSPlaybackOrchestrator, QueuedAudioPlayer) -> Void
    private let onActivated: (IOSPlaybackOrchestrator) -> Void
    private let onDisposed: (IOSPlaybackOrchestrator, QueuedAudioPlayer) -> Void
    private let queueState = PlaybackBackendQueueState<Track>()
    private var pendingSnapshot = PlaybackBackendSnapshot.empty
    private var isAuthoritative: Bool
    private var controlSurfaceRelinquished = false
    private var disposed = false
    private var pendingQueueChanged = false
    private(set) var queueResetCount = 0

    init(
        player: QueuedAudioPlayer,
        orchestrator: IOSPlaybackOrchestrator,
        transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
        onCommitted: @escaping (IOSPlaybackOrchestrator, QueuedAudioPlayer) -> Void,
        onActivated: @escaping (IOSPlaybackOrchestrator) -> Void,
        onDisposed: @escaping (IOSPlaybackOrchestrator, QueuedAudioPlayer) -> Void,
        initiallyAuthoritative: Bool = false,
        queueProvider: @escaping () -> [Track]
    ) {
        self.player = player
        self.orchestrator = orchestrator
        self.transitionGenerationSidecar = transitionGenerationSidecar
        self.onCommitted = onCommitted
        self.onActivated = onActivated
        self.onDisposed = onDisposed
        self.isAuthoritative = initiallyAuthoritative
        self.queueProvider = queueProvider
    }

    var playbackState: State { return orchestrator.playbackState }
    var publicPlaybackError: IOSPlaybackErrorSnapshot? { return nil }
    var currentIndex: Int { return orchestrator.currentIndex }
    var position: Double { return orchestrator.currentTime }
    var duration: Double { return orchestrator.duration }
    var bufferedPosition: Double { return orchestrator.bufferedPosition }
    var publicVolume: Float { return orchestrator.volume }
    var publicRate: Float { return orchestrator.rate }
    var publicPlayWhenReady: Bool { return orchestrator.playWhenReady }
    var publicRepeatMode: Int { return player.repeatMode.rawValue }
    var queue: [Track] { return queueProvider() }

    func settleActiveTransition() throws {
        orchestrator.settleActiveTransition()
    }

    func snapshot() throws -> PlaybackBackendSnapshot {
        let queue = queueProvider()
        queueState.captureAuthoritative(queue)
        let index = queue.indices.contains(orchestrator.currentIndex) ? orchestrator.currentIndex : nil
        return PlaybackBackendSnapshot(
            queueIDs: queue.map(playbackBackendTrackID),
            activeIndex: index,
            activeTrackID: index.map { playbackBackendTrackID(queue[$0]) },
            position: max(0, orchestrator.currentTime),
            playWhenReady: orchestrator.playWhenReady,
            volume: orchestrator.volume,
            rate: orchestrator.rate,
            repeatMode: player.repeatMode.rawValue,
            transitionGeneration: transitionGenerationSidecar.observe(orchestrator.transitionGeneration)
        )
    }

    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws {
        let queue = queueProvider()
        pendingQueueChanged = !samePlaybackBackendTrackObjects(queueState.pending, queue)
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        queueState.stage(queue)
        pendingSnapshot = snapshot
        orchestrator.setVolume(0)
    }

    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        let queue = isAuthoritative ? queueState.authoritative : queueState.pending
        if isAuthoritative && !samePlaybackBackendTrackObjects(queueProvider(), queue) {
            player.stop()
            player.clear()
            try player.add(items: queue)
        }
        orchestrator.setRate(snapshot.rate)
        if isAuthoritative {
            player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        }
        let expectedIndex = snapshot.activeIndex ?? -1
        let queueNeedsReplacement = pendingQueueChanged || orchestrator.currentIndex != expectedIndex
        if queueNeedsReplacement {
            queueResetCount += 1
            orchestrator.replaceQueue(queue, currentIndex: snapshot.activeIndex ?? -1)
        }
        if let index = snapshot.activeIndex, queue.indices.contains(index) {
            if queueNeedsReplacement {
                try awaitResult { completion in
                    orchestrator.skip(to: index, initialTime: snapshot.position, completion: completion)
                }
            } else if abs(orchestrator.currentTime - snapshot.position) > 0.75 {
                try awaitResult { completion in
                    orchestrator.seek(to: snapshot.position, completion: completion)
                }
            }
        }
        orchestrator.pause()
    }

    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws {
        guard !disposed else {
            throw playbackBackendError(
                code: "playback_backend_activation_not_ready",
                message: "The ping-pong playback candidate was disposed before activation."
            )
        }
        try orchestrator.verifyPreparedForActivation(expectedIndex: snapshot.activeIndex)
        try awaitResult { completion in
            orchestrator.preparePlaybackForActivation(
                playWhenReady: snapshot.playWhenReady,
                completion: completion
            )
        }
    }

    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot {
        return try performPlaybackBackendOnMainSync {
            let intendedPlayWhenReady = orchestrator.playWhenReady
            let intendedVolume = orchestrator.volume
            orchestrator.setVolume(0)
            orchestrator.pause()
            return try snapshot().withIntent(
                playWhenReady: intendedPlayWhenReady,
                volume: intendedVolume
            )
        }
    }

    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws {
        try awaitResult { completion in
            orchestrator.preparePlaybackForActivation(
                playWhenReady: snapshot.playWhenReady,
                completion: completion
            )
        }
        try performPlaybackBackendOnMainSync {
            orchestrator.activatePreparedPlayback(
                playWhenReady: snapshot.playWhenReady,
                restoredVolume: snapshot.volume
            )
        }
    }

    func stopAndMute() throws {
        orchestrator.setVolume(0)
        orchestrator.stop()
    }

    func suspendEventDeliveryForHandoff() throws {
        orchestrator.delegate = nil
    }

    func suspendControlSurface() throws {
        player.remoteCommands = []
        controlSurfaceRelinquished = true
    }

    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {
        controlSurfaceRelinquished = false
        onCommitted(orchestrator, player)
        onActivated(orchestrator)
    }

    func activateInitialControlSurface() {
        guard isAuthoritative else { return }
        onCommitted(orchestrator, player)
        onActivated(orchestrator)
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
        // The canonical QueuedAudioPlayer may still be the previous standard
        // backend before the facade swap. Muting it is therefore post-commit.
        player.volume = 0
        player.playWhenReady = false
        player.automaticallyUpdateNowPlayingInfo = false
        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        orchestrator.activatePreparedPlayback(
            playWhenReady: snapshot.playWhenReady,
            restoredVolume: 0
        )
        controlSurfaceRelinquished = false
        onCommitted(orchestrator, player)
        orchestrator.setVolume(snapshot.volume)
        onActivated(orchestrator)
    }

    func reactivateAfterRollback(_ snapshot: PlaybackBackendSnapshot) {
        isAuthoritative = true
        _ = queueState.rollback()
        try? cancelHandoffQuiescence(snapshot)
        resumeControlSurface(snapshot)
    }

    func play() throws {
        try awaitResult { completion in orchestrator.play(completion: completion) }
    }

    func pause() { orchestrator.pause() }

    func seek(to position: Double) throws {
        try awaitResult { completion in orchestrator.seek(to: position, completion: completion) }
    }

    func startTransition(_ request: PlaybackTransitionRequest) throws {
        try awaitResult { completion in
            orchestrator.crossFade(
                fadeDuration: request.duration,
                fadeInterval: request.interval,
                fadeToVolume: Double(request.targetVolume),
                waitUntil: request.waitUntil,
                completion: completion
            )
        }
    }

    func dispose() throws {
        if disposed { return }
        disposed = true
        let wasAuthoritative = isAuthoritative
        isAuthoritative = false
        if wasAuthoritative && !controlSurfaceRelinquished {
            player.remoteCommands = []
        }
        onDisposed(orchestrator, player)
        orchestrator.stop()
    }

    func syncQueue(_ tracks: [Track]) {
        orchestrator.setQueue(tracks)
    }

    func add(_ tracks: [Track], at index: Int) throws {
        try player.add(items: tracks, at: index)
        orchestrator.setQueue(queueProvider())
    }

    func remove(at indexes: [Int]) throws {
        let indexes = Array(Set(indexes)).sorted(by: >)
        guard !indexes.isEmpty else { return }
        let validIndexes = player.items.indices
        if let invalid = indexes.first(where: { !validIndexes.contains($0) }) {
            throw AudioPlayerError.QueueError.invalidIndex(index: invalid, message: "One or more indexes were out of bounds.")
        }
        for index in indexes {
            try player.removeItem(at: index)
        }
        orchestrator.setQueue(queueProvider())
    }

    func move(from: Int, to: Int) throws {
        try player.moveItem(fromIndex: from, toIndex: to)
        orchestrator.setQueue(queueProvider())
    }

    func removeUpcomingTracks() {
        player.removeUpcomingItems()
        orchestrator.setQueue(queueProvider())
    }

    func replaceQueue(_ tracks: [Track]) throws {
        player.clear()
        try player.add(items: tracks)
        player.volume = 0
        orchestrator.replaceQueue(tracks, currentIndex: -1)
    }

    func clearQueue() {
        player.clear()
        orchestrator.replaceQueue([], currentIndex: -1)
    }

    func load(_ track: Track, completion: @escaping (Result<Int, Error>) -> Void) {
        player.load(item: track)
        player.volume = 0
        orchestrator.load(track: track, completion: completion)
    }

    func skip(to index: Int, initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        orchestrator.skip(to: index, initialTime: initialTime, completion: completion)
    }

    func skipToNext(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        orchestrator.skipToNext(initialTime: initialTime, completion: completion)
    }

    func skipToPrevious(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        orchestrator.skipToPrevious(initialTime: initialTime, completion: completion)
    }

    func play(completion: @escaping (Result<Void, Error>) -> Void) {
        player.volume = 0
        orchestrator.play(completion: completion)
    }

    func stop() { orchestrator.stop() }

    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        orchestrator.setPlayWhenReady(value, completion: completion)
    }

    func seek(to position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        orchestrator.seek(to: position, completion: completion)
    }

    func seek(by offset: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        orchestrator.seek(by: offset, completion: completion)
    }

    func setVolume(_ value: Float) { orchestrator.setVolume(value) }
    func setRate(_ value: Float) { orchestrator.setRate(value) }
    func retry() { orchestrator.play { _ in } }
    func setRepeatMode(_ rawValue: Int) {
        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: rawValue) ?? .off
    }

    func prepareCrossfade(
        previous: Bool,
        seekTo: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        orchestrator.prepareCrossfade(previous: previous, seekTo: seekTo, completion: completion)
    }

    func crossFade(
        fadeDuration: Double,
        fadeInterval: Double,
        fadeToVolume: Double,
        waitUntil: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        orchestrator.crossFade(
            fadeDuration: fadeDuration,
            fadeInterval: fadeInterval,
            fadeToVolume: fadeToVolume,
            waitUntil: waitUntil,
            completion: completion
        )
    }

    private func awaitResult(
        timeout: TimeInterval = 10,
        _ start: (@escaping (Result<Void, Error>) -> Void) -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: Result<Void, Error>?
        start { result in
            captured = result
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw playbackBackendError(
                code: "playback_backend_restore_timeout",
                message: "The replacement playback backend did not become ready in time."
            )
        }
        switch captured {
        case .success?: return
        case .failure(let error)?: throw error
        case nil:
            throw playbackBackendError(
                code: "playback_backend_restore_failed",
                message: "The replacement playback backend did not report a result."
            )
        }
    }
}

final class IOSPlaybackBackendFactory: PlaybackBackendFactory {
    private let createBackend: (PlaybackBackendKind) -> PlaybackBackend

    init(createBackend: @escaping (PlaybackBackendKind) -> PlaybackBackend) {
        self.createBackend = createBackend
    }

    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        return createBackend(kind)
    }
}
