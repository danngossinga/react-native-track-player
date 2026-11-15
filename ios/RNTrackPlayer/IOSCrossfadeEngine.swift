//
//  IOSCrossfadeEngine.swift
//  RNTrackPlayer
//

import AVFoundation
import Foundation
import QuartzCore

#if RNTP_E2E_PROBES
enum IOSPlaybackE2EProbe {
    static func finite(_ value: Double) -> Any {
        value.isFinite ? value as Any : NSNull()
    }
}
#endif

enum IOSPlaybackLog {
    static func log(_ message: String) {
        let time = CACurrentMediaTime()
        print("[XF-ORCH][\(String(format: "%.6f", time))] \(message)")
    }
}

enum IOSCrossfadeEngineState {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed
}

final class IOSCrossfadeEngine {
#if RNTP_E2E_PROBES
    let e2eIdentity = UUID().uuidString
    private final class WeakEngine {
        weak var value: IOSCrossfadeEngine?
        init(_ value: IOSCrossfadeEngine) { self.value = value }
    }
    private static let e2eRegistryLock = NSLock()
    private static var e2eRegistry: [String: WeakEngine] = [:]

    /// Includes retained engines from former backends, not just current A/B.
    /// Copy weak entries under the registry lock; inspect AVPlayer only on main
    /// and after releasing that lock. Reading never creates or resets an engine.
    static func e2eLiveSnapshots() -> [[String: Any]] {
        precondition(Thread.isMainThread)
        e2eRegistryLock.lock()
        let engines = e2eRegistry.values.compactMap(\.value)
        e2eRegistryLock.unlock()
        return engines.sorted { $0.e2eIdentity < $1.e2eIdentity }.map { $0.e2eSnapshot() }
    }

    func e2eSnapshot() -> [String: Any] {
        precondition(Thread.isMainThread)
        let status: Any
        switch player.timeControlStatus {
        case .paused: status = "paused"
        case .waitingToPlayAtSpecifiedRate: status = "waiting"
        case .playing: status = "playing"
        @unknown default: status = NSNull()
        }
        return [
            "id": e2eIdentity,
            "generation": generation,
            "state": String(describing: state),
            "volume": IOSPlaybackE2EProbe.finite(Double(player.volume)),
            "observedRate": IOSPlaybackE2EProbe.finite(Double(player.rate)),
            "timeControlStatus": status,
            "position": IOSPlaybackE2EProbe.finite(player.currentTime().seconds),
            "duration": player.currentItem.map { IOSPlaybackE2EProbe.finite($0.duration.seconds) } ?? NSNull(),
            "currentItemPresent": player.currentItem != nil
        ]
    }
#endif
    /// How long a load may take in all, playable stage included (`prepareTimeoutMs` option,
    /// 60000 ms by default). Read at every load, so a new value applies to the next load at once.
    var prepareTimeoutMs: () -> Int = { prepareTimeoutDefaultMs }
    /// How long playback may take in all to start after `play` (`playStartTimeoutMs`, 60000 ms by
    /// default). Read at every play, so a new value from the app applies to the next one at once.
    var playStartTimeoutMs: () -> Int = { playStartTimeoutDefaultMs }
    /// How long a load or a play start may go on with no new media loaded (`stallTimeoutMs`,
    /// 10000 ms by default). Read at every load and play.
    var stallTimeoutMs: () -> Int = { stallTimeoutDefaultMs }
    private let player = AVPlayer()
    private var pendingAsset: AVURLAsset?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    /// The waits running on this engine; each wait owns its driver, a reset cancels them all.
    private var waits: [StallWaitDriver] = []
    private var generation = 0
    private let name: String
    private(set) var state: IOSCrossfadeEngineState = .idle

    init(name: String = "engine") {
        self.name = name
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        player.volume = 0
#if RNTP_E2E_PROBES
        Self.e2eRegistryLock.lock()
        Self.e2eRegistry[e2eIdentity] = WeakEngine(self)
        Self.e2eRegistryLock.unlock()
#endif
    }

#if RNTP_E2E_PROBES
    deinit {
        Self.e2eRegistryLock.lock()
        Self.e2eRegistry.removeValue(forKey: e2eIdentity)
        Self.e2eRegistryLock.unlock()
    }
#endif

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: Double {
        guard let item = player.currentItem else { return 0 }
        let seconds = item.duration.seconds
        return seconds.isFinite ? seconds : 0
    }

    var bufferedPosition: Double {
        guard let range = player.currentItem?.loadedTimeRanges.last?.timeRangeValue else {
            return currentTime
        }
        let end = range.start.seconds + range.duration.seconds
        return end.isFinite ? end : currentTime
    }

    var isReady: Bool {
        return player.currentItem?.status == .readyToPlay
    }

    var isPlaying: Bool {
        return player.timeControlStatus == .playing && player.rate > 0
    }

    var rate: Float {
        get { return player.rate }
        set {
            if player.rate > 0 {
                player.rate = max(newValue, 0.1)
            }
        }
    }

    var timeControlStatus: AVPlayer.TimeControlStatus {
        return player.timeControlStatus
    }

    func setVolume(_ volume: Float) {
        player.volume = max(0, min(1, volume))
    }

    func prepare(track: Track, position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        IOSPlaybackLog.log("\(name) prepare start title=\(track.title ?? "unknown") position=\(position)")
        reset()
        generation += 1
        state = .loading
        let currentGeneration = generation
        let asset = AVURLAsset(url: track.url.value, options: track.getAssetOptions())
        pendingAsset = asset
        // One wait for the whole load, under prepareTimeoutMs. The playable stage has no progress
        // signal (nil readings: only the limit applies); from the item on, the load also fails
        // when it loads nothing for stallTimeoutMs (the ready wait, the seek and the preroll).
        var loadItem: AVPlayerItem?
        var settled = false
        var loadWait: StallWaitDriver?
        func settle(_ result: Result<Void, Error>) {
            guard !settled else { return }
            settled = true
            if let loadWait = loadWait { self.endWait(loadWait) }
            completion(result)
        }
        let wait = startWait(
            totalTimeoutMs: prepareTimeoutMs(),
            readings: { loadItem.map(Self.loadProgress(of:)) }
        ) { [weak self] verdict, watch in
            guard let self = self, self.generation == currentGeneration, !settled else { return }
            let reason = Self.describe(verdict, watch)
            let stage = loadItem == nil ? "playable" : "ready"
            IOSPlaybackLog.log("\(self.name) prepare timeout stage=\(stage) \(reason)")
            self.pendingAsset?.cancelLoading()
            self.pendingAsset = nil
            self.itemStatusObservation?.invalidate()
            self.itemStatusObservation = nil
            loadItem?.cancelPendingSeeks()
            self.player.cancelPendingPrerolls()
            self.state = .failed
            settle(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: loadItem == nil
                    ? "Crossfade engine did not become playable (\(reason))."
                    : "Crossfade engine did not become ready (\(reason))."]
            )))
        }
        loadWait = wait

        asset.loadValuesAsynchronously(forKeys: ["playable"]) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration, !settled else { return }

                var assetError: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &assetError)
                guard status == .loaded, asset.isPlayable else {
                    self.state = .failed
                    IOSPlaybackLog.log("\(self.name) prepare failed playable status=\(status.rawValue)")
                    settle(.failure(assetError ?? NSError(
                        domain: "RNTP-Crossfade",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Crossfade asset is not playable."]
                    )))
                    return
                }

                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 6
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                self.pendingAsset = nil
                self.player.replaceCurrentItem(with: item)
                self.player.volume = 0
                loadItem = item
                wait.noteProgress()

                self.waitForReadyItem(item: item, generation: currentGeneration) { [weak self] result in
                    guard let self = self, self.generation == currentGeneration, !settled else { return }
                    switch result {
                    case .failure(let error):
                        settle(.failure(error))
                    case .success:
                        // Reaching ready is progress; the seek and preroll stay under this wait.
                        wait.noteProgress()
                        self.seek(to: position, watched: false) { [weak self] seekResult in
                            guard let self = self, self.generation == currentGeneration, !settled else { return }
                            switch seekResult {
                            case .failure(let error):
                                self.state = .failed
                                IOSPlaybackLog.log("\(self.name) seek failed during prepare error=\(error.localizedDescription)")
                                settle(.failure(error))
                            case .success:
                                self.preroll(generation: currentGeneration) { result in
                                    guard !settled else { return }
                                    if case .success = result {
                                        self.state = .ready
                                        IOSPlaybackLog.log("\(self.name) prepare end duration=\(self.duration) buffered=\(self.bufferedPosition)")
                                    }
                                    settle(result)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Seeks the current item. With a completion, the seek fails when it loads nothing for
    /// `stallTimeoutMs` or exceeds `prepareTimeoutMs` (the same limit as an Android crossfade seek);
    /// `watched: false` is for a seek already under a wait (the load's).
    func seek(to position: Double, watched: Bool = true, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let currentGeneration = generation
        let time = CMTime(seconds: max(0, position), preferredTimescale: 1000)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 1000)
        IOSPlaybackLog.log("\(name) seek to=\(max(0, position))")
        var done = false
        var seekWait: StallWaitDriver?
        func finish(_ result: Result<Void, Error>) {
            guard !done else { return }
            done = true
            if let seekWait = seekWait { endWait(seekWait) }
            completion?(result)
        }
        if watched, completion != nil {
            let item = player.currentItem
            seekWait = startWait(
                totalTimeoutMs: prepareTimeoutMs(),
                readings: { item.map(Self.loadProgress(of:)) ?? [0, 0] }
            ) { [weak self] verdict, watch in
                guard let self = self, self.generation == currentGeneration, !done else { return }
                let reason = Self.describe(verdict, watch)
                IOSPlaybackLog.log("\(self.name) seek timeout \(reason)")
                item?.cancelPendingSeeks()
                self.state = .failed
                finish(.failure(NSError(
                    domain: "RNTP-Crossfade",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Crossfade engine seek did not finish (\(reason))."]
                )))
            }
        }
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration, !done else { return }
                guard finished else {
                    self.state = .failed
                    finish(.failure(NSError(
                        domain: "RNTP-Crossfade",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Crossfade engine seek failed."]
                    )))
                    return
                }
                finish(.success(()))
            }
        }
    }

    func play(
        rate: Float,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let currentGeneration = generation
        IOSPlaybackLog.log("\(name) play rate=\(rate) volume=\(player.volume)")
        player.playImmediately(atRate: max(rate, 0.1))
        waitForPlaying(generation: currentGeneration, timeoutMs: playStartTimeoutMs(), completion: completion)
    }

    func play(rate: Float = 1) {
        IOSPlaybackLog.log("\(name) play fire-and-forget rate=\(rate) volume=\(player.volume)")
        player.playImmediately(atRate: max(rate, 0.1))
        state = .playing
    }

    func pause() {
        IOSPlaybackLog.log("\(name) pause")
        player.pause()
        if state == .playing {
            state = .paused
        }
    }

    func stop() {
        IOSPlaybackLog.log("\(name) stop")
        player.pause()
        player.seek(to: .zero)
        state = .idle
    }

    func reset() {
        IOSPlaybackLog.log("\(name) reset")
        generation += 1
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        waits.forEach { $0.cancel() }
        waits.removeAll()
        pendingAsset?.cancelLoading()
        pendingAsset = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.volume = 0
        state = .idle
    }

    private func preroll(
        generation: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        player.preroll(atRate: 1) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                IOSPlaybackLog.log("\(self.name) preroll complete")
                completion(.success(()))
            }
        }
    }

    /// Waits for the item's status (no limit of its own: the load's wait bounds it).
    private func waitForReadyItem(
        item: AVPlayerItem,
        generation: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false

        func finish(_ result: Result<Void, Error>) {
            guard !didComplete else { return }
            didComplete = true
            self.itemStatusObservation?.invalidate()
            self.itemStatusObservation = nil
            completion(result)
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.state = .ready
                    IOSPlaybackLog.log("\(self.name) item ready")
                    finish(.success(()))
                case .failed:
                    self.state = .failed
                    IOSPlaybackLog.log("\(self.name) item failed error=\(observedItem.error?.localizedDescription ?? "unknown")")
                    finish(.failure(observedItem.error ?? NSError(
                        domain: "RNTP-Crossfade",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Crossfade engine item failed."]
                    )))
                default:
                    break
                }
            }
        }
    }

    private func waitForPlaying(
        generation: Int,
        timeoutMs: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false
        var playWait: StallWaitDriver?

        func finish(_ result: Result<Void, Error>) {
            guard !didComplete else { return }
            didComplete = true
            self.timeControlObservation?.invalidate()
            self.timeControlObservation = nil
            if let playWait = playWait { self.endWait(playWait) }
            completion(result)
        }

        if player.timeControlStatus == .playing {
            state = .playing
            finish(.success(()))
            return
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                if observedPlayer.timeControlStatus == .playing {
                    self.state = .playing
                    IOSPlaybackLog.log("\(self.name) playing")
                    finish(.success(()))
                }
            }
        }

        // Waiting to play while media keeps loading (or time advancing) is progress.
        playWait = startWait(
            totalTimeoutMs: timeoutMs,
            readings: { [weak self] in
                guard let self = self else { return nil }
                return (self.player.currentItem.map(Self.loadProgress(of:)) ?? [0, 0]) + [self.currentTime]
            }
        ) { [weak self] verdict, watch in
            guard let self = self, self.generation == generation, !didComplete else { return }
            self.state = .failed
            IOSPlaybackLog.log("\(self.name) playing timeout \(Self.describe(verdict, watch)) status=\(self.player.timeControlStatus.rawValue) waitingReason=\(self.player.reasonForWaitingToPlay?.rawValue ?? "none") itemError=\(self.player.currentItem?.error?.localizedDescription ?? "none")")
            finish(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not start playing (\(Self.describe(verdict, watch)))."]
            )))
        }
    }

    /// Starts a wait under `stallTimeoutMs` and `totalTimeoutMs`, owned by this engine until it
    /// ends or a reset cancels it.
    private func startWait(
        totalTimeoutMs: Int,
        readings: @escaping () -> [Double]?,
        onGiveUp: @escaping (StallVerdict, StallWatch) -> Void
    ) -> StallWaitDriver {
        weak var driver: StallWaitDriver?
        let created = StallWaitDriver(
            stallTimeoutMs: stallTimeoutMs(),
            totalTimeoutMs: totalTimeoutMs,
            readings: readings
        ) { [weak self] verdict, watch in
            if let self = self, let driver = driver { self.endWait(driver) }
            onGiveUp(verdict, watch)
        }
        driver = created
        waits.append(created)
        created.start()
        return created
    }

    private func endWait(_ driver: StallWaitDriver) {
        driver.cancel()
        waits.removeAll { $0 === driver }
    }

    /// The progress of a load or of a start that waits: the seconds of media the item has loaded,
    /// and the bytes its access log reports downloaded (which grow while a first segment arrives,
    /// before any loaded time range exists).
    private static func loadProgress(of item: AVPlayerItem) -> [Double] {
        let loadedSeconds = item.loadedTimeRanges.reduce(0.0) { total, value in
            let seconds = value.timeRangeValue.duration.seconds
            return seconds.isFinite ? total + seconds : total
        }
        let bytes = item.accessLog()?.events.reduce(0.0) { total, event in
            total + Double(max(0, event.numberOfBytesTransferred))
        } ?? 0
        return [loadedSeconds, bytes]
    }

    private static func describe(_ verdict: StallVerdict, _ watch: StallWatch) -> String {
        return verdict == .stalled
            ? "no progress for \(watch.stallTimeoutMs) ms"
            : "over the \(watch.totalTimeoutMs) ms limit"
    }
}
