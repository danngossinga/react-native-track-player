//
//  IOSPlaybackOrchestrator.swift
//  RNTrackPlayer
//

import Foundation
import QuartzCore

enum IOSPlaybackOrchestratorState {
    case idle
    case loading
    case playingSingle
    case preloadingNext
    case crossfading
    case paused
    case pausedDuringCrossfade
    case seeking
    case skipping
    case ended
    case error
}

protocol IOSPlaybackOrchestratorDelegate: AnyObject {
    func playbackOrchestrator(_ orchestrator: IOSPlaybackOrchestrator, didChangeState state: State)
    func playbackOrchestrator(
        _ orchestrator: IOSPlaybackOrchestrator,
        didChangeActiveTrack index: Int?,
        lastIndex: Int?,
        lastPosition: Double
    )
    func playbackOrchestrator(_ orchestrator: IOSPlaybackOrchestrator, didEndQueueAt index: Int, position: Double)
    func playbackOrchestrator(
        _ orchestrator: IOSPlaybackOrchestrator,
        didEmitCrossfadeState state: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int?,
        fromVolume: Float?,
        toVolume: Float?,
        errorCode: String?
    )
    func playbackOrchestratorDidUpdateNowPlaying(_ orchestrator: IOSPlaybackOrchestrator)
}

private final class IOSCrossfadeContext {
    let runId: Int
    let fromIndex: Int
    let toIndex: Int
    let durationMs: Int
    let intervalMs: Int
    let targetVolume: Float
    let outgoingStartVolume: Float
    let incomingStartTime: Double
    var elapsedMs: Int
    var lastRunningEmitMs: Int

    init(
        runId: Int,
        fromIndex: Int,
        toIndex: Int,
        durationMs: Int,
        intervalMs: Int,
        targetVolume: Float,
        outgoingStartVolume: Float,
        incomingStartTime: Double
    ) {
        self.runId = runId
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        self.durationMs = durationMs
        self.intervalMs = intervalMs
        self.targetVolume = targetVolume
        self.outgoingStartVolume = outgoingStartVolume
        self.incomingStartTime = incomingStartTime
        self.elapsedMs = 0
        self.lastRunningEmitMs = -250
    }
}

final class IOSPlaybackOrchestrator {
    weak var delegate: IOSPlaybackOrchestratorDelegate?

    private let engineA = IOSCrossfadeEngine(name: "engineA")
    private let engineB = IOSCrossfadeEngine(name: "engineB")
    private var activeEngine: IOSCrossfadeEngine
    private var standbyEngine: IOSCrossfadeEngine
    private var queue: [Track] = []
    private var runId = 0
    private var crossfadeContext: IOSCrossfadeContext?
    private var crossfadeWorkItem: DispatchWorkItem?
    private var scheduledStartWorkItem: DispatchWorkItem?
    private var endObserverWorkItem: DispatchWorkItem?
    private var preparedFromIndex: Int?
    private var preparedToIndex: Int?
    private var preparedSeekTo: Double = 0
    private var activeEngineIndex: Int?
    private var standbyEngineIndex: Int?
    private var lastKnownState: State = .none
    private(set) var state: IOSPlaybackOrchestratorState = .idle
    private(set) var currentIndex: Int = -1
    private(set) var playWhenReady: Bool = false
    private(set) var volume: Float = 1
    private(set) var rate: Float = 1

    init() {
        activeEngine = engineA
        standbyEngine = engineB
    }

    var hasCurrentItem: Bool {
        return currentIndex >= 0 && currentIndex < queue.count
    }

    var currentTrack: Track? {
        guard hasCurrentItem else { return nil }
        return queue[currentIndex]
    }

    var currentTime: Double {
        return logicalEngine.currentTime
    }

    var duration: Double {
        if logicalEngine.duration > 0 {
            return logicalEngine.duration
        }
        return currentTrack?.duration ?? 0
    }

    var bufferedPosition: Double {
        return logicalEngine.bufferedPosition
    }

    var playbackState: State {
        switch state {
        case .idle:
            return .none
        case .loading, .seeking, .skipping:
            return .loading
        case .preloadingNext:
            return playWhenReady ? .playing : .paused
        case .playingSingle, .crossfading:
            return .playing
        case .paused, .pausedDuringCrossfade:
            return .paused
        case .ended:
            return .ended
        case .error:
            return .error
        }
    }

    private var logicalEngine: IOSCrossfadeEngine {
        switch state {
        case .crossfading, .pausedDuringCrossfade:
            return standbyEngine
        default:
            return activeEngine
        }
    }

    func setQueue(_ tracks: [Track]) {
        let currentTrack = self.currentTrack
        queue = tracks
        if let currentTrack = currentTrack,
           let newIndex = tracks.firstIndex(where: { $0 === currentTrack }) {
            currentIndex = newIndex
            activeEngineIndex = newIndex
            standbyEngineIndex = nextIndex(after: newIndex)
        } else if !tracks.indices.contains(currentIndex) {
            resetEngines()
            currentIndex = -1
        }
        IOSPlaybackLog.log("queue sync count=\(tracks.count) currentIndex=\(currentIndex)")
        refreshNowPlaying()
    }

    func replaceQueue(_ tracks: [Track], currentIndex: Int = -1) {
        cancelAllWork()
        resetEngines()
        queue = tracks
        self.currentIndex = tracks.indices.contains(currentIndex) ? currentIndex : -1
        activeEngineIndex = self.currentIndex >= 0 ? self.currentIndex : nil
        standbyEngineIndex = nil
        state = self.currentIndex >= 0 ? .paused : .idle
        emitStateIfNeeded()
        refreshNowPlaying()
    }

    func load(track: Track, completion: @escaping (Result<Int, Error>) -> Void) {
        replaceQueue([track], currentIndex: -1)
        loadIndex(0, position: 0, autoPlay: false) { result in
            switch result {
            case .success:
                completion(.success(0))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func play(completion: ((Result<Void, Error>) -> Void)? = nil) {
        playWhenReady = true
        IOSPlaybackLog.log("play state=\(state) currentIndex=\(currentIndex)")

        switch state {
        case .pausedDuringCrossfade:
            state = .crossfading
            activeEngine.play(rate: rate)
            standbyEngine.play(rate: rate)
            emitStateIfNeeded()
            resumeCrossfadeRamp()
            completion?(.success(()))
        case .paused:
            activeEngine.setVolume(volume)
            activeEngine.play(rate: rate)
            state = .playingSingle
            emitStateIfNeeded()
            scheduleEndObserver()
            completion?(.success(()))
        case .idle, .ended:
            let indexToPlay = queue.indices.contains(currentIndex) ? currentIndex : 0
            guard queue.indices.contains(indexToPlay) else {
                completion?(.failure(makeError("empty_queue", "No track is available to play.")))
                return
            }
            loadIndex(indexToPlay, position: 0, autoPlay: true, completion: completion)
        case .loading, .seeking, .skipping, .preloadingNext:
            completion?(.success(()))
        case .playingSingle, .crossfading:
            completion?(.success(()))
        case .error:
            completion?(.failure(makeError("player_error", "The orchestrator is in an error state.")))
        }
        refreshNowPlaying()
    }

    func pause() {
        IOSPlaybackLog.log("pause state=\(state)")
        playWhenReady = false
        switch state {
        case .crossfading:
            crossfadeWorkItem?.cancel()
            crossfadeWorkItem = nil
            activeEngine.pause()
            standbyEngine.pause()
            state = .pausedDuringCrossfade
        default:
            activeEngine.pause()
            standbyEngine.pause()
            state = hasCurrentItem ? .paused : .idle
        }
        emitStateIfNeeded()
        refreshNowPlaying()
    }

    func stop() {
        IOSPlaybackLog.log("stop")
        playWhenReady = false
        emitCrossfadeCancellationIfNeeded(errorCode: "stop")
        cancelAllWork()
        resetEngines()
        currentIndex = -1
        state = .idle
        emitStateIfNeeded()
        refreshNowPlaying()
    }

    func setPlayWhenReady(_ value: Bool, completion: ((Result<Void, Error>) -> Void)? = nil) {
        if value {
            play(completion: completion)
        } else {
            pause()
            completion?(.success(()))
        }
    }

    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        if state == .crossfading, let context = crossfadeContext {
            let progress = min(1, max(0, Double(context.elapsedMs) / Double(context.durationMs)))
            let angle = progress * Double.pi / 2
            activeEngine.setVolume(context.outgoingStartVolume * Float(cos(angle)))
            standbyEngine.setVolume(volume * Float(sin(angle)))
        } else {
            activeEngine.setVolume(volume)
        }
        IOSPlaybackLog.log("setVolume volume=\(volume)")
    }

    func setRate(_ value: Float) {
        rate = value.isFinite && value > 0.01 ? value : 1
        activeEngine.rate = rate
        standbyEngine.rate = rate
        IOSPlaybackLog.log("setRate rate=\(rate)")
        refreshNowPlaying()
    }

    func seek(to position: Double, completion: ((Result<Void, Error>) -> Void)? = nil) {
        IOSPlaybackLog.log("seek to=\(position) state=\(state)")
        if state == .crossfading || state == .pausedDuringCrossfade {
            promoteLogicalEngineAfterCrossfadeCancellation(errorCode: "seek")
        }

        state = .seeking
        emitStateIfNeeded()
        activeEngine.seek(to: position) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.state = self.playWhenReady ? .playingSingle : .paused
                if self.playWhenReady {
                    self.activeEngine.play(rate: self.rate)
                    self.scheduleEndObserver()
                }
                self.emitStateIfNeeded()
                self.refreshNowPlaying()
                completion?(.success(()))
            case .failure(let error):
                self.state = .error
                self.emitStateIfNeeded()
                completion?(.failure(error))
            }
        }
    }

    func seek(by offset: Double, completion: ((Result<Void, Error>) -> Void)? = nil) {
        seek(to: max(0, currentTime + offset), completion: completion)
    }

    func skip(to index: Int, initialTime: Double = -1, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard queue.indices.contains(index) else {
            completion?(.failure(makeError("index_out_of_bounds", "The track index is out of bounds.")))
            return
        }
        IOSPlaybackLog.log("skip to=\(index) initialTime=\(initialTime)")
        let wasPlaying = playWhenReady
        emitCrossfadeCancellationIfNeeded(errorCode: "skip")
        cancelAllWork()
        state = .skipping
        emitStateIfNeeded()
        loadIndex(index, position: max(0, initialTime), autoPlay: wasPlaying, completion: completion)
    }

    func skipToNext(initialTime: Double = -1, completion: ((Result<Void, Error>) -> Void)? = nil) {
        skip(to: currentIndex + 1, initialTime: initialTime, completion: completion)
    }

    func skipToPrevious(initialTime: Double = -1, completion: ((Result<Void, Error>) -> Void)? = nil) {
        if currentTime > 3 {
            seek(to: 0, completion: completion)
            return
        }
        skip(to: currentIndex - 1, initialTime: initialTime, completion: completion)
    }

    func prepareCrossfade(
        previous: Bool,
        seekTo: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let fromIndex = currentIndex
        let toIndex = previous ? fromIndex - 1 : fromIndex + 1
        guard state != .crossfading && state != .pausedDuringCrossfade else {
            emitCrossfadeState("error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "crossfade_in_progress")
            completion(.failure(makeError("crossfade_in_progress", "A crossfade is already in progress.")))
            return
        }
        guard canCrossfade(fromIndex: fromIndex, toIndex: toIndex, durationMs: 1) else {
            emitCrossfadeState("error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "crossfade_target_unavailable")
            completion(.failure(makeError("crossfade_target_unavailable", "No crossfade target track is available.")))
            return
        }

        prepareStandby(index: toIndex, position: max(0, seekTo)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.preparedFromIndex = fromIndex
                self.preparedToIndex = toIndex
                self.preparedSeekTo = max(0, seekTo)
                self.emitCrossfadeState(
                    "prepared",
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    elapsedMs: 0,
                    fromVolume: self.volume,
                    toVolume: 0,
                    errorCode: nil
                )
                completion(.success(()))
            case .failure(let error):
                self.emitCrossfadeState("error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "prepare_failed")
                completion(.failure(error))
            }
        }
    }

    func crossFade(
        fadeDuration: Double,
        fadeInterval: Double,
        fadeToVolume: Double,
        waitUntil: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let fromIndex = currentIndex
        let toIndex = preparedFromIndex == fromIndex && preparedToIndex != nil
            ? preparedToIndex!
            : fromIndex + 1
        let durationMs = max(1, Int(fadeDuration))
        guard canCrossfade(fromIndex: fromIndex, toIndex: toIndex, durationMs: durationMs) else {
            emitCrossfadeState("error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "crossfade_unavailable")
            completion(.failure(makeError("crossfade_unavailable", "Crossfade is not available for this transition.")))
            return
        }

        runId += 1
        let currentRunId = runId
        let intervalMs = max(10, Int(fadeInterval))
        let targetVolume = Float(max(0, min(1, fadeToVolume)))
        emitCrossfadeState(
            "scheduled",
            fromIndex: fromIndex,
            toIndex: toIndex,
            elapsedMs: 0,
            fromVolume: activeEngine.volume,
            toVolume: 0,
            errorCode: nil
        )

        func scheduleStartCheck() {
            guard self.runId == currentRunId else { return }
            let remainingMs = Int(waitUntil - self.currentTime * 1000)
            if remainingMs <= 0 {
                self.startCrossfade(
                    runId: currentRunId,
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    durationMs: durationMs,
                    intervalMs: intervalMs,
                    targetVolume: targetVolume,
                    completion: completion
                )
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                guard self != nil else { return }
                scheduleStartCheck()
            }
            self.scheduledStartWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(max(50, min(250, remainingMs))),
                execute: workItem
            )
        }

        scheduleStartCheck()
    }

    private func loadIndex(
        _ index: Int,
        position: Double,
        autoPlay: Bool,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        guard queue.indices.contains(index) else {
            completion?(.failure(makeError("index_out_of_bounds", "The track index is out of bounds.")))
            return
        }

        runId += 1
        let currentRunId = runId
        let lastIndex = currentIndex >= 0 ? currentIndex : nil
        let lastPosition = currentTime
        let track = queue[index]
        state = .loading
        emitStateIfNeeded()
        resetEngines()
        activeEngineIndex = index
        activeEngine.setVolume(autoPlay ? volume : 0)

        activeEngine.prepare(track: track, position: position) { [weak self] result in
            guard let self = self, self.runId == currentRunId else { return }
            switch result {
            case .success:
                self.currentIndex = index
                self.delegate?.playbackOrchestrator(
                    self,
                    didChangeActiveTrack: index,
                    lastIndex: lastIndex,
                    lastPosition: lastPosition
                )
                if autoPlay {
                    self.playWhenReady = true
                    self.activeEngine.setVolume(self.volume)
                    self.activeEngine.play(rate: self.rate)
                    self.state = .playingSingle
                    self.scheduleEndObserver()
                    self.preloadNextIfPossible()
                } else {
                    self.playWhenReady = false
                    self.state = .paused
                    self.activeEngine.setVolume(self.volume)
                }
                self.emitStateIfNeeded()
                self.refreshNowPlaying()
                completion?(.success(()))
            case .failure(let error):
                self.state = .error
                self.emitStateIfNeeded()
                completion?(.failure(error))
            }
        }
    }

    private func startCrossfade(
        runId: Int,
        fromIndex: Int,
        toIndex: Int,
        durationMs: Int,
        intervalMs: Int,
        targetVolume: Float,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard self.runId == runId else { return }

        let startPreparedStandby = { [weak self] in
            guard let self = self, self.runId == runId else { return }
            IOSPlaybackLog.log("crossfade start from=\(fromIndex) to=\(toIndex)")
            let outgoingStartVolume = self.activeEngine.volume > 0 ? self.activeEngine.volume : self.volume
            self.activeEngine.setVolume(outgoingStartVolume)
            self.standbyEngine.setVolume(0)
            self.standbyEngine.play(rate: self.rate) { [weak self] result in
                guard let self = self, self.runId == runId else { return }
                switch result {
                case .success:
                    let lastPosition = self.activeEngine.currentTime
                    self.currentIndex = toIndex
                    self.state = .crossfading
                    self.delegate?.playbackOrchestrator(
                        self,
                        didChangeActiveTrack: toIndex,
                        lastIndex: fromIndex,
                        lastPosition: lastPosition
                    )
                    self.refreshNowPlaying()
                    self.emitStateIfNeeded()
                    self.emitCrossfadeState(
                        "started",
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        elapsedMs: 0,
                        fromVolume: self.activeEngine.volume,
                        toVolume: self.standbyEngine.volume,
                        errorCode: nil
                    )
                    let context = IOSCrossfadeContext(
                        runId: runId,
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        durationMs: durationMs,
                        intervalMs: intervalMs,
                        targetVolume: targetVolume,
                        outgoingStartVolume: outgoingStartVolume,
                        incomingStartTime: self.standbyEngine.currentTime
                    )
                    self.crossfadeContext = context
                    self.runCrossfadeRamp(context: context, completion: completion)
                case .failure(let error):
                    self.emitCrossfadeState("error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "crossfade_start_failed")
                    completion(.failure(error))
                }
            }
        }

        if standbyEngineIndex == toIndex && standbyEngine.isReady {
            startPreparedStandby()
            return
        }

        prepareStandby(index: toIndex, position: preparedFromIndex == fromIndex ? preparedSeekTo : 0) { result in
            switch result {
            case .success:
                startPreparedStandby()
            case .failure(let error):
                self.emitCrossfadeState("error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "prepare_failed")
                completion(.failure(error))
            }
        }
    }

    private func runCrossfadeRamp(
        context: IOSCrossfadeContext,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard runId == context.runId else { return }
        guard state == .crossfading else { return }

        if context.elapsedMs >= 2000,
           standbyEngine.currentTime <= context.incomingStartTime + 0.2 {
            fallbackToTargetAfterStalledCrossfade(context: context, completion: completion)
            return
        }

        if activeEngine.duration > 0,
           activeEngine.currentTime >= max(0, activeEngine.duration - 0.15) {
            if standbyEngine.currentTime > context.incomingStartTime + 0.2 {
                context.elapsedMs = context.durationMs
                finishCrossfade(context: context, completion: completion)
            } else {
                fallbackToTargetAfterStalledCrossfade(context: context, completion: completion)
            }
            return
        }

        let progress = min(1, max(0, Double(context.elapsedMs) / Double(context.durationMs)))
        let angle = progress * Double.pi / 2
        let fromVolume = context.outgoingStartVolume * Float(cos(angle))
        let toVolume = context.targetVolume * Float(sin(angle))
        activeEngine.setVolume(fromVolume)
        standbyEngine.setVolume(toVolume)

        if context.elapsedMs == 0 {
            IOSPlaybackLog.log("crossfade first frame fromVolume=\(fromVolume) toVolume=\(toVolume)")
        }

        if context.elapsedMs - context.lastRunningEmitMs >= 250 || context.elapsedMs >= context.durationMs {
            emitCrossfadeState(
                "running",
                fromIndex: context.fromIndex,
                toIndex: context.toIndex,
                elapsedMs: context.elapsedMs,
                fromVolume: fromVolume,
                toVolume: toVolume,
                errorCode: nil
            )
            context.lastRunningEmitMs = context.elapsedMs
        }

        if context.elapsedMs >= context.durationMs {
            finishCrossfade(context: context, completion: completion)
            return
        }

        context.elapsedMs = min(context.durationMs, context.elapsedMs + context.intervalMs)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.runCrossfadeRamp(context: context, completion: completion)
        }
        crossfadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(context.intervalMs), execute: workItem)
    }

    private func finishCrossfade(
        context: IOSCrossfadeContext,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        IOSPlaybackLog.log("crossfade completed from=\(context.fromIndex) to=\(context.toIndex)")
        activeEngine.pause()
        activeEngine.reset()

        let outgoingEngine = activeEngine
        activeEngine = standbyEngine
        standbyEngine = outgoingEngine
        activeEngineIndex = context.toIndex
        standbyEngineIndex = nil
        activeEngine.setVolume(context.targetVolume)
        volume = context.targetVolume
        state = playWhenReady ? .playingSingle : .paused
        preparedFromIndex = nil
        preparedToIndex = nil
        preparedSeekTo = 0
        crossfadeContext = nil
        crossfadeWorkItem = nil
        IOSPlaybackLog.log("active/standby swap activeIndex=\(activeEngineIndex ?? -1)")
        emitCrossfadeState(
            "completed",
            fromIndex: context.fromIndex,
            toIndex: context.toIndex,
            elapsedMs: context.durationMs,
            fromVolume: 0,
            toVolume: context.targetVolume,
            errorCode: nil
        )
        emitStateIfNeeded()
        refreshNowPlaying()
        scheduleEndObserver()
        preloadNextIfPossible()
        completion(.success(()))
    }

    private func fallbackToTargetAfterStalledCrossfade(
        context: IOSCrossfadeContext,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        IOSPlaybackLog.log("crossfade incoming stalled from=\(context.fromIndex) to=\(context.toIndex) incomingStart=\(context.incomingStartTime) incomingNow=\(standbyEngine.currentTime)")
        emitCrossfadeState(
            "error",
            fromIndex: context.fromIndex,
            toIndex: context.toIndex,
            elapsedMs: context.elapsedMs,
            fromVolume: activeEngine.volume,
            toVolume: standbyEngine.volume,
            errorCode: "incoming_stalled"
        )
        crossfadeWorkItem?.cancel()
        crossfadeWorkItem = nil
        crossfadeContext = nil
        standbyEngine.pause()
        standbyEngine.reset()
        skip(to: context.toIndex, initialTime: 0, completion: completion)
    }

    private func resumeCrossfadeRamp() {
        guard let context = crossfadeContext else { return }
        runCrossfadeRamp(context: context) { _ in }
    }

    private func promoteLogicalEngineAfterCrossfadeCancellation(errorCode: String) {
        guard let context = crossfadeContext,
              state == .crossfading || state == .pausedDuringCrossfade else { return }
        IOSPlaybackLog.log("crossfade cancel promote logical engine currentIndex=\(currentIndex)")
        let lastPosition = activeEngine.currentTime
        emitCrossfadeCancellationIfNeeded(errorCode: errorCode)
        crossfadeWorkItem?.cancel()
        crossfadeWorkItem = nil
        activeEngine.pause()
        activeEngine.reset()
        let outgoingEngine = activeEngine
        activeEngine = standbyEngine
        standbyEngine = outgoingEngine
        currentIndex = context.toIndex
        activeEngineIndex = currentIndex
        standbyEngineIndex = nil
        crossfadeContext = nil
        state = playWhenReady ? .playingSingle : .paused
        delegate?.playbackOrchestrator(
            self,
            didChangeActiveTrack: context.toIndex,
            lastIndex: context.fromIndex,
            lastPosition: lastPosition
        )
    }

    private func prepareStandby(
        index: Int,
        position: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard queue.indices.contains(index) else {
            completion(.failure(makeError("index_out_of_bounds", "The track index is out of bounds.")))
            return
        }
        let track = queue[index]
        standbyEngineIndex = index
        IOSPlaybackLog.log("standby prepare index=\(index)")
        standbyEngine.prepare(track: track, position: position, completion: completion)
    }

    private func preloadNextIfPossible() {
        guard let next = nextIndex(after: currentIndex) else { return }
        guard state == .playingSingle else { return }
        guard canUseTrackForCrossfade(index: currentIndex), canUseTrackForCrossfade(index: next) else { return }
        state = .preloadingNext
        emitStateIfNeeded()
        prepareStandby(index: next, position: 0) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                IOSPlaybackLog.log("standby preload ready index=\(next)")
            case .failure(let error):
                IOSPlaybackLog.log("standby preload failed index=\(next) error=\(error.localizedDescription)")
                self.standbyEngineIndex = nil
            }
            if self.state == .preloadingNext {
                self.state = self.playWhenReady ? .playingSingle : .paused
                self.emitStateIfNeeded()
            }
        }
    }

    private func canCrossfade(fromIndex: Int, toIndex: Int, durationMs: Int) -> Bool {
        guard queue.indices.contains(fromIndex), queue.indices.contains(toIndex) else { return false }
        guard canUseTrackForCrossfade(index: fromIndex), canUseTrackForCrossfade(index: toIndex) else { return false }
        let seconds = durationForTrack(index: fromIndex)
        if seconds <= 0 { return false }
        if seconds * 1000 <= Double(durationMs + 500) { return false }
        return true
    }

    private func canUseTrackForCrossfade(index: Int) -> Bool {
        guard queue.indices.contains(index) else { return false }
        if queue[index].isLiveStream == true { return false }
        return durationForTrack(index: index) > 0
    }

    private func durationForTrack(index: Int) -> Double {
        guard queue.indices.contains(index) else { return 0 }
        if index == currentIndex, logicalEngine.duration > 0 {
            return logicalEngine.duration
        }
        return queue[index].duration ?? 0
    }

    private func nextIndex(after index: Int) -> Int? {
        let next = index + 1
        return queue.indices.contains(next) ? next : nil
    }

    private func scheduleEndObserver() {
        endObserverWorkItem?.cancel()
        guard playWhenReady else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.observeEnd()
        }
        endObserverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }

    private func observeEnd() {
        guard playWhenReady, (state == .playingSingle || state == .preloadingNext), hasCurrentItem else { return }
        let total = duration
        if total > 0 && currentTime >= max(0, total - 0.15) {
            if let next = nextIndex(after: currentIndex) {
                skip(to: next, initialTime: 0) { _ in }
            } else {
                state = .ended
                emitStateIfNeeded()
                delegate?.playbackOrchestrator(self, didEndQueueAt: currentIndex, position: currentTime)
            }
            return
        }
        scheduleEndObserver()
    }

    private func cancelAllWork() {
        runId += 1
        crossfadeWorkItem?.cancel()
        crossfadeWorkItem = nil
        scheduledStartWorkItem?.cancel()
        scheduledStartWorkItem = nil
        endObserverWorkItem?.cancel()
        endObserverWorkItem = nil
        crossfadeContext = nil
        preparedFromIndex = nil
        preparedToIndex = nil
        preparedSeekTo = 0
    }

    private func emitCrossfadeCancellationIfNeeded(errorCode: String) {
        guard let context = crossfadeContext else { return }
        emitCrossfadeState(
            "cancelled",
            fromIndex: context.fromIndex,
            toIndex: context.toIndex,
            elapsedMs: context.elapsedMs,
            fromVolume: activeEngine.volume,
            toVolume: standbyEngine.volume,
            errorCode: errorCode
        )
    }

    private func resetEngines() {
        activeEngine.reset()
        standbyEngine.reset()
        activeEngine = engineA
        standbyEngine = engineB
        activeEngineIndex = nil
        standbyEngineIndex = nil
    }

    private func emitCrossfadeState(
        _ state: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int? = nil,
        fromVolume: Float? = nil,
        toVolume: Float? = nil,
        errorCode: String? = nil
    ) {
        let elapsedValue = elapsedMs.map { String($0) } ?? "n/a"
        let fromVolumeValue = fromVolume.map { String(format: "%.3f", $0) } ?? "n/a"
        let toVolumeValue = toVolume.map { String(format: "%.3f", $0) } ?? "n/a"
        let errorValue = errorCode ?? "none"
        IOSPlaybackLog.log("crossfade state=\(state) fromIndex=\(fromIndex) toIndex=\(toIndex) elapsedMs=\(elapsedValue) fromVolume=\(fromVolumeValue) toVolume=\(toVolumeValue) error=\(errorValue)")
        delegate?.playbackOrchestrator(
            self,
            didEmitCrossfadeState: state,
            fromIndex: fromIndex,
            toIndex: toIndex,
            elapsedMs: elapsedMs,
            fromVolume: fromVolume,
            toVolume: toVolume,
            errorCode: errorCode
        )
    }

    private func emitStateIfNeeded() {
        let nextState = playbackState
        guard nextState != lastKnownState else { return }
        lastKnownState = nextState
        IOSPlaybackLog.log("state=\(nextState.rawValue)")
        delegate?.playbackOrchestrator(self, didChangeState: nextState)
    }

    private func refreshNowPlaying() {
        IOSPlaybackLog.log("nowPlaying update index=\(currentIndex) position=\(currentTime) rate=\(playWhenReady ? rate : 0)")
        delegate?.playbackOrchestratorDidUpdateNowPlaying(self)
    }

    private func makeError(_ code: String, _ message: String) -> NSError {
        return NSError(
            domain: "RNTP-Orchestrator",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                "code": code
            ]
        )
    }
}
