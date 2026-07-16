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
    private let onDisposed: (IOSPlaybackOrchestrator, QueuedAudioPlayer) -> Void
    private var pendingQueue: [Track] = []
    private var authoritativeQueue: [Track] = []
    private var pendingSnapshot = PlaybackBackendSnapshot.empty
    private var isAuthoritative: Bool
    private var controlSurfaceRelinquished = false
    private var disposed = false

    init(
        player: QueuedAudioPlayer,
        orchestrator: IOSPlaybackOrchestrator,
        transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
        onCommitted: @escaping (IOSPlaybackOrchestrator, QueuedAudioPlayer) -> Void,
        onDisposed: @escaping (IOSPlaybackOrchestrator, QueuedAudioPlayer) -> Void,
        initiallyAuthoritative: Bool = false,
        queueProvider: @escaping () -> [Track]
    ) {
        self.player = player
        self.orchestrator = orchestrator
        self.transitionGenerationSidecar = transitionGenerationSidecar
        self.onCommitted = onCommitted
        self.onDisposed = onDisposed
        self.isAuthoritative = initiallyAuthoritative
        self.queueProvider = queueProvider
        if initiallyAuthoritative {
            onCommitted(orchestrator, player)
        }
    }

    var playbackState: State { return orchestrator.playbackState }
    var currentIndex: Int { return orchestrator.currentIndex }
    var position: Double { return orchestrator.currentTime }
    var duration: Double { return orchestrator.duration }
    var bufferedPosition: Double { return orchestrator.bufferedPosition }
    var publicVolume: Float { return orchestrator.volume }
    var publicRate: Float { return orchestrator.rate }
    var publicPlayWhenReady: Bool { return orchestrator.playWhenReady }
    var queue: [Track] { return queueProvider() }

    func settleActiveTransition() throws {
        orchestrator.settleActiveTransition()
    }

    func snapshot() throws -> PlaybackBackendSnapshot {
        let queue = queueProvider()
        authoritativeQueue = queue
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
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        pendingQueue = queueProvider()
        pendingSnapshot = snapshot
        orchestrator.setVolume(0)
        orchestrator.replaceQueue(pendingQueue, currentIndex: snapshot.activeIndex ?? -1)
    }

    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        let queue = isAuthoritative ? authoritativeQueue : pendingQueue
        if isAuthoritative && !samePlaybackBackendTrackObjects(queueProvider(), queue) {
            player.stop()
            player.clear()
            try player.add(items: queue)
        }
        orchestrator.setRate(snapshot.rate)
        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        let needsPlaybackRestore = !isAuthoritative ||
            orchestrator.currentIndex != (snapshot.activeIndex ?? -1) ||
            abs(orchestrator.currentTime - snapshot.position) > 0.75 ||
            orchestrator.playWhenReady != snapshot.playWhenReady
        if needsPlaybackRestore {
            orchestrator.replaceQueue(queue, currentIndex: snapshot.activeIndex ?? -1)
        }
        if needsPlaybackRestore,
           let index = snapshot.activeIndex,
           queue.indices.contains(index) {
            try awaitResult { completion in
                orchestrator.skip(to: index, initialTime: snapshot.position, completion: completion)
            }
        }
        orchestrator.pause()
    }

    func stopAndMute() throws {
        orchestrator.setVolume(0)
        orchestrator.stop()
    }

    func suspendControlSurface() throws {
        player.remoteCommands = []
        controlSurfaceRelinquished = true
    }

    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {
        controlSurfaceRelinquished = false
        onCommitted(orchestrator, player)
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
        authoritativeQueue = pendingQueue
        isAuthoritative = true
        // The canonical QueuedAudioPlayer may still be the previous standard
        // backend before the facade swap. Muting it is therefore post-commit.
        player.volume = 0
        player.playWhenReady = false
        player.automaticallyUpdateNowPlayingInfo = false
        orchestrator.setVolume(snapshot.volume)
        if snapshot.playWhenReady {
            orchestrator.play { _ in }
        } else {
            orchestrator.pause()
        }
        controlSurfaceRelinquished = false
        onCommitted(orchestrator, player)
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
        isAuthoritative = false
        if !controlSurfaceRelinquished {
            player.remoteCommands = []
        }
        orchestrator.stop()
        onDisposed(orchestrator, player)
    }

    func syncQueue(_ tracks: [Track]) {
        orchestrator.setQueue(tracks)
    }

    func add(_ tracks: [Track], at index: Int) throws {
        try player.add(items: tracks, at: index)
        orchestrator.setQueue(queueProvider())
    }

    func remove(at indexes: [Int]) throws {
        for index in indexes.sorted().reversed() {
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
