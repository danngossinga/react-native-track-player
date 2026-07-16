import Foundation
import SwiftAudioEx

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
    private let incomingQueue: [Track]?
    private let queueProvider: () -> [Track]
    private let onCommitted: (QueuedAudioPlayer) -> Void
    private let onDisposed: (QueuedAudioPlayer) -> Void
    private var pendingQueue: [Track] = []
    private var authoritativeQueue: [Track] = []
    private var pendingSnapshot = PlaybackBackendSnapshot.empty
    private var isAuthoritative: Bool
    private var controlSurfaceRelinquished = false
    private var disposed = false

    init(
        player: QueuedAudioPlayer,
        transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
        automaticallyUpdateNowPlayingInfo: @escaping () -> Bool,
        onCommitted: @escaping (QueuedAudioPlayer) -> Void,
        onDisposed: @escaping (QueuedAudioPlayer) -> Void,
        initiallyAuthoritative: Bool = false,
        incomingQueue: [Track]? = nil,
        queueProvider: @escaping () -> [Track]
    ) {
        self.player = player
        self.transitionGenerationSidecar = transitionGenerationSidecar
        self.automaticallyUpdateNowPlayingInfo = automaticallyUpdateNowPlayingInfo
        self.onCommitted = onCommitted
        self.onDisposed = onDisposed
        self.isAuthoritative = initiallyAuthoritative
        self.incomingQueue = incomingQueue
        self.queueProvider = queueProvider
        if initiallyAuthoritative {
            onCommitted(player)
        }
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
        authoritativeQueue = queue
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
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        pendingQueue = playbackBackendQueueForRestore(
            incoming: incomingQueue,
            current: queueProvider
        )
        pendingSnapshot = snapshot
    }

    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        transitionGenerationSidecar.restore(snapshot.transitionGeneration)
        let queue = isAuthoritative ? authoritativeQueue : pendingQueue
        let queueChanged = !samePlaybackBackendTrackObjects(queueProvider(), queue)
        if !isAuthoritative || queueChanged {
            player.stop()
            player.clear()
            try player.add(items: queue)
        }
        player.rate = snapshot.rate
        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        if let index = snapshot.activeIndex,
           queue.indices.contains(index),
           !isAuthoritative || queueChanged || player.currentIndex != index {
            try player.jumpToItem(atIndex: index, playWhenReady: false)
            player.seek(to: snapshot.position)
        }
        player.playWhenReady = false
        player.pause()
    }

    func stopAndMute() throws {
        player.volume = 0
        player.stop()
    }

    func suspendControlSurface() throws {
        player.remoteCommands = []
        controlSurfaceRelinquished = true
    }

    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {
        controlSurfaceRelinquished = false
        onCommitted(player)
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
        player.automaticallyUpdateNowPlayingInfo = automaticallyUpdateNowPlayingInfo()
        player.volume = snapshot.volume
        player.playWhenReady = snapshot.playWhenReady
        controlSurfaceRelinquished = false
        onCommitted(player)
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
