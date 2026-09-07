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

#if RNTP_E2E_PROBES
    func e2eSnapshot() -> [String: Any]
#endif

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

#if RNTP_E2E_PROBES
    private let e2eIdentity = UUID().uuidString
    private let e2eEngineIdentity = UUID().uuidString

    func e2eSnapshot() -> [String: Any] {
        precondition(Thread.isMainThread)
        // These are SDK getters. SwiftAudioEx does not expose its AVPlayer:
        // configured volume/rate and playWhenReady cannot prove physical rate,
        // timeControlStatus, native generation, or AVPlayerItem presence.
        let engine: [String: Any] = [
            "id": e2eEngineIdentity,
            "generation": NSNull(),
            "state": String(describing: player.playerState),
            "volume": IOSPlaybackE2EProbe.finite(Double(player.volume)),
            "observedRate": NSNull(),
            "timeControlStatus": NSNull(),
            "position": IOSPlaybackE2EProbe.finite(player.currentTime),
            "duration": IOSPlaybackE2EProbe.finite(player.duration),
            "currentItemPresent": NSNull()
        ]
        return [
            "schemaVersion": 1,
            "backendId": e2eIdentity,
            "backendKind": "standard",
            "generation": transitionGenerationSidecar.current,
            "state": playbackState.rawValue,
            "currentIndex": currentIndex,
            "engineAId": NSNull(),
            "engineBId": NSNull(),
            "activeEngineId": e2eEngineIdentity,
            "standbyEngineId": NSNull(),
            "activeEngineIndex": currentIndex >= 0 ? currentIndex as Any : NSNull(),
            "standbyEngineIndex": NSNull(),
            "engines": [engine]
        ]
    }
#endif

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
    // SwiftAudioEx's seek event has no item or command identifier. Only one
    // native seek may be outstanding, including a cancelled seek whose actual
    // AVFoundation callback has not arrived yet.
    private final class PendingSeek {
        let track: Track
        let position: Double
        var completion: ((Result<Void, Error>) -> Void)?
        var timeout: DispatchWorkItem?

        init(track: Track, position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
            self.track = track
            self.position = position
            self.completion = completion
        }

        func finish(_ result: Result<Void, Error>) {
            let callback = completion
            completion = nil
            timeout?.cancel()
            timeout = nil
            callback?(result)
        }
    }
    private var pendingSeeks: [PendingSeek] = []
    private var issuedSeek: PendingSeek?
    private var seekReadinessPoll: DispatchWorkItem?
    // SwiftAudioEx retains the listener during asynchronous removal. Use a
    // separate identity so deinit never passes its dying self to that closure.
    private let seekListener = NSObject()
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
        player.event.seek.addListener(seekListener) { [weak self] event in
            DispatchQueue.main.async {
                self?.didCompleteNativeSeek(position: event.seconds, didFinish: event.didFinish)
            }
        }
    }

    deinit {
        seekReadinessPoll?.cancel()
        player.event.seek.removeListener(seekListener)
    }

    private func onMain<Value>(_ operation: () throws -> Value) rethrows -> Value {
        if Thread.isMainThread { return try operation() }
        return try DispatchQueue.main.sync(execute: operation)
    }

    private func seekError(_ code: String, _ message: String) -> Error {
        playbackBackendError(code: code, message: message)
    }

    private func enqueueSeek(to position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !disposed, let track = player.currentItem as? Track else {
            completion(.failure(seekError("standard_seek_unavailable", "No active track is available for seeking.")))
            return
        }
        guard position.isFinite else {
            completion(.failure(seekError("standard_seek_invalid_position", "The seek position must be finite.")))
            return
        }
        let request = PendingSeek(track: track, position: max(0, position), completion: completion)
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let self = self, let request = request, request.completion != nil else { return }
            self.pendingSeeks.removeAll { $0 === request }
            // If already emitted, keep the ticket until its real callback. A
            // timeout does not make a late, identical SDK event distinguishable.
            request.finish(.failure(self.seekError("standard_seek_timeout", "The native seek did not complete in time.")))
            self.pumpSeeks()
        }
        request.timeout = timeout
        pendingSeeks.append(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        pumpSeeks()
    }

    private func pumpSeeks() {
        seekReadinessPoll?.cancel()
        seekReadinessPoll = nil
        guard issuedSeek == nil, !disposed else { return }
        while let request = pendingSeeks.first {
            guard (player.currentItem as? Track) === request.track else {
                pendingSeeks.removeFirst()
                request.finish(.failure(seekError("standard_seek_cancelled", "The active track changed before seeking.")))
                continue
            }
            if player.playerState == .failed {
                pendingSeeks.removeFirst()
                request.finish(.failure(seekError("standard_seek_unavailable", "The active track failed to load.")))
                continue
            }
            if player.playerState == .stopped {
                // stop retains the queue but unloads its native item. Reload
                // silently, without the SDK issuing a retained-position seek.
                player.playWhenReady = false
                player.reload(startFromCurrentTime: false)
            }
            // This is the native item's duration, not Track metadata. Without
            // an AVPlayerItem, SwiftAudioEx stores a deferred seek and may never
            // call back (for example after a 404). Check and issue on main so a
            // queue replacement cannot run between them.
            guard player.duration > 0 else {
                let poll = DispatchWorkItem { [weak self] in self?.pumpSeeks() }
                seekReadinessPoll = poll
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
                return
            }
            pendingSeeks.removeFirst()
            issuedSeek = request
            player.seek(to: request.position)
            return
        }
    }

    private func didCompleteNativeSeek(position: Double, didFinish: Bool) {
        guard let request = issuedSeek, request.position == position else { return }
        issuedSeek = nil
        let sameTrack = (player.currentItem as? Track) === request.track
        request.finish(didFinish && sameTrack && !disposed
            ? .success(())
            : .failure(seekError("standard_seek_cancelled", "The native seek was interrupted.")))
        pumpSeeks()
    }

    private func cancelPendingSeeks() {
        seekReadinessPoll?.cancel()
        seekReadinessPoll = nil
        let waiting = pendingSeeks
        pendingSeeks.removeAll()
        let error = seekError("standard_seek_cancelled", "Playback changed before the native seek completed.")
        issuedSeek?.finish(.failure(error))
        waiting.forEach { $0.finish(.failure(error)) }
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
        try onMain {
            cancelPendingSeeks()
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
            player.playWhenReady = false
            player.pause()
            if let index = snapshot.activeIndex,
               queue.indices.contains(index) {
                let indexChanged = player.currentIndex != index
                if indexChanged {
                    try player.jumpToItem(atIndex: index, playWhenReady: false)
                }
                if queueChanged || indexChanged ||
                    abs(player.currentTime - max(0, snapshot.position)) > 0.75 {
                    enqueueSeek(to: snapshot.position) { _ in }
                }
            }
        }
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
            cancelPendingSeeks()
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
        onMain {
            cancelPendingSeeks()
            player.volume = 0
            player.stop()
        }
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
        onMain {
            let wasIdle = idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            player.play()
            publishIdleTrackActivationIfNeeded(wasIdle)
        }
    }
    func pause() {
        onMain {
            cancelPendingSeeks()
            player.pause()
        }
    }
    func seek(to position: Double) throws {
        onMain { enqueueSeek(to: position) { _ in } }
    }

    func startTransition(_ request: PlaybackTransitionRequest) throws {
        throw playbackBackendError(
            code: "crossfade_disabled",
            message: "The standard playback backend does not own a crossfade engine."
        )
    }

    func dispose() throws {
        onMain {
            if disposed { return }
            disposed = true
            cancelPendingSeeks()
            isAuthoritative = false
            if !controlSurfaceRelinquished {
                player.remoteCommands = []
            }
            onDisposed(player)
        }
    }

    func syncQueue(_ tracks: [Track]) {}

    func add(_ tracks: [Track], at index: Int) throws {
        try onMain { try player.add(items: tracks, at: index) }
    }

    func remove(at indexes: [Int]) throws {
        try onMain {
            let indexes = Array(Set(indexes)).sorted(by: >)
            guard !indexes.isEmpty else { return }
            let validIndexes = player.items.indices
            if let invalid = indexes.first(where: { !validIndexes.contains($0) }) {
                throw AudioPlayerError.QueueError.invalidIndex(index: invalid, message: "One or more indexes were out of bounds.")
            }
            if indexes.contains(player.currentIndex) { cancelPendingSeeks() }
            for index in indexes {
                try player.removeItem(at: index)
            }
            if player.items.isEmpty { idleWithoutActiveTrack = false }
        }
    }

    func move(from: Int, to: Int) throws {
        try onMain { try player.moveItem(fromIndex: from, toIndex: to) }
    }

    func removeUpcomingTracks() {
        onMain {
            guard !idleWithoutActiveTrack else { return }
            player.removeUpcomingItems()
        }
    }

    func replaceQueue(_ tracks: [Track]) throws {
        try onMain {
            cancelPendingSeeks()
            player.clear()
            try player.add(items: tracks)
            if tracks.isEmpty { idleWithoutActiveTrack = false }
        }
    }

    func clearQueue() {
        onMain {
            cancelPendingSeeks()
            player.clear()
            idleWithoutActiveTrack = false
        }
    }

    func load(_ track: Track, completion: @escaping (Result<Int, Error>) -> Void) {
        onMain {
            cancelPendingSeeks()
            let wasIdle = idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            player.load(item: track)
            publishIdleTrackActivationIfNeeded(wasIdle)
            completion(.success(player.currentIndex))
        }
    }

    func skip(to index: Int, initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain {
            let wasIdle = idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            do {
                guard player.items.indices.contains(index) else {
                    throw seekError("index_out_of_bounds", "The track index is out of bounds.")
                }
                cancelPendingSeeks()
                if wasIdle { idleWithoutActiveTrack = false }
                let sameIndex = player.currentIndex == index
                if !sameIndex {
                    try player.jumpToItem(atIndex: index, playWhenReady: player.playWhenReady)
                }
                publishIdleTrackActivationIfNeeded(wasIdle)
                if sameIndex || initialTime >= 0 {
                    // jumpToItem on the same item emits its own seek(0). Issue
                    // only the requested seek, and wait for its real callback.
                    enqueueSeek(to: initialTime >= 0 ? initialTime : 0, completion: completion)
                } else {
                    completion(.success(()))
                }
            } catch {
                if wasIdle { idleWithoutActiveTrack = true }
                cancelIdleTrackActivationIfNeeded(wasIdle)
                completion(.failure(error))
            }
        }
    }

    func skipToNext(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain {
            cancelPendingSeeks()
            if idleWithoutActiveTrack {
                beginIdleTrackActivationIfNeeded(true)
                do {
                    idleWithoutActiveTrack = false
                    if player.currentIndex != 0 {
                        try player.jumpToItem(atIndex: 0, playWhenReady: false)
                    }
                    publishIdleTrackActivationIfNeeded(true)
                    if initialTime >= 0 {
                        enqueueSeek(to: initialTime, completion: completion)
                    } else {
                        completion(.success(()))
                    }
                } catch {
                    idleWithoutActiveTrack = true
                    cancelIdleTrackActivationIfNeeded(true)
                    completion(.failure(error))
                }
                return
            }
            player.next()
            if initialTime >= 0 {
                enqueueSeek(to: initialTime, completion: completion)
            } else {
                completion(.success(()))
            }
        }
    }

    func skipToPrevious(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain {
            guard !idleWithoutActiveTrack else {
                completion(.failure(playbackBackendError(
                    code: "index_out_of_bounds",
                    message: "The previous track index is out of bounds."
                )))
                return
            }
            cancelPendingSeeks()
            player.previous()
            if initialTime >= 0 {
                enqueueSeek(to: initialTime, completion: completion)
            } else {
                completion(.success(()))
            }
        }
    }

    func play(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try play()
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    func stop() {
        onMain {
            cancelPendingSeeks()
            player.stop()
        }
    }

    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain {
            if !value { cancelPendingSeeks() }
            let wasIdle = value && idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            player.playWhenReady = value
            publishIdleTrackActivationIfNeeded(wasIdle)
            completion(.success(()))
        }
    }

    func seek(to position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain { enqueueSeek(to: position, completion: completion) }
    }

    func seek(by offset: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain { enqueueSeek(to: player.currentTime + offset, completion: completion) }
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
