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
    private var timeoutWorkItem: DispatchWorkItem?
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
        // One watch for the whole load: the playable stage has no progress signal, so only the
        // total limit bounds it; the wait for a ready item also fails when it stalls.
        let loadWatch = StallWatch(
            stallTimeoutMs: stallTimeoutMs(),
            totalTimeoutMs: prepareTimeoutMs(),
            startedAt: Self.now()
        )
        var playableSettled = false
        scheduleWaitCheck(generation: currentGeneration) { [weak self] in
            guard let self = self, !playableSettled else { return false }
            guard loadWatch.capVerdict(at: Self.now()) == .capExceeded else { return true }
            playableSettled = true
            self.pendingAsset?.cancelLoading()
            self.pendingAsset = nil
            self.state = .failed
            IOSPlaybackLog.log("\(self.name) playable timeout limitMs=\(loadWatch.totalTimeoutMs)")
            completion(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not become playable within \(loadWatch.totalTimeoutMs) ms."]
            )))
            return false
        }

        asset.loadValuesAsynchronously(forKeys: ["playable"]) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration, !playableSettled else { return }
                playableSettled = true
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil

                var assetError: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &assetError)
                guard status == .loaded, asset.isPlayable else {
                    self.state = .failed
                    IOSPlaybackLog.log("\(self.name) prepare failed playable status=\(status.rawValue)")
                    completion(.failure(assetError ?? NSError(
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

                var readyWatch = loadWatch
                readyWatch.noteProgress(at: Self.now())
                self.waitForReadyItem(item: item, generation: currentGeneration, watch: readyWatch) { [weak self] result in
                    guard let self = self, self.generation == currentGeneration else { return }
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        // The seek to the start position and the preroll stay under the same
                        // watch: no progress for stallTimeoutMs, or the load limit, ends the load.
                        var settleWatch = loadWatch
                        settleWatch.noteProgress(at: Self.now())
                        var settled = false
                        func settle(_ result: Result<Void, Error>) {
                            guard !settled else { return }
                            settled = true
                            self.timeoutWorkItem?.cancel()
                            self.timeoutWorkItem = nil
                            completion(result)
                        }
                        self.scheduleWaitCheck(generation: currentGeneration) { [weak self] in
                            guard let self = self, !settled else { return false }
                            let verdict = settleWatch.check(at: Self.now(), readings: Self.loadProgress(of: item))
                            guard verdict != .wait else { return true }
                            self.state = .failed
                            let reason = Self.describe(verdict, settleWatch)
                            IOSPlaybackLog.log("\(self.name) prepare seek/preroll timeout \(reason)")
                            item.cancelPendingSeeks()
                            self.player.cancelPendingPrerolls()
                            settle(.failure(NSError(
                                domain: "RNTP-Crossfade",
                                code: 5,
                                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not become ready (\(reason))."]
                            )))
                            return false
                        }
                        self.seek(to: position) { [weak self] seekResult in
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

    func seek(to position: Double, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let currentGeneration = generation
        let time = CMTime(seconds: max(0, position), preferredTimescale: 1000)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 1000)
        IOSPlaybackLog.log("\(name) seek to=\(max(0, position))")
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration else { return }
                guard finished else {
                    self.state = .failed
                    completion?(.failure(NSError(
                        domain: "RNTP-Crossfade",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Crossfade engine seek failed."]
                    )))
                    return
                }
                completion?(.success(()))
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
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
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

    private func waitForReadyItem(
        item: AVPlayerItem,
        generation: Int,
        watch: StallWatch,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false

        func finish(_ result: Result<Void, Error>) {
            guard !didComplete else { return }
            didComplete = true
            self.itemStatusObservation?.invalidate()
            self.itemStatusObservation = nil
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
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

        var watch = watch
        scheduleWaitCheck(generation: generation) { [weak self] in
            guard let self = self, !didComplete else { return false }
            let verdict = watch.check(at: Self.now(), readings: Self.loadProgress(of: item))
            guard verdict != .wait else { return true }
            self.state = .failed
            let reason = Self.describe(verdict, watch)
            IOSPlaybackLog.log("\(self.name) item ready timeout \(reason)")
            finish(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not become ready (\(reason))."]
            )))
            return false
        }
    }

    private func waitForPlaying(
        generation: Int,
        timeoutMs: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var didComplete = false

        func finish(_ result: Result<Void, Error>) {
            guard !didComplete else { return }
            didComplete = true
            self.timeControlObservation?.invalidate()
            self.timeControlObservation = nil
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
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
        var watch = StallWatch(stallTimeoutMs: stallTimeoutMs(), totalTimeoutMs: timeoutMs, startedAt: Self.now())
        scheduleWaitCheck(generation: generation) { [weak self] in
            guard let self = self, !didComplete else { return false }
            let verdict = watch.check(
                at: Self.now(),
                readings: (self.player.currentItem.map(Self.loadProgress(of:)) ?? [0, 0]) + [self.currentTime]
            )
            guard verdict != .wait else { return true }
            self.state = .failed
            IOSPlaybackLog.log("\(self.name) playing timeout \(Self.describe(verdict, watch)) status=\(self.player.timeControlStatus.rawValue) waitingReason=\(self.player.reasonForWaitingToPlay?.rawValue ?? "none") itemError=\(self.player.currentItem?.error?.localizedDescription ?? "none")")
            finish(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not start playing (\(Self.describe(verdict, watch)))."]
            )))
            return false
        }
    }

    /// Runs `check` every `stallCheckIntervalMs` on main while it returns true, for the current
    /// load or play only (a reset or a new operation cancels it).
    private func scheduleWaitCheck(generation: Int, _ check: @escaping () -> Bool) {
        let tick = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == generation else { return }
            if check() {
                self.scheduleWaitCheck(generation: generation, check)
            }
        }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stallCheckIntervalMs), execute: tick)
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

    private static func now() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    private static func describe(_ verdict: StallVerdict, _ watch: StallWatch) -> String {
        return verdict == .stalled
            ? "no progress for \(watch.stallTimeoutMs) ms"
            : "over the \(watch.totalTimeoutMs) ms limit"
    }
}
