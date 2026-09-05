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

        asset.loadValuesAsynchronously(forKeys: ["playable"]) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration else { return }

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

                self.waitForReadyItem(item: item, generation: currentGeneration) { [weak self] result in
                    guard let self = self, self.generation == currentGeneration else { return }
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        self.seek(to: position) { [weak self] seekResult in
                            guard let self = self, self.generation == currentGeneration else { return }
                            switch seekResult {
                            case .failure(let error):
                                self.state = .failed
                                IOSPlaybackLog.log("\(self.name) seek failed during prepare error=\(error.localizedDescription)")
                                completion(.failure(error))
                            case .success:
                                self.preroll(generation: currentGeneration) { result in
                                    if case .success = result {
                                        self.state = .ready
                                        IOSPlaybackLog.log("\(self.name) prepare end duration=\(self.duration) buffered=\(self.bufferedPosition)")
                                    }
                                    completion(result)
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
        timeoutMs: Int = 5000,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let currentGeneration = generation
        IOSPlaybackLog.log("\(name) play rate=\(rate) volume=\(player.volume)")
        player.playImmediately(atRate: max(rate, 0.1))
        waitForPlaying(generation: currentGeneration, timeoutMs: timeoutMs, completion: completion)
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

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == generation else { return }
            self.state = .failed
            IOSPlaybackLog.log("\(self.name) item ready timeout")
            finish(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not become ready."]
            )))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5000), execute: timeout)
    }

    private func waitForPlaying(
        generation: Int,
        timeoutMs: Int = 5000,
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

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == generation else { return }
            self.state = .failed
            IOSPlaybackLog.log("\(self.name) playing timeout")
            finish(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not start playing."]
            )))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)
    }
}
