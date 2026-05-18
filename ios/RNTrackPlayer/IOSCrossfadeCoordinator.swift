//
//  IOSCrossfadeCoordinator.swift
//  RNTrackPlayer
//

import AVFoundation
import Foundation

private final class IOSCrossfadeEngine {
    private let player = AVPlayer()
    private var pendingAsset: AVURLAsset?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeoutWorkItem: DispatchWorkItem?
    private var generation = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
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

    func prepare(track: Track, position: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        reset()
        generation += 1
        let currentGeneration = generation
        let asset = AVURLAsset(url: track.url.value, options: track.getAssetOptions())
        pendingAsset = asset

        asset.loadValuesAsynchronously(forKeys: ["playable"]) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration else { return }

                var assetError: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &assetError)
                guard status == .loaded, asset.isPlayable else {
                    completion(.failure(assetError ?? NSError(
                        domain: "RNTP-Crossfade",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Crossfade asset is not playable."]
                    )))
                    return
                }

                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 1
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
                                completion(.failure(error))
                            case .success:
                                self.preroll(generation: currentGeneration, completion: completion)
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
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration else { return }
                guard finished else {
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

    func play(rate: Float, completion: @escaping (Result<Void, Error>) -> Void) {
        let currentGeneration = generation
        player.playImmediately(atRate: max(rate, 0.01))
        waitForPlaying(generation: currentGeneration, completion: completion)
    }

    func pause() {
        player.pause()
    }

    func reset() {
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
    }

    private func preroll(
        generation: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        player.preroll(atRate: 1) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
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
                    finish(.success(()))
                case .failed:
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
            finish(.success(()))
            return
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == generation else { return }
                if observedPlayer.timeControlStatus == .playing {
                    finish(.success(()))
                }
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == generation else { return }
            finish(.failure(NSError(
                domain: "RNTP-Crossfade",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Crossfade engine did not start playing."]
            )))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2000), execute: timeout)
    }
}

final class IOSCrossfadeCoordinator {
    private let firstEngine = IOSCrossfadeEngine()
    private let secondEngine = IOSCrossfadeEngine()
    private var activeEngine: IOSCrossfadeEngine
    private var standbyEngine: IOSCrossfadeEngine
    private var workItems: [DispatchWorkItem] = []
    private var runId = 0
    private(set) var hasActivePlayback = false
    private(set) var isTransitioning = false
    private(set) var activeIndex: Int?
    private(set) var preparedFromIndex: Int?
    private(set) var preparedToIndex: Int?

    init() {
        activeEngine = firstEngine
        standbyEngine = secondEngine
    }

    var currentTime: Double {
        hasActivePlayback ? activeEngine.currentTime : 0
    }

    var duration: Double {
        hasActivePlayback ? activeEngine.duration : 0
    }

    var bufferedPosition: Double {
        hasActivePlayback ? activeEngine.bufferedPosition : 0
    }

    var volume: Float {
        get { hasActivePlayback ? activeEngine.volume : 0 }
        set { activeEngine.volume = newValue }
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
        cancelTransition(keepActivePlayback: hasActivePlayback)
        preparedFromIndex = fromIndex
        preparedToIndex = toIndex

        let needsOutgoingPrepare = !hasActivePlayback || activeIndex != fromIndex
        if needsOutgoingPrepare {
            hasActivePlayback = false
            activeIndex = fromIndex
        }

        prepareEngines(
            needsOutgoingPrepare: needsOutgoingPrepare,
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
        onCompleted: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float) -> Void,
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

        let startPlayback = { [weak self] in
            guard let self = self, self.runId == currentRunId else { return }
            self.activeEngine.volume = max(0, publicVolume)
            self.standbyEngine.volume = 0

            if !self.hasActivePlayback {
                self.activeEngine.seek(to: currentPublicPosition()) { [weak self] result in
                    guard let self = self, self.runId == currentRunId else { return }
                    switch result {
                    case .failure(let error):
                        self.fail(error: error, onError: onError)
                    case .success:
                        self.playBoth(
                            runId: currentRunId,
                            rate: rate,
                            fromIndex: fromIndex,
                            toIndex: toIndex,
                            durationMs: durationMs,
                            intervalMs: intervalMs,
                            targetVolume: targetVolume,
                            onStarted: onStarted,
                            onRunning: onRunning,
                            onCompleted: onCompleted,
                            onError: onError
                        )
                    }
                }
                return
            }

            self.playBoth(
                runId: currentRunId,
                rate: rate,
                fromIndex: fromIndex,
                toIndex: toIndex,
                durationMs: durationMs,
                intervalMs: intervalMs,
                targetVolume: targetVolume,
                onStarted: onStarted,
                onRunning: onRunning,
                onCompleted: onCompleted,
                onError: onError
            )
        }

        startPlayback()
    }

    func cancelTransition(keepActivePlayback: Bool) {
        runId += 1
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        isTransitioning = false
        preparedFromIndex = nil
        preparedToIndex = nil
        standbyEngine.reset()
        if !keepActivePlayback {
            activeEngine.reset()
            hasActivePlayback = false
            activeIndex = nil
        }
    }

    func reset() {
        cancelTransition(keepActivePlayback: false)
        firstEngine.reset()
        secondEngine.reset()
        activeEngine = firstEngine
        standbyEngine = secondEngine
    }

    func pause() {
        activeEngine.pause()
        standbyEngine.pause()
    }

    func play(rate: Float, completion: ((Result<Void, Error>) -> Void)? = nil) {
        activeEngine.play(rate: rate) { result in
            completion?(result)
        }
    }

    func seek(to position: Double, completion: ((Result<Void, Error>) -> Void)? = nil) {
        activeEngine.seek(to: position, completion: completion)
    }

    private func prepareEngines(
        needsOutgoingPrepare: Bool,
        outgoingTrack: Track,
        outgoingPosition: Double,
        incomingTrack: Track,
        incomingPosition: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var remaining = needsOutgoingPrepare ? 2 : 1
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

        standbyEngine.prepare(track: incomingTrack, position: incomingPosition, completion: finish)
        if needsOutgoingPrepare {
            activeEngine.prepare(track: outgoingTrack, position: outgoingPosition, completion: finish)
        }
    }

    private func playBoth(
        runId: Int,
        rate: Float,
        fromIndex: Int,
        toIndex: Int,
        durationMs: Int,
        intervalMs: Int,
        targetVolume: Float,
        onStarted: @escaping (_ fromVolume: Float, _ toVolume: Float) -> Void,
        onRunning: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float) -> Void,
        onCompleted: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float) -> Void,
        onError: @escaping (Error) -> Void
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
                self.fail(error: error, onError: onError)
                return
            }

            onStarted(self.activeEngine.volume, self.standbyEngine.volume)
            self.runRamp(
                runId: runId,
                fromIndex: fromIndex,
                toIndex: toIndex,
                durationMs: max(1, durationMs),
                intervalMs: max(10, intervalMs),
                outgoingStartVolume: self.activeEngine.volume,
                targetVolume: targetVolume,
                elapsedMs: 0,
                lastRunningEmitMs: -250,
                onRunning: onRunning,
                onCompleted: onCompleted
            )
        }

        activeEngine.play(rate: rate, completion: finish)
        standbyEngine.play(rate: rate, completion: finish)
    }

    private func runRamp(
        runId: Int,
        fromIndex: Int,
        toIndex: Int,
        durationMs: Int,
        intervalMs: Int,
        outgoingStartVolume: Float,
        targetVolume: Float,
        elapsedMs: Int,
        lastRunningEmitMs: Int,
        onRunning: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float) -> Void,
        onCompleted: @escaping (_ elapsedMs: Int, _ fromVolume: Float, _ toVolume: Float) -> Void
    ) {
        guard self.runId == runId else { return }

        let progress = min(1, max(0, Double(elapsedMs) / Double(durationMs)))
        let angle = progress * Double.pi / 2
        let fromVolume = outgoingStartVolume * Float(cos(angle))
        let toVolume = targetVolume * Float(sin(angle))
        activeEngine.volume = max(0, fromVolume)
        standbyEngine.volume = max(0, toVolume)

        let shouldEmitRunning = elapsedMs - lastRunningEmitMs >= 250 || elapsedMs >= durationMs
        if shouldEmitRunning {
            onRunning(min(elapsedMs, durationMs), activeEngine.volume, standbyEngine.volume)
        }

        if elapsedMs >= durationMs {
            activeEngine.pause()
            activeEngine.volume = 0
            standbyEngine.volume = targetVolume
            swap(&activeEngine, &standbyEngine)
            standbyEngine.reset()
            hasActivePlayback = true
            isTransitioning = false
            activeIndex = toIndex
            preparedFromIndex = nil
            preparedToIndex = nil
            workItems.removeAll()
            onCompleted(durationMs, 0, targetVolume)
            return
        }

        let nextElapsedMs = min(durationMs, elapsedMs + intervalMs)
        let nextLastRunningEmitMs = shouldEmitRunning ? elapsedMs : lastRunningEmitMs
        let next = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.runRamp(
                runId: runId,
                fromIndex: fromIndex,
                toIndex: toIndex,
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

    private func fail(error: Error, onError: @escaping (Error) -> Void) {
        cancelTransition(keepActivePlayback: hasActivePlayback)
        onError(error)
    }
}
