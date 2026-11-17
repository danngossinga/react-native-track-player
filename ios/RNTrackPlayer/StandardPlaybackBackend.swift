import AVFoundation
import Foundation
import SwiftAudioEx

/// The standard player's now-playing writes (the lock screen), held while the standard backend
/// shows the reported track and another loads (ReportedNowPlaying, rule 13): SwiftAudioEx writes
/// the loading item's title, artwork (also later, when that artwork arrives) and times at its
/// load and at its state changes, which would replace the reported track's. While held those
/// writes are dropped; `direct` always writes (the reported track's metadata, the app's own
/// updates). Chosen over turning `automaticallyUpdateNowPlayingInfo` off during the load: a
/// natural advance's load writes before the backend hears of it, and the artwork callback does
/// not read that flag. Set on both QueuedAudioPlayers (RNTrackPlayer).
final class StandardNowPlayingInfoController: NowPlayingInfoControllerProtocol {
    private let base: NowPlayingInfoController
    private let lock = NSLock()
    private var held = false

    required init() {
        base = NowPlayingInfoController()
    }

    required init(infoCenter: NowPlayingInfoCenter) {
        base = NowPlayingInfoController(infoCenter: infoCenter)
    }

    /// Writes that always go through.
    var direct: NowPlayingInfoControllerProtocol { return base }

    /// Whether SwiftAudioEx's own writes are dropped (another track loads).
    var isHeld: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return held
        }
        set {
            lock.lock()
            held = newValue
            lock.unlock()
        }
    }

    func set(keyValue: NowPlayingInfoKeyValue) {
        if !isHeld { base.set(keyValue: keyValue) }
    }

    func set(keyValues: [NowPlayingInfoKeyValue]) {
        if !isHeld { base.set(keyValues: keyValues) }
    }

    func setWithoutUpdate(keyValues: [NowPlayingInfoKeyValue]) {
        if !isHeld { base.setWithoutUpdate(keyValues: keyValues) }
    }

    /// A cleared player (no item) clears the lock screen, held or not.
    func clear() {
        base.clear()
    }
}

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
        /// Until the next reading: the next player event, or a tenth of the stall timeout.
        waitForNextPoll: () -> Void
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
    // The wait looks at every player event (state, duration, seek) and, between them, every
    // stallTimeoutMs / 10 (as the load watch and Android): no fixed poll.
    let wake = DispatchSemaphore(value: 0)
    let listener = NSObject()
    player.event.stateChange.addListener(listener) { _ in wake.signal() }
    player.event.updateDuration.addListener(listener) { _ in wake.signal() }
    player.event.seek.addListener(listener) { _ in wake.signal() }
    defer {
        player.event.stateChange.removeListener(listener)
        player.event.updateDuration.removeListener(listener)
        player.event.seek.removeListener(listener)
    }
    let sampleMs = standardLoadSampleIntervalMs(stallTimeoutMs)
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
        },
        waitForNextPoll: { _ = wake.wait(timeout: .now() + .milliseconds(sampleMs)) }
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
    /// A load's progress: its item's access-log bytes (see StandardLoadBytes).
    private let loadBytes = StandardLoadBytes()
    /// AVFoundation's item notifications (access-log and error-log entries, a failure), which
    /// check the load at once when they are its item's.
    private var itemObservers: [NSObjectProtocol] = []
    /// Told when a load or seek was given up (the player stopped loading and is in error), with
    /// the events to emit.
    private let onLoadGaveUp: (QueuedAudioPlayer, StandardGiveUpReport) -> Void
    /// The load sequences (PlaybackBackend.swift, tested): this backend is its player
    /// (`StandardLoadPlayer`). Set in init, before any event.
    private var loads: StandardLoadCoordinator!
    /// The load or seek given up, until the next command: the player is in error (SwiftAudioEx
    /// itself is stopped), and a failed seek keeps its target as the position.
    private var giveUps: StandardGiveUps { return loads.giveUps }
    var hostFailure: IOSPlaybackErrorSnapshot? { return loads.hostFailure }
    /// Which track is active around a load, and when the app is told (the crossfade rule): a track
    /// is reported once it loaded, never one that failed to load.
    private var failedLoads: FailedLoadRule { return loads.failedLoads }
    /// Skip, next, previous and load end once their track loaded, or with its failure (crossfade's rule).
    private var commandLoads: StandardCommandLoad { return loads.commandLoads }
    /// The position of the track the player left at its last item change (lastPosition).
    private var lastItemPosition: Double = 0
    /// Reports a change of the active track: the player, its index (nil: none), the track the app
    /// had and its index (nil: none), and that track's last position (s).
    private let onActiveTrackChanged: (QueuedAudioPlayer, Int?, Track?, Int?, Double) -> Void
    /// A load failed: the active track's index (nil: none), for the lock screen to show it again.
    private let onLoadFailed: (QueuedAudioPlayer, Int?) -> Void
    /// What the lock screen shows (ReportedNowPlaying): the reported track's index (nil: the
    /// player's own item), and whether SwiftAudioEx's own updates are held (another track loads).
    private let onNowPlaying: (QueuedAudioPlayer, Int?, Bool) -> Void
    /// What the progress readers see: the reported track's (rule 13).
    private let progress = ReportedTrackProgress()
    /// What the lock screen shows: the reported track (rule 13).
    private let nowPlaying = ReportedNowPlaying()
    // SwiftAudioEx retains the listener during asynchronous removal. Use a
    // separate identity so deinit never passes its dying self to that closure.
    private let seekListener = NSObject()
    /// The player's state and duration events, for a seek waiting for its item to load.
    private let seekEventListener = NSObject()
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
        onLoadGaveUp: @escaping (QueuedAudioPlayer, StandardGiveUpReport) -> Void = { _, _ in },
        onActiveTrackChanged: @escaping (QueuedAudioPlayer, Int?, Track?, Int?, Double) -> Void = { _, _, _, _, _ in },
        onLoadFailed: @escaping (QueuedAudioPlayer, Int?) -> Void = { _, _ in },
        onNowPlaying: @escaping (QueuedAudioPlayer, Int?, Bool) -> Void = { _, _, _ in },
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
        self.onNowPlaying = onNowPlaying
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
        loads = StandardLoadCoordinator(player: self, watched: loadWatch != nil)
        player.event.seek.addListener(seekListener) { [weak self] event in
            DispatchQueue.main.async {
                self?.didCompleteNativeSeek(position: event.seconds, didFinish: event.didFinish)
            }
        }
        // A seek waiting for its item to load is issued at the player's next event.
        player.event.stateChange.addListener(seekEventListener) { [weak self] _ in
            DispatchQueue.main.async { self?.pumpSeeksWaitingForTheItem() }
        }
        player.event.updateDuration.addListener(seekEventListener) { [weak self] _ in
            DispatchQueue.main.async { self?.pumpSeeksWaitingForTheItem() }
        }
        if let watch = loadWatch {
            // The player's events drive the watch; one timer only while a load is watched.
            loadDriver = StandardLoadDriver(
                watch: watch,
                observe: { [unowned self] in self.observeLoad() },
                giveUp: { [unowned self] verdict in
                    self.loads.giveUpLoad(verdict, stallTimeoutMs: watch.lastStallTimeoutMs, totalTimeoutMs: watch.lastTotalTimeoutMs)
                }
            )
            player.event.stateChange.addListener(stateListener) { [weak self] _ in
                DispatchQueue.main.async { self?.loadDriver?.poke() }
            }
            // The item's own events, as Android's player events: posted on any queue, with any
            // player's item (filtered on main).
            itemObservers = [.AVPlayerItemNewAccessLogEntry, .AVPlayerItemNewErrorLogEntry, .AVPlayerItemFailedToPlayToEndTime].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                    guard let item = notification.object as? AVPlayerItem else { return }
                    DispatchQueue.main.async { self?.itemEvent(item) }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.loadDriver?.poke() }
        }
    }

    deinit {
        loadDriver?.stop()
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        player.event.stateChange.removeListener(stateListener)
        seekReadinessPoll?.cancel()
        player.event.seek.removeListener(seekListener)
        player.event.stateChange.removeListener(seekEventListener)
        player.event.updateDuration.removeListener(seekEventListener)
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
        guard isAuthoritative, !disposed, hostFailure == nil, !idleWithoutActiveTrack, let watch = loadWatch else {
            return StandardLoadObservation(item: nil, phase: .idle, readings: [])
        }
        let item = (player.currentItem as AnyObject?).map(ObjectIdentifier.init)
        let phase = standardLoadPhase(stateRawValue: player.playerState.rawValue, bufferedPosition: player.bufferedPosition)
        let ownedElsewhere = issuedSeek != nil || !pendingSeeks.isEmpty
        // A new load's progress starts before its first reading (Android: startLoad).
        if watch.startsLoad(StandardLoadObservation(item: item, phase: phase, readings: [], ownedElsewhere: ownedElsewhere)) {
            loadBytes.startLoad(url: currentAssetURL())
        }
        let playerItem = standardPlayerItem(of: player)
        if case let .item(current) = playerItem {
            loadBytes.playerItem(current)
        }
        // None while the player has no AVPlayerItem (the playable stage: only the total limit).
        let observed = StandardLoadObservation(
            item: item,
            phase: phase,
            readings: standardLoadReadings(playerItem, bytes: loadBytes.read(standardAccessLogBytes), buffered: player.bufferedPosition),
            ownedElsewhere: ownedElsewhere
        )
        loads.followLoad(observed)
        // At every player event: the reported track's progress is kept while the player is on
        // it, and the lock screen follows the reported track.
        _ = reportedProgress()
        followNowPlaying()
        return observed
    }

    /// The lock screen shows the reported track (ReportedNowPlaying); only the authoritative
    /// backend's. Main.
    func followNowPlaying() {
        guard isAuthoritative, !disposed else { return }
        let current = (player.currentItem as AnyObject?).map(ObjectIdentifier.init)
        if let change = nowPlaying.follow(reported: failedLoads.reported, playerItem: current) {
            onNowPlaying(player, indexOfItem(change.item), change.held)
        }
    }

    /// The URL of the current track's asset, as SwiftAudioEx builds it.
    private func currentAssetURL() -> URL? {
        guard let track = player.currentItem else { return nil }
        return standardAssetURL(source: track.getSourceUrl(), isFile: track.getSourceType() == .file)
    }

    /// An AVPlayerItem event (any player's): checks the load at once when it is this load's item.
    private func itemEvent(_ item: AVPlayerItem) {
        guard !disposed else { return }
        let url = (item.asset as? AVURLAsset)?.url
        if loadBytes.isLoadEvent(item, url: url, player: standardPlayerItem(of: player)) {
            loadDriver?.poke()
        }
    }

    /// Waits for the load a command started (StandardLoadCoordinator.waitForCommandLoad, tested),
    /// its outcome as the command's result. Main.
    private func waitForCommandLoad(_ completion: @escaping (Result<Void, Error>) -> Void) {
        loads.waitForCommandLoad { outcome in completion(standardCommandLoadResult(outcome)) }
    }

    /// After a command's load: its initial position (`initialTime`, or 0 for the same track), as
    /// Android's skip then seekTo; else done.
    private func finishCommandLoad(seekTo position: Double?, completion: @escaping (Result<Void, Error>) -> Void) {
        waitForCommandLoad { [weak self] result in
            guard let self = self, case .success = result, let position = position else {
                completion(result)
                return
            }
            self.enqueueSeek(to: position, completion: completion)
        }
    }

    /// The track a command waits for left the queue: its wait ends cancelled.
    private func cancelCommandLoadOfRemovedTrack() {
        guard commandLoads.isWaiting else { return }
        if !player.items.contains(where: { commandLoads.waits(for: ObjectIdentifier($0 as AnyObject)) }) {
            commandLoads.cancel()
        }
    }

    /// Whether SwiftAudioEx's own state event is emitted (StandardLoadCoordinator.emitsPlayerState,
    /// tested): not its `stopped` after a give-up.
    func emitsPlayerState(_ stateRawValue: String) -> Bool {
        return loads.emitsPlayerState(stateRawValue)
    }

    /// Whether the player's current error is a command's to report (its rejection): no playback
    /// error event for it, as the crossfade path (RNTrackPlayer.handleAudioPlayerFailed).
    func reportsPlayerErrorThroughCommand() -> Bool {
        return onMain { commandLoads.reportsFailure(of: (player.currentItem as AnyObject?).map(ObjectIdentifier.init)) }
    }

    private func indexOfItem(_ item: ObjectIdentifier?) -> Int? {
        guard let item = item else { return nil }
        return player.items.firstIndex { ObjectIdentifier($0 as AnyObject) == item }
    }

    private func trackOf(_ item: ObjectIdentifier?) -> Track? {
        guard let index = indexOfItem(item) else { return nil }
        return player.items[index] as? Track
    }

    private func report(_ change: FailedLoadRule.Report, lastIndex: Int?? = nil, lastTrack: Track? = nil) {
        onActiveTrackChanged(
            player,
            indexOfItem(change.to),
            lastTrack ?? trackOf(change.from),
            lastIndex ?? indexOfItem(change.from),
            lastItemPosition
        )
        followNowPlaying()
    }

    /// The reported track left the queue: no active track, reported at once (as the crossfade
    /// path's queue change); the player's next track is reported once it loaded. As Android.
    private func reportRemovedTrack(_ before: [AudioItem]) {
        guard let reported = failedLoads.reported, indexOfItem(reported) == nil else { return }
        let lastIndex = before.firstIndex { ObjectIdentifier($0 as AnyObject) == reported }
        let lastTrack = lastIndex.flatMap { before[$0] as? Track }
        if let change = failedLoads.removed(reported) { report(change, lastIndex: .some(lastIndex), lastTrack: lastTrack) }
    }

    /// The player moved to `item` (its current-item event, with the last track's position):
    /// whether to report it now (only a new queue's first track); else once it loaded.
    func itemMoved(_ item: AudioItem?, lastItem: AudioItem?, lastPosition: Double) -> Bool {
        return onMain {
            lastItemPosition = lastPosition
            // The track the player left: its last position, while another loads (rule 13).
            progress.left((lastItem as AnyObject?).map(ObjectIdentifier.init), position: lastPosition)
            let moved = failedLoads.moved((item as AnyObject?).map(ObjectIdentifier.init))
            // SwiftAudioEx has shown the new item on the lock screen: the reported one again.
            followNowPlaying()
            loadDriver?.poke()
            return moved
        }
    }

    /// A seek, pause or stop that cancelled a command's wait while its track loads
    /// (`standardTrackToReturnTo`): the cancelled command does not take effect, as crossfade's
    /// operation cancelled while it loads. The player goes back to the reported track, paused, at
    /// `position` (nil: where the player left that track), which stops the other track's load. As
    /// Android.
    private func returnToReportedTrack(_ cancelledWait: Bool, at position: Double?) {
        let current = (player.currentItem as AnyObject?).map(ObjectIdentifier.init)
        guard let target = standardTrackToReturnTo(cancelledWait: cancelledWait, playerItem: current, reported: failedLoads.reported),
              let index = indexOfItem(target) else { return }
        let kept = position ?? reportedProgress().position
        requested.request(false)
        try? player.jumpToItem(atIndex: index, playWhenReady: false)
        // A seek issues its own (once the item loaded); SwiftAudioEx defers this one until then.
        if position == nil { player.seek(to: kept) }
    }

    /// Before a play or retry after a failed load: the previous track, else the failed one, loads.
    @discardableResult
    private func loadActiveTrackAfterFailedLoad() -> Bool {
        guard let target = indexOfItem(failedLoads.play()), target != player.currentIndex else { return false }
        try? player.jumpToItem(atIndex: target, playWhenReady: player.playWhenReady)
        return true
    }

    /// After a failed seek: the track loads again at the seek's target (kept as the position),
    /// as Android's player resumes from it; SwiftAudioEx applies the seek once the item loaded.
    private func reloadAtKeptPosition(_ kept: Double?) {
        guard let kept = kept else { return }
        player.reload(startFromCurrentTime: false)
        player.seek(to: kept)
    }

    /// A command after a give-up: the player is no longer in that error. Returns the position a
    /// failed seek kept, for a play or retry to load the track there.
    @discardableResult
    private func clearHostFailure() -> Double? {
        return giveUps.clear()
    }

    private func seekError(_ code: String, _ message: String) -> Error {
        playbackBackendError(code: code, message: message)
    }

    private func enqueueSeek(to position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        // A newer command, as a crossfade seek: a skip or load still waiting ends cancelled, and
        // does not take effect: the seek acts on the active track.
        let cancelledWait = commandLoads.cancel()
        clearHostFailure()
        _ = failedLoads.command()
        returnToReportedTrack(cancelledWait, at: position)
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
        let stallMs = stallTimeoutMs()
        // Its progress is sampled every stallTimeoutMs / 10 (as the load watch and Android); the
        // seek itself ends at its native callback (event-driven).
        let wait = StallWaitDriver(
            stallTimeoutMs: stallMs,
            totalTimeoutMs: seekTimeoutMs(),
            intervalMs: standardLoadSampleIntervalMs(stallMs),
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
            self.loads.seekTimedOut(issued: request.issued, track: ObjectIdentifier(request.track), message: message, keptPosition: request.position)
            // If already emitted, keep the ticket until its real callback. A
            // timeout does not make a late, identical SDK event distinguishable.
            request.finish(.failure(self.seekError("standard_seek_timeout", message)))
            self.pumpSeeks()
            self.pokeLoadWatchAfterSeek()
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
                // Its track failed to load (a player error): it stays failed, as Android.
                loads.failLoadedTrack()
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
            // queue replacement cannot run between them. A stream with no length has
            // no duration for good: issued once its item is ready to play.
            guard standardSeekCanBeIssued(duration: player.duration, item: standardSeekItem(standardPlayerItem(of: player))) else {
                // Looked at again at the player's next event (state, duration: seekEventListener)
                // or after stallTimeoutMs / 10, whichever comes first: no fixed poll.
                let poll = DispatchWorkItem { [weak self] in self?.pumpSeeks() }
                seekReadinessPoll = poll
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(standardLoadSampleIntervalMs(stallTimeoutMs())), execute: poll)
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

    /// A player event while a seek waits for its item to load (pumpSeeks' poll is set): look now.
    private func pumpSeeksWaitingForTheItem() {
        guard seekReadinessPoll != nil else { return }
        pumpSeeks()
    }

    private func didCompleteNativeSeek(position: Double, didFinish: Bool) {
        // Matched by the seek it completes, not by position alone (A, B, then A again).
        guard let request = nativeSeeks.completed(at: position) else { return }
        let wasIssued = issuedSeek === request
        if wasIssued { issuedSeek = nil }
        let sameTrack = (player.currentItem as? Track) === request.track
        // On an item AVPlayer cannot seek in, an unfinished seek completes where the player is
        // (Android: where ExoPlayer lands).
        let seekable = standardSeekItem(standardPlayerItem(of: player)).seekable
        // A seek that fails for any reason stops loading (as the crossfade path); one a newer
        // seek replaced does not.
        loads.nativeSeekEnded(didFinish: didFinish, track: ObjectIdentifier(request.track), isLatest: wasIssued && pendingSeeks.isEmpty, seekable: seekable, keptPosition: request.position)
        request.finish(standardSeekEndCompletes(didFinish: didFinish, sameTrack: sameTrack, seekable: seekable) && !disposed
            ? .success(())
            : .failure(seekError("standard_seek_cancelled", "The native seek was interrupted.")))
        pumpSeeks()
        pokeLoadWatchAfterSeek()
    }

    private func cancelPendingSeeks() {
        seekReadinessPoll?.cancel()
        seekReadinessPoll = nil
        let waiting = pendingSeeks
        pendingSeeks.removeAll()
        let error = seekError("standard_seek_cancelled", "Playback changed before the native seek completed.")
        issuedSeek?.finish(.failure(error))
        waiting.forEach { $0.finish(.failure(error)) }
        pokeLoadWatchAfterSeek()
    }

    /// A seek ended (done, cancelled, given up): it no longer owns the loading, so the load watch
    /// looks again at once (as Android's seekTo finally), after the current change settles.
    private func pokeLoadWatchAfterSeek() {
        DispatchQueue.main.async { [weak self] in self?.loadDriver?.poke() }
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
    // The reported track's progress, as currentIndex (rule 13): while another track loads, the
    // reported one's as the player left it (ReportedTrackProgress).
    var position: Double { return reportedProgress().position }
    var duration: Double { return reportedProgress().duration }
    var bufferedPosition: Double { return reportedProgress().buffered }

    /// The player's own item's progress.
    private func liveProgress() -> TrackProgress {
        return TrackProgress(
            // A failed seek keeps its target (SwiftAudioEx's stop reset its own position).
            position: giveUps.position(live: idleWithoutActiveTrack ? 0 : player.currentTime),
            duration: idleWithoutActiveTrack ? 0 : player.duration,
            buffered: idleWithoutActiveTrack ? 0 : player.bufferedPosition
        )
    }

    private func reportedProgress() -> TrackProgress {
        return progress.read(
            reported: failedLoads.reported,
            playerItem: (player.currentItem as AnyObject?).map(ObjectIdentifier.init),
            live: liveProgress()
        )
    }
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
            // A new load: a failure of it no command waits for is reported again.
            commandLoads.failureCleared()
            let kept = clearHostFailure()
            let wasIdle = idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            // A failed seek's target is its own track's: not the active track's the play loads.
            if !loadActiveTrackAfterFailedLoad() { reloadAtKeptPosition(kept) }
            requested.request(true)
            player.play()
            publishIdleTrackActivationIfNeeded(wasIdle)
        }
    }
    func pause() {
        onMain {
            cancelPendingSeeks()
            // As crossfade's pause: a skip or load still waiting ends cancelled and does not take
            // effect. A give-up's error stays (Android: the same).
            returnToReportedTrack(commandLoads.cancel(), at: nil)
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
            loads.dispose()
            loadDriver?.stop()
            cancelPendingSeeks()
            isAuthoritative = false
            // The next owner of the lock screen (crossfade, another standard backend) writes freely.
            (player.nowPlayingInfoController as? StandardNowPlayingInfoController)?.isHeld = false
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
            let before = player.items
            for index in indexes {
                try player.removeItem(at: index)
            }
            cancelCommandLoadOfRemovedTrack()
            if player.items.isEmpty {
                idleWithoutActiveTrack = false
                failedLoads.reset()
            } else {
                reportRemovedTrack(before)
            }
        }
    }

    func move(from: Int, to: Int) throws {
        try onMain { try player.moveItem(fromIndex: from, toIndex: to) }
    }

    func removeUpcomingTracks() {
        onMain {
            guard !idleWithoutActiveTrack else { return }
            let before = player.items
            player.removeUpcomingItems()
            cancelCommandLoadOfRemovedTrack()
            reportRemovedTrack(before)
        }
    }

    func replaceQueue(_ tracks: [Track]) throws {
        try onMain {
            clearHostFailure()
            commandLoads.cancel()
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
            commandLoads.cancel()
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
            commandLoads.cancel()
            cancelPendingSeeks()
            let wasIdle = idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            player.load(item: track)
            publishIdleTrackActivationIfNeeded(wasIdle)
            // As crossfade's load: once the track loaded, or with its failure.
            waitForCommandLoad { [weak self] result in
                completion(result.map { self?.player.currentIndex ?? -1 })
            }
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
                commandLoads.cancel()
                cancelPendingSeeks()
                if wasIdle { idleWithoutActiveTrack = false }
                let sameIndex = player.currentIndex == index
                if !sameIndex {
                    try player.jumpToItem(atIndex: index, playWhenReady: player.playWhenReady)
                }
                publishIdleTrackActivationIfNeeded(wasIdle)
                // As crossfade's skip: once the track loaded, then the requested seek (jumpToItem
                // on the same item emits its own seek(0): issue only the requested one, and wait
                // for its real callback).
                finishCommandLoad(
                    seekTo: sameIndex || initialTime >= 0 ? (initialTime >= 0 ? initialTime : 0) : nil,
                    completion: completion
                )
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
            commandLoads.cancel()
            cancelPendingSeeks()
            if idleWithoutActiveTrack {
                beginIdleTrackActivationIfNeeded(true)
                do {
                    idleWithoutActiveTrack = false
                    if player.currentIndex != 0 {
                        try player.jumpToItem(atIndex: 0, playWhenReady: false)
                    }
                    publishIdleTrackActivationIfNeeded(true)
                    finishCommandLoad(seekTo: initialTime >= 0 ? initialTime : nil, completion: completion)
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
            finishCommandLoad(seekTo: initialTime >= 0 ? initialTime : nil, completion: completion)
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
            commandLoads.cancel()
            cancelPendingSeeks()
            clearHostFailure()
            if failedLoads.isPending((player.currentItem as AnyObject?).map(ObjectIdentifier.init)), let active = indexOfItem(failedLoads.reported), active - 1 >= 0 {
                _ = failedLoads.command()
                try? player.jumpToItem(atIndex: active - 1, playWhenReady: player.playWhenReady)
            } else {
                _ = failedLoads.command()
                player.previous()
            }
            finishCommandLoad(seekTo: initialTime >= 0 ? initialTime : nil, completion: completion)
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
            // As Android: the stop ends a give-up's error, and the app is told it stopped.
            let ended = giveUps.stopped(playerStopped: player.playerState == .stopped)
            _ = failedLoads.command()
            let cancelledWait = commandLoads.cancel()
            cancelPendingSeeks()
            // As crossfade's stop: a skip or load still waiting does not take effect.
            returnToReportedTrack(cancelledWait, at: nil)
            requested.request(false)
            player.stop()
            if let ended = ended { onLoadGaveUp(player, ended) }
        }
    }

    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        onMain {
            guard value else {
                // As pause (Android: the same command): a give-up's error stays, and a skip or
                // load still waiting ends cancelled and does not take effect.
                cancelPendingSeeks()
                returnToReportedTrack(commandLoads.cancel(), at: nil)
                player.playWhenReady = false
                requested.request(false)
                completion(.success(()))
                return
            }
            let kept = clearHostFailure()
            commandLoads.failureCleared()
            let wasIdle = idleWithoutActiveTrack
            beginIdleTrackActivationIfNeeded(wasIdle)
            if wasIdle { idleWithoutActiveTrack = false }
            // A failed seek's target is its own track's: not the active track's the play loads.
            if !loadActiveTrackAfterFailedLoad() { reloadAtKeptPosition(kept) }
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
        onMain { commandLoads.failureCleared() }
        let kept = clearHostFailure()
        let wasIdle = idleWithoutActiveTrack
        beginIdleTrackActivationIfNeeded(wasIdle)
        if wasIdle { idleWithoutActiveTrack = false }
        let jumped = loadActiveTrackAfterFailedLoad()
        // A failed seek's target is its own track's: not the active track's the retry loads.
        if jumped {
        } else if kept != nil {
            reloadAtKeptPosition(kept)
        } else {
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

/// The player the load sequences act on (StandardLoadCoordinator): one-line adapters over
/// SwiftAudioEx and the backend's callbacks. Main.
extension StandardPlaybackBackend: StandardLoadPlayer {
    var currentLoadItem: ObjectIdentifier? { return (player.currentItem as AnyObject?).map(ObjectIdentifier.init) }
    var loadStateRawValue: String { return player.playerState.rawValue }
    var loadErrorMessage: String? { return player.playbackError?.localizedDescription }
    func reloadForCommand() { player.reload(startFromCurrentTime: false) }
    func checkLoad() { loadDriver?.poke() }
    func stopLoading(log: String) {
        IOSPlaybackLog.log("standard load abandoned (\(log))")
        requested.request(false)
        player.stop()
    }
    func emitGiveUp(_ report: StandardGiveUpReport) { onLoadGaveUp(player, report) }
    func reportActiveTrack(_ change: FailedLoadRule.Report) { report(change) }
    func showAfterFailedLoad(_ reported: ObjectIdentifier?) { onLoadFailed(player, indexOfItem(reported)) }
    func logFailedLoad(active: ObjectIdentifier?) {
        IOSPlaybackLog.log("standard load failed index=\(player.currentIndex) activeIndex=\(indexOfItem(active).map(String.init) ?? "none")")
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
