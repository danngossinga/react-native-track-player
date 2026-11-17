import Foundation
import SwiftAudioEx

struct StandardPlaybackReadinessObservation {
    let state: AudioPlayerState
    let index: Int
    let position: Double
    /// The player's buffered position (seconds): its growth is the wait's progress.
    let buffered: Double
}

enum StandardPlaybackReadinessGate {
    /// Fails when the track makes no progress for `stallTimeoutMs`, or after `timeoutMs` in all.
    static func wait(
        expectedIndex: Int,
        expectedPosition: Double,
        timeoutMs: Int,
        stallTimeoutMs: Int,
        /// The app's `backendSwitchPositionToleranceMs`.
        positionToleranceMs: Int,
        observe: () -> StandardPlaybackReadinessObservation,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        waitForNextPoll: () -> Void = { Thread.sleep(forTimeInterval: 0.01) }
    ) throws {
        var watch = StallWatch(stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: timeoutMs, startedAt: now())
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
               abs(observation.position - restoredPosition) <= Double(positionToleranceMs) / 1000 {
                return
            }
            let verdict = watch.check(at: now(), readings: [observation.buffered])
            if verdict != .wait {
                throw playbackBackendError(
                    code: "playback_backend_activation_not_ready",
                    message: verdict == .stalled
                        ? "The standard playback candidate made no progress for \(stallTimeoutMs) ms while restoring playback."
                        : "The standard playback candidate timed out (\(timeoutMs) ms) while restoring playback."
                )
            }
            waitForNextPoll()
        }
    }
}

private func waitForStandardPlaybackActivation(
    player: QueuedAudioPlayer,
    snapshot: PlaybackBackendSnapshot,
    timeoutMs: Int,
    positionToleranceMs: Int,
    stallTimeoutMs: Int
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
        timeoutMs: timeoutMs,
        stallTimeoutMs: stallTimeoutMs,
        positionToleranceMs: positionToleranceMs,
        observe: {
            StandardPlaybackReadinessObservation(
                state: player.playerState,
                index: player.currentIndex,
                position: player.currentTime,
                buffered: player.bufferedPosition
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
    /// Whether it plays as far as an interruption is concerned: what the module last asked
    /// (play, pause, stop...), not a pause the system made for the interruption itself.
    var interruptionIsPlaying: Bool { get }
    /// Whether a load, skip, seek or retry would start the audio now (`commandStartsPlayback`).
    var startingCommandPlays: Bool { get }
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
    /// How long a seek may take in all (`standardSeekTimeoutMs`, 60000 ms by default), read at
    /// every seek.
    private let seekTimeoutMs: () -> Int
    /// How far a restored position may be off at a backend switch (`backendSwitchPositionToleranceMs`).
    private let positionToleranceMs: () -> Int
    /// How long a seek or a readiness wait may go on with no progress (`stallTimeoutMs`).
    private let stallTimeoutMs: () -> Int
    private let queueState = PlaybackBackendQueueState<Track>()
    private var pendingSnapshot = PlaybackBackendSnapshot.empty
    private var idleWithoutActiveTrack = false
    private var isAuthoritative: Bool
    private var controlSurfaceRelinquished = false
    private var disposed = false
    // SwiftAudioEx's seek event has no item or command identifier: NativeSeekLedger matches
    // each callback to the native seek it completes.
    private final class PendingSeek {
        let track: Track
        let position: Double
        var completion: ((Result<Void, Error>) -> Void)?
        /// The seek's wait (stallTimeoutMs once issued, standardSeekTimeoutMs in all).
        var wait: StallWaitDriver?
        /// Issued to the player: from then on, a stall of the buffered position fails it.
        var issued = false

        init(track: Track, position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
            self.track = track
            self.position = position
            self.completion = completion
        }

        // A request dropped without a result stops its wait instead of leaving it to the cap.
        deinit {
            wait?.cancel()
        }

        func finish(_ result: Result<Void, Error>) {
            let callback = completion
            completion = nil
            wait?.cancel()
            wait = nil
            callback?(result)
        }
    }
    private var pendingSeeks: [PendingSeek] = []
    private var issuedSeek: PendingSeek?
    private var nativeSeeks = NativeSeekLedger<PendingSeek>()
    private var seekReadinessPoll: DispatchWorkItem?
    /// The stall rule on this player's loads (nil: none, tests); see `observeLoad`.
    private let loadWatch: StandardLoadWatch?
    private var loadDriver: StandardLoadDriver?
    private let stateListener = NSObject()
    /// Told when a load or seek was given up (the player stopped loading and is in error);
    /// `report`: also emit it as a playback error (a load no command waits for).
    private let onLoadGaveUp: (QueuedAudioPlayer, IOSPlaybackErrorSnapshot, Bool) -> Void
    /// The load or seek given up, until the next command: the player is in error (SwiftAudioEx
    /// itself is stopped), and a failed seek keeps its target as the position.
    private(set) var hostFailure: IOSPlaybackErrorSnapshot? {
        get { return giveUpState?.failure }
        set { giveUpState = newValue.map { StandardGiveUp(failure: $0, keptPosition: nil) } }
    }
    private var giveUpState: StandardGiveUp<IOSPlaybackErrorSnapshot>?
    /// Which track is active around a load, and when the app is told (the crossfade rule): a track
    /// is reported once it loaded, never one that failed to load.
    private let failedLoads = FailedLoadRule()
    private var sawPlayerFailure = false
    /// The position of the track the player left at its last item change (lastPosition).
    private var lastItemPosition: Double = 0
    /// Reports a change of the active track: the player, its index (nil: none), the track the app
    /// had and its index (nil: none), and that track's last position (s).
    private let onActiveTrackChanged: (QueuedAudioPlayer, Int?, Track?, Int?, Double) -> Void
    /// A load failed: the active track's index (nil: none), for the lock screen to show it again.
    private let onLoadFailed: (QueuedAudioPlayer, Int?) -> Void
    // SwiftAudioEx retains the listener during asynchronous removal. Use a
    // separate identity so deinit never passes its dying self to that closure.
    private let seekListener = NSObject()
    private(set) var queueReloadCount = 0

    init(
        player: QueuedAudioPlayer,
        transitionGenerationSidecar: PlaybackTransitionGenerationSidecar,
        // The app's standardReadyTimeoutMs, standardSeekTimeoutMs and stallTimeoutMs, read at
        // every wait.
        readinessTimeoutMs: @escaping () -> Int,
        positionToleranceMs: @escaping () -> Int = { backendSwitchPositionToleranceDefaultMs },
        seekTimeoutMs: @escaping () -> Int,
        stallTimeoutMs: @escaping () -> Int,
        /// The app's `prepareTimeoutMs`: a load's total limit. Nil: loads are not watched.
        prepareTimeoutMs: (() -> Int)? = nil,
        onLoadGaveUp: @escaping (QueuedAudioPlayer, IOSPlaybackErrorSnapshot, Bool) -> Void = { _, _, _ in },
        onActiveTrackChanged: @escaping (QueuedAudioPlayer, Int?, Track?, Int?, Double) -> Void = { _, _, _, _, _ in },
        onLoadFailed: @escaping (QueuedAudioPlayer, Int?) -> Void = { _, _ in },
        automaticallyUpdateNowPlayingInfo: @escaping () -> Bool,
        onCommitted: @escaping (QueuedAudioPlayer) -> Void,
        onActivated: @escaping (QueuedAudioPlayer) -> Void,
        onDisposed: @escaping (QueuedAudioPlayer) -> Void,
        onIdleTrackActivationWillBegin: @escaping (QueuedAudioPlayer) -> Void = { _ in },
        onIdleTrackActivated: @escaping (QueuedAudioPlayer, Int?) -> Void = { _, _ in },
        waitForActivationReadiness: (
            (QueuedAudioPlayer, PlaybackBackendSnapshot) throws -> Void
        )? = nil,
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
        self.seekTimeoutMs = seekTimeoutMs
        self.positionToleranceMs = positionToleranceMs
        self.stallTimeoutMs = stallTimeoutMs
        self.loadWatch = prepareTimeoutMs.map { StandardLoadWatch(stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: $0) }
        self.onLoadGaveUp = onLoadGaveUp
        self.onActiveTrackChanged = onActiveTrackChanged
        self.onLoadFailed = onLoadFailed
        // The app's readiness timeout (standardReadyTimeoutMs), read at every activation.
        self.waitForActivationReadiness = waitForActivationReadiness ?? { player, snapshot in
            try waitForStandardPlaybackActivation(
                player: player,
                snapshot: snapshot,
                timeoutMs: readinessTimeoutMs(),
                positionToleranceMs: positionToleranceMs(),
                stallTimeoutMs: stallTimeoutMs()
            )
        }
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
        if let watch = loadWatch {
            // The player's events drive the watch; one timer only while a load is watched.
            loadDriver = StandardLoadDriver(
                watch: watch,
                observe: { [unowned self] in self.observeLoad() },
                giveUp: { [unowned self] verdict in self.giveUpLoad(verdict, watch: watch) }
            )
            player.event.stateChange.addListener(stateListener) { [weak self] _ in
                DispatchQueue.main.async { self?.loadDriver?.poke() }
            }
            DispatchQueue.main.async { [weak self] in self?.loadDriver?.poke() }
        }
    }

    deinit {
        loadDriver?.stop()
        player.event.stateChange.removeListener(stateListener)
        seekReadinessPoll?.cancel()
        player.event.seek.removeListener(seekListener)
    }

    private func onMain<Value>(_ operation: () throws -> Value) rethrows -> Value {
        if Thread.isMainThread { return try operation() }
        return try DispatchQueue.main.sync(execute: operation)
    }

    /// What the load watch sees, after feeding `failedLoads` (ready, failures): the stall rule on
    /// this player's loads, as the crossfade path and Android's standard player (no command waits
    /// for a standard load). Only while it is the authoritative backend (a candidate's readiness is
    /// `StandardPlaybackReadinessGate`'s); a waited seek owns its loading (its own limits). Main.
    private func observeLoad() -> StandardLoadObservation {
        guard isAuthoritative, !disposed, hostFailure == nil, !idleWithoutActiveTrack else {
            return StandardLoadObservation(item: nil, phase: .idle, readings: [])
        }
        let observed = StandardLoadObservation(
            item: (player.currentItem as AnyObject?).map(ObjectIdentifier.init),
            phase: standardLoadPhase(stateRawValue: player.playerState.rawValue, bufferedPosition: player.bufferedPosition),
            readings: [player.bufferedPosition],
            ownedElsewhere: issuedSeek != nil || !pendingSeeks.isEmpty
        )
        followLoad(observed)
        return observed
    }

    private func giveUpLoad(_ verdict: StallVerdict, watch: StandardLoadWatch) {
        let reason = verdict.reason(stallTimeoutMs: watch.lastStallTimeoutMs, totalTimeoutMs: watch.lastTotalTimeoutMs)
        giveUp(
            log: "load \(reason)",
            failure: IOSPlaybackErrorSnapshot(
                message: standardLoadGiveUpMessage(verdict, stallTimeoutMs: watch.lastStallTimeoutMs, totalTimeoutMs: watch.lastTotalTimeoutMs),
                code: standardPrepareTimeoutCode
            ),
            report: true
        )
    }

    /// Feeds `failedLoads`: when the item is ready, and a player failure.
    private func followLoad(_ observed: StandardLoadObservation) {
        guard observed.item != nil else { return }
        if observed.phase == .failed {
            if !sawPlayerFailure {
                sawPlayerFailure = true
                failLoadedTrack()
            }
            return
        }
        sawPlayerFailure = false
        if observed.ownedElsewhere { return }
        if observed.phase == .ready, let change = failedLoads.ready() { report(change) }
    }

    private func indexOfItem(_ item: ObjectIdentifier?) -> Int? {
        guard let item = item else { return nil }
        return player.items.firstIndex { ObjectIdentifier($0 as AnyObject) == item }
    }

    private func trackOf(_ item: ObjectIdentifier?) -> Track? {
        guard let index = indexOfItem(item) else { return nil }
        return player.items[index] as? Track
    }

    /// A load failed: the previous track stays active (none when there was none), as the crossfade
    /// path and Android; the lock screen shows it again.
    private func failLoadedTrack() {
        IOSPlaybackLog.log("standard load failed index=\(player.currentIndex) activeIndex=\(indexOfItem(failedLoads.active).map(String.init) ?? "none")")
        if let change = failedLoads.failed() { report(change) }
        if failedLoads.isPending((player.currentItem as AnyObject?).map(ObjectIdentifier.init)) {
            onLoadFailed(player, indexOfItem(failedLoads.reported))
        }
    }

    private func report(_ change: FailedLoadRule.Report) {
        onActiveTrackChanged(player, indexOfItem(change.to), trackOf(change.from), indexOfItem(change.from), lastItemPosition)
    }

    /// The player moved to `item` (its current-item event, with the last track's position):
    /// whether to report it now (only a new queue's first track); else once it loaded.
    func itemMoved(_ item: AudioItem?, lastPosition: Double) -> Bool {
        return onMain {
            lastItemPosition = lastPosition
            let moved = failedLoads.moved((item as AnyObject?).map(ObjectIdentifier.init))
            loadDriver?.poke()
            return moved
        }
    }

    /// Before a play or retry after a failed load: the previous track, else the failed one, loads.
    @discardableResult
    private func loadActiveTrackAfterFailedLoad() -> Bool {
        guard let target = indexOfItem(failedLoads.play()), target != player.currentIndex else { return false }
        try? player.jumpToItem(atIndex: target, playWhenReady: player.playWhenReady)
        return true
    }

    /// Out of the error state, a failed seek's target stays the position until the track loads.
    private func keepPosition(_ kept: Double?) {
        giveUpState = kept.map { StandardGiveUp(failure: nil, keptPosition: $0) }
    }

    /// After a failed seek: the track loads again at the seek's target (kept as the position),
    /// as Android's player resumes from it; SwiftAudioEx applies the seek once the item loaded.
    private func reloadAtKeptPosition(_ kept: Double?) {
        guard let kept = kept else { return }
        player.reload(startFromCurrentTime: false)
        player.seek(to: kept)
    }

    /// Ends a load or seek given up: SwiftAudioEx stops (its item leaves the AVPlayer, which stops
    /// requesting media) and the player is in error with `failure` until the next command.
    private func giveUp(log: String, failure: IOSPlaybackErrorSnapshot, report: Bool, keptPosition: Double? = nil) {
        IOSPlaybackLog.log("standard load abandoned (\(log))")
        giveUpState = StandardGiveUp(failure: failure, keptPosition: keptPosition)
        requested.request(false)
        player.stop()
        onLoadGaveUp(player, failure, report)
        if report { failLoadedTrack() }
    }

    /// A command after a give-up: the player is no longer in that error. Returns the position a
    /// failed seek kept, for a play or retry to load the track there.
    @discardableResult
    private func clearHostFailure() -> Double? {
        let kept = giveUpState?.keptPosition
        giveUpState = nil
        return kept
    }

    private func seekError(_ code: String, _ message: String) -> Error {
        playbackBackendError(code: code, message: message)
    }

    private func enqueueSeek(to position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        clearHostFailure()
        _ = failedLoads.command()
        guard !disposed, let track = player.currentItem as? Track else {
            completion(.failure(seekError("standard_seek_unavailable", "No active track is available for seeking.")))
            return
        }
        guard position.isFinite else {
            completion(.failure(seekError("standard_seek_invalid_position", "The seek position must be finite.")))
            return
        }
        let request = PendingSeek(track: track, position: max(0, position), completion: completion)
        // Until the seek is issued (queued behind another seek, or waiting for the item to load,
        // for example after a stop) only standardSeekTimeoutMs bounds it; once issued, it also
        // fails when the player's buffered position does not grow for stallTimeoutMs. That
        // position (the end of the last loaded range) is the only signal SwiftAudioEx exposes:
        // a seek far from the loaded range shows no growth until its first data arrives.
        let wait = StallWaitDriver(
            stallTimeoutMs: stallTimeoutMs(),
            totalTimeoutMs: seekTimeoutMs(),
            readings: { [weak self, weak request] in
                guard let self = self, let request = request, request.issued else { return nil }
                return [self.player.bufferedPosition]
            }
        ) { [weak self, weak request] verdict, watch in
            guard let self = self, let request = request, request.completion != nil else { return }
            self.pendingSeeks.removeAll { $0 === request }
            let message = verdict == .stalled
                ? "The native seek made no progress for \(watch.stallTimeoutMs) ms."
                : "The native seek did not complete within \(watch.totalTimeoutMs) ms."
            // As a crossfade seek that gives up: the player stops loading and is in error (the
            // rejection is the report: no playback error on top of it).
            if request.issued, (self.player.currentItem as? Track) === request.track {
                self.giveUp(
                    log: "seek \(message)",
                    failure: IOSPlaybackErrorSnapshot(message: message, code: "standard_seek_timeout"),
                    report: false,
                    keptPosition: request.position
                )
            }
            // If already emitted, keep the ticket until its real callback. A
            // timeout does not make a late, identical SDK event distinguishable.
            request.finish(.failure(self.seekError("standard_seek_timeout", message)))
            self.pumpSeeks()
        }
        request.wait = wait
        // A newer seek ends the older ones at once (standard_seek_cancelled), as on Android.
        let superseded = pendingSeeks
        pendingSeeks.removeAll()
        superseded.forEach {
            $0.finish(.failure(seekError("standard_seek_cancelled", "A newer seek replaced this one.")))
        }
        if let issued = issuedSeek {
            // Its native callback still comes (NativeSeekLedger) but resolves nothing.
            issuedSeek = nil
            nativeSeeks.release(issued)
            issued.finish(.failure(seekError("standard_seek_cancelled", "A newer seek replaced this one.")))
        }
        pendingSeeks.append(request)
        wait.start()
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
            request.issued = true
            request.wait?.noteProgress()
            nativeSeeks.issued(request, at: request.position)
            player.seek(to: request.position)
            return
        }
    }

    private func didCompleteNativeSeek(position: Double, didFinish: Bool) {
        // Matched by the seek it completes, not by position alone (A, B, then A again).
        guard let request = nativeSeeks.completed(at: position) else { return }
        if issuedSeek === request { issuedSeek = nil }
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
        if hostFailure != nil { return .error }
        return idleWithoutActiveTrack ? .none : State.fromPlayerState(state: player.playerState)
    }
    var publicPlaybackError: IOSPlaybackErrorSnapshot? {
        return hostFailure ?? iosPlaybackErrorSnapshot(from: player.playbackError)
    }
    var currentIndex: Int {
        if failedLoads.isPending((player.currentItem as AnyObject?).map(ObjectIdentifier.init)) {
            return indexOfItem(failedLoads.reported) ?? -1
        }
        return idleWithoutActiveTrack ? -1 : player.currentIndex
    }
    var position: Double {
        // A failed seek keeps its target (SwiftAudioEx's stop reset its own position).
        return giveUpState?.position(live: idleWithoutActiveTrack ? 0 : player.currentTime)
            ?? (idleWithoutActiveTrack ? 0 : player.currentTime)
    }
    var duration: Double { return idleWithoutActiveTrack ? 0 : player.duration }
    var bufferedPosition: Double { return idleWithoutActiveTrack ? 0 : player.bufferedPosition }
    var publicVolume: Float { return player.volume }
    var publicRate: Float { return player.rate }
    var publicPlayWhenReady: Bool { return !idleWithoutActiveTrack && player.playWhenReady }
    /// The module's last request, not SwiftAudioEx's own pause at the interruption (see
    /// RequestedPlayback).
    /// Read on main, where the player and `requested` change.
    var interruptionIsPlaying: Bool {
        return onMain {
            interruptionCountsAsPlaying(playWhenReady: requested.playWhenReady, stateRawValue: playbackState.rawValue)
        }
    }
    /// SwiftAudioEx's own playWhenReady: the one a load or skip starts the audio with. Read on main.
    var startingCommandPlays: Bool {
        return onMain {
            commandStartsPlayback(playWhenReady: publicPlayWhenReady, stateRawValue: playbackState.rawValue)
        }
    }
    private var requested = RequestedPlayback()

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
            clearHostFailure()
            _ = failedLoads.command()
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
            requested.request(false)
            player.pause()
            if let index = snapshot.activeIndex,
               queue.indices.contains(index) {
                let indexChanged = player.currentIndex != index
                if indexChanged {
                    try player.jumpToItem(atIndex: index, playWhenReady: false)
                }
                if queueChanged || indexChanged ||
                    abs(player.currentTime - max(0, snapshot.position)) > Double(positionToleranceMs()) / 1000 {
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
            requested.request(snapshot.playWhenReady)
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
        // A backend switch restored this track, ready (the readiness gate): the app has it.
        failedLoads.adopted(idleWithoutActiveTrack ? nil : (player.currentItem as AnyObject?).map(ObjectIdentifier.init))
        isAuthoritative = true
        loadDriver?.poke()
    }

    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {
        player.automaticallyUpdateNowPlayingInfo = automaticallyUpdateNowPlayingInfo()
        player.playWhenReady = !idleWithoutActiveTrack && snapshot.playWhenReady
        requested.request(player.playWhenReady)
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
            let kept = clearHostFailure()
            let wasIdle = idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            loadActiveTrackAfterFailedLoad()
            reloadAtKeptPosition(kept)
            requested.request(true)
            player.play()
            publishIdleTrackActivationIfNeeded(wasIdle)
        }
    }
    func pause() {
        onMain {
            cancelPendingSeeks()
            requested.request(false)
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
            loadDriver?.stop()
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
            clearHostFailure()
            // A new queue: its first track is a new selection.
            failedLoads.reset()
            cancelPendingSeeks()
            player.clear()
            try player.add(items: tracks)
            if tracks.isEmpty { idleWithoutActiveTrack = false }
        }
    }

    func clearQueue() {
        onMain {
            clearHostFailure()
            failedLoads.reset()
            cancelPendingSeeks()
            player.clear()
            idleWithoutActiveTrack = false
        }
    }

    func load(_ track: Track, completion: @escaping (Result<Int, Error>) -> Void) {
        onMain {
            clearHostFailure()
            _ = failedLoads.command()
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
            clearHostFailure()
            _ = failedLoads.command()
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
            clearHostFailure()
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
            // After a failed load, next is relative to the active (previous) track, as Android.
            if failedLoads.isPending((player.currentItem as AnyObject?).map(ObjectIdentifier.init)), let active = indexOfItem(failedLoads.reported), active + 1 < player.items.count {
                _ = failedLoads.command()
                try? player.jumpToItem(atIndex: active + 1, playWhenReady: player.playWhenReady)
            } else {
                _ = failedLoads.command()
                player.next()
            }
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
            clearHostFailure()
            if failedLoads.isPending((player.currentItem as AnyObject?).map(ObjectIdentifier.init)), let active = indexOfItem(failedLoads.reported), active - 1 >= 0 {
                _ = failedLoads.command()
                try? player.jumpToItem(atIndex: active - 1, playWhenReady: player.playWhenReady)
            } else {
                _ = failedLoads.command()
                player.previous()
            }
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
            keepPosition(clearHostFailure())
            _ = failedLoads.command()
            cancelPendingSeeks()
            requested.request(false)
            player.stop()
        }
    }

    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain {
            let kept = clearHostFailure()
            if !value { cancelPendingSeeks() }
            let wasIdle = value && idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            if value {
                loadActiveTrackAfterFailedLoad()
                reloadAtKeptPosition(kept)
            } else {
                keepPosition(kept)
            }
            player.playWhenReady = value
            requested.request(value)
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
        let kept = clearHostFailure()
        let wasIdle = idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        if wasIdle { idleWithoutActiveTrack = false }
        let jumped = loadActiveTrackAfterFailedLoad()
        if kept != nil {
            reloadAtKeptPosition(kept)
        } else if !jumped {
            player.reload(startFromCurrentTime: true)
        }
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
        // The app is told of this track now (the idle activation's own event).
        failedLoads.published((player.currentItem as AnyObject?).map(ObjectIdentifier.init))
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
