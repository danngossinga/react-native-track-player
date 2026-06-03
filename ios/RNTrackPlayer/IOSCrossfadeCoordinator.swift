//
//  IOSCrossfadeCoordinator.swift
//  RNTrackPlayer
//

import AVFoundation
import Foundation
import QuartzCore

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
    }

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

final class IOSCrossfadeCoordinator {
    private let outgoingEngine = IOSCrossfadeEngine(name: "legacyOutgoing")
    private let incomingEngine = IOSCrossfadeEngine(name: "legacyIncoming")
    private var workItems: [DispatchWorkItem] = []
    private var runId = 0
    private(set) var isTransitioning = false
    private(set) var preparedFromIndex: Int?
    private(set) var preparedToIndex: Int?

    var incomingCurrentTime: Double {
        return incomingEngine.currentTime
    }

    private func xfadeLog(_ message: String) {
        IOSPlaybackLog.log("legacy \(message)")
    }

    func prepare(
        outgoingTrack: Track,
        outgoingPosition: Double,
        fromIndex: Int,
        incomingTrack: Track,
        incomingPosition: Double,
        toIndex: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        cancelTransition(keepActivePlayback: false)
        preparedFromIndex = fromIndex
        preparedToIndex = toIndex
        prepareEngines(
            outgoingTrack: outgoingTrack,
            outgoingPosition: outgoingPosition,
            incomingTrack: incomingTrack,
            incomingPosition: incomingPosition,
            completion: completion
        )
    }

    func start(
        fromIndex: Int,
        toIndex: Int,
        durationMs: Int,
        intervalMs: Int,
        targetVolume: Float,
        rate: Float,
        publicVolume: Float,
        currentPublicPosition: @escaping () -> Double,
        onStarted: @escaping (_ fromVolume: Float, _ toVolume: Float) -> Void,
        onRunning: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float) -> Void,
        onCompleted: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float, _ incomingPosition: Double) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard preparedFromIndex == fromIndex, preparedToIndex == toIndex else {
            onError(NSError(
                domain: "RNTP-Crossfade",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade target was not prepared."]
            ))
            return
        }

        runId += 1
        let currentRunId = runId
        isTransitioning = true

        xfadeLog("start: before outgoing seek")
        outgoingEngine.seek(to: currentPublicPosition()) { [weak self] result in
            guard let self = self, self.runId == currentRunId else { return }
            switch result {
            case .failure(let error):
                self.fail(error: error, onError: onError)
            case .success:
                self.xfadeLog("start: after outgoing seek")
                self.outgoingEngine.volume = max(0, publicVolume)
                self.incomingEngine.volume = 0
                self.playBoth(runId: currentRunId, rate: rate) { [weak self] playResult in
                    guard let self = self, self.runId == currentRunId else { return }
                    switch playResult {
                    case .failure(let error):
                        self.fail(error: error, onError: onError)
                    case .success:
                        self.xfadeLog("playBoth: completed")
                        onStarted(self.outgoingEngine.volume, self.incomingEngine.volume)
                        self.runRamp(
                            runId: currentRunId,
                            durationMs: max(1, durationMs),
                            intervalMs: max(10, intervalMs),
                            outgoingStartVolume: self.outgoingEngine.volume,
                            targetVolume: targetVolume,
                            elapsedMs: 0,
                            lastRunningEmitMs: -250,
                            onRunning: onRunning,
                            onCompleted: onCompleted
                        )
                    }
                }
            }
        }
    }

    func cancelTransition(keepActivePlayback: Bool) {
        runId += 1
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        isTransitioning = false
        preparedFromIndex = nil
        preparedToIndex = nil
        outgoingEngine.reset()
        incomingEngine.reset()
    }

    func reset() {
        cancelTransition(keepActivePlayback: false)
    }

    func pause() {
        outgoingEngine.pause()
        incomingEngine.pause()
    }

    func handbackToPublicPlayer(
        durationMs: Int,
        targetVolume: Float,
        setPublicVolume: @escaping (Float) -> Void,
        completion: @escaping () -> Void
    ) {
        let currentRunId = runId
        let durationMs = max(1, durationMs)
        isTransitioning = true
        xfadeLog("handback: start")
        runHandbackRamp(
            runId: currentRunId,
            durationMs: durationMs,
            targetVolume: targetVolume,
            elapsedMs: 0,
            setPublicVolume: setPublicVolume,
            completion: completion
        )
    }

    private func prepareEngines(
        outgoingTrack: Track,
        outgoingPosition: Double,
        incomingTrack: Track,
        incomingPosition: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var remaining = 2
        var firstError: Error?

        func finish(_ result: Result<Void, Error>) {
            switch result {
            case .failure(let error):
                if firstError == nil {
                    firstError = error
                }
            case .success:
                break
            }

            remaining -= 1
            guard remaining == 0 else { return }
            if let error = firstError {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }

        outgoingEngine.prepare(track: outgoingTrack, position: outgoingPosition, completion: finish)
        incomingEngine.prepare(track: incomingTrack, position: incomingPosition, completion: finish)
    }

    private func playBoth(
        runId: Int,
        rate: Float,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var remaining = 2
        var firstError: Error?

        func finish(_ result: Result<Void, Error>) {
            switch result {
            case .failure(let error):
                if firstError == nil {
                    firstError = error
                }
            case .success:
                break
            }

            remaining -= 1
            guard remaining == 0 else { return }
            completion(firstError.map { .failure($0) } ?? .success(()))
        }

        outgoingEngine.play(rate: rate, completion: finish)
        incomingEngine.play(rate: rate, completion: finish)
    }

    private func runRamp(
        runId: Int,
        durationMs: Int,
        intervalMs: Int,
        outgoingStartVolume: Float,
        targetVolume: Float,
        elapsedMs: Int,
        lastRunningEmitMs: Int,
        onRunning: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float) -> Void,
        onCompleted: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float, _ incomingPosition: Double) -> Void
    ) {
        guard self.runId == runId else { return }

        let progress = min(1, max(0, Double(elapsedMs) / Double(durationMs)))
        let angle = progress * Double.pi / 2
        let fromVolume = outgoingStartVolume * Float(cos(angle))
        let toVolume = targetVolume * Float(sin(angle))
        outgoingEngine.volume = max(0, fromVolume)
        incomingEngine.volume = max(0, toVolume)

        let shouldEmitRunning = elapsedMs - lastRunningEmitMs >= 250 || elapsedMs >= durationMs
        if shouldEmitRunning {
            onRunning(min(elapsedMs, durationMs), outgoingEngine.volume, incomingEngine.volume)
        }

        if elapsedMs >= durationMs {
            xfadeLog("ramp: completed, incomingPosition=\(incomingEngine.currentTime)")
            outgoingEngine.pause()
            outgoingEngine.volume = 0
            outgoingEngine.reset()
            incomingEngine.volume = targetVolume
            isTransitioning = false
            preparedFromIndex = nil
            preparedToIndex = nil
            workItems.removeAll()
            onCompleted(durationMs, 0, targetVolume, incomingEngine.currentTime)
            return
        }

        let nextElapsedMs = min(durationMs, elapsedMs + intervalMs)
        let nextLastRunningEmitMs = shouldEmitRunning ? elapsedMs : lastRunningEmitMs
        let next = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.runRamp(
                runId: runId,
                durationMs: durationMs,
                intervalMs: intervalMs,
                outgoingStartVolume: outgoingStartVolume,
                targetVolume: targetVolume,
                elapsedMs: nextElapsedMs,
                lastRunningEmitMs: nextLastRunningEmitMs,
                onRunning: onRunning,
                onCompleted: onCompleted
            )
        }
        workItems.append(next)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(intervalMs), execute: next)
    }

    private func runHandbackRamp(
        runId: Int,
        durationMs: Int,
        targetVolume: Float,
        elapsedMs: Int,
        setPublicVolume: @escaping (Float) -> Void,
        completion: @escaping () -> Void
    ) {
        guard self.runId == runId else { return }

        let progress = min(1, max(0, Double(elapsedMs) / Double(durationMs)))
        let angle = progress * Double.pi / 2
        let publicVolume = targetVolume * Float(sin(angle))
        let incomingVolume = targetVolume * Float(cos(angle))

        setPublicVolume(max(0, publicVolume))
        incomingEngine.volume = max(0, incomingVolume)

        if elapsedMs >= durationMs {
            incomingEngine.pause()
            incomingEngine.volume = 0
            incomingEngine.reset()
            setPublicVolume(targetVolume)
            isTransitioning = false
            preparedFromIndex = nil
            preparedToIndex = nil
            workItems.removeAll()
            xfadeLog("handback: completed")
            completion()
            return
        }

        let nextElapsedMs = min(durationMs, elapsedMs + 16)
        let next = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.runHandbackRamp(
                runId: runId,
                durationMs: durationMs,
                targetVolume: targetVolume,
                elapsedMs: nextElapsedMs,
                setPublicVolume: setPublicVolume,
                completion: completion
            )
        }
        workItems.append(next)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: next)
    }

    private func fail(error: Error, onError: @escaping (Error) -> Void) {
        cancelTransition(keepActivePlayback: false)
        onError(error)
    }
}
