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
        lastTrack: Track?,
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
    let completionGate: PlaybackBackendCommandCompletion<Void>
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
        incomingStartTime: Double,
        completionGate: PlaybackBackendCommandCompletion<Void>
    ) {
        self.runId = runId
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        self.durationMs = durationMs
        self.intervalMs = intervalMs
        self.targetVolume = targetVolume
        self.outgoingStartVolume = outgoingStartVolume
        self.incomingStartTime = incomingStartTime
        self.completionGate = completionGate
        self.elapsedMs = 0
        self.lastRunningEmitMs = -250
    }
}

private struct IOSScheduledCrossfade {
    let runId: Int
    let fromIndex: Int
    let toIndex: Int
    let fromVolume: Float
    let completionGate: PlaybackBackendCommandCompletion<Void>
}

final class IOSPlaybackOrchestrator {
    typealias SeekOperation = (
        IOSCrossfadeEngine,
        Double,
        @escaping (Result<Void, Error>) -> Void
    ) -> Void
    typealias StandbyPrepareOperation = (
        IOSCrossfadeEngine,
        Track,
        Double,
        @escaping (Result<Void, Error>) -> Void
    ) -> Void
    typealias StandbyMaintenanceScheduler = (TimeInterval, DispatchWorkItem) -> Void
    typealias SynchronizationTestHook = () -> Void
    typealias ScheduledCrossfadeTimerHook = (@escaping () -> Bool) -> Void

    weak var delegate: IOSPlaybackOrchestratorDelegate?

    private let engineA = IOSCrossfadeEngine(name: "engineA")
    private let engineB = IOSCrossfadeEngine(name: "engineB")
    private var activeEngine: IOSCrossfadeEngine
    private var standbyEngine: IOSCrossfadeEngine
    private var queue: [Track] = []
    private var runId = 0
    private var crossfadeContext: IOSCrossfadeContext?
    private var scheduledCrossfade: IOSScheduledCrossfade?
    private var crossfadeWorkItem: DispatchWorkItem?
    private var scheduledStartWorkItem: DispatchWorkItem?
    private var endObserverWorkItem: DispatchWorkItem?
    private var standbyMaintenanceWorkItem: DispatchWorkItem?
    private let crossfadeCommandSlot = PlaybackBackendExclusiveCommandSlot<Void>()
    private var preparedFromIndex: Int?
    private var preparedToIndex: Int?
    private var preparedSeekTo: Double = 0
    private var activeEngineIndex: Int?
    private var standbyEngineIndex: Int?
    private var standbyPreparationGeneration = 0
    private var standbyMaintenanceGeneration = 0
    private var crossfadeEventGeneration: UInt64 = 0
    private let checkpointStore = PlaybackCheckpointStore()
    private var lastKnownState: State = .none
    private var pendingRecoveryPosition: Double?
    private let operationRegistry = PlaybackBackendOperationRegistry()
    private let seekOperation: SeekOperation
    private let standbyPrepareOperation: StandbyPrepareOperation
    private let standbyMaintenanceScheduler: StandbyMaintenanceScheduler
    private let standbyMaintenanceAfterValidationHook: SynchronizationTestHook
    private let crossfadeRampAfterValidationHook: SynchronizationTestHook
    private let standbyPreparationBeforeNativeInvocationHook: SynchronizationTestHook
    private let crossfadeRunningBeforeDeliveryHook: SynchronizationTestHook
    private let crossfadeFinishAfterCommitHook: SynchronizationTestHook
    private let scheduledCrossfadeTimerHook: ScheduledCrossfadeTimerHook
    private let scheduledCrossfadeCancellationAfterClaimHook: SynchronizationTestHook
    private let crossfadeMutationLock = NSLock()
    private let standbyPreparationInvocationQueue = DispatchQueue.main
    private let crossfadeEventDeliveryQueue = DispatchQueue.main
    private(set) var state: IOSPlaybackOrchestratorState = .idle
    private(set) var currentIndex: Int = -1
    private(set) var playWhenReady: Bool = false
    private(set) var volume: Float = 1
    private(set) var rate: Float = 1

    var transitionGeneration: Int {
        return runId
    }

    var isEndObservationScheduled: Bool {
        return endObserverWorkItem != nil
    }

    var logicalEngineOutputVolume: Float {
        return logicalEngine.volume
    }

#if RNTP_E2E_PROBES
    func e2eSnapshot(backendIdentity: String) -> [String: Any] {
        precondition(Thread.isMainThread)
        crossfadeMutationLock.lock()
        defer { crossfadeMutationLock.unlock() }
        return [
            "schemaVersion": 1,
            "backendId": backendIdentity,
            "backendKind": "pingPong",
            "generation": runId,
            "state": String(describing: state),
            "currentIndex": currentIndex,
            "engineAId": engineA.e2eIdentity,
            "engineBId": engineB.e2eIdentity,
            "activeEngineId": activeEngine.e2eIdentity,
            "standbyEngineId": standbyEngine.e2eIdentity,
            "activeEngineIndex": activeEngineIndex.map { $0 as Any } ?? NSNull(),
            "standbyEngineIndex": standbyEngineIndex.map { $0 as Any } ?? NSNull(),
            "engines": [engineA.e2eSnapshot(), engineB.e2eSnapshot()]
        ]
    }
#endif

    init(
        seekOperation: @escaping SeekOperation = { engine, position, completion in
            engine.seek(to: position, completion: completion)
        },
        standbyPrepareOperation: @escaping StandbyPrepareOperation = {
            engine, track, position, completion in
            engine.prepare(track: track, position: position, completion: completion)
        },
        standbyMaintenanceScheduler: @escaping StandbyMaintenanceScheduler = {
            delay, workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        },
        standbyMaintenanceAfterValidationHook: @escaping SynchronizationTestHook = {},
        crossfadeRampAfterValidationHook: @escaping SynchronizationTestHook = {},
        standbyPreparationBeforeNativeInvocationHook: @escaping SynchronizationTestHook = {},
        crossfadeRunningBeforeDeliveryHook: @escaping SynchronizationTestHook = {},
        crossfadeFinishAfterCommitHook: @escaping SynchronizationTestHook = {},
        scheduledCrossfadeTimerHook: @escaping ScheduledCrossfadeTimerHook = { check in
            _ = check()
        },
        scheduledCrossfadeCancellationAfterClaimHook: @escaping SynchronizationTestHook = {}
    ) {
        self.seekOperation = seekOperation
        self.standbyPrepareOperation = standbyPrepareOperation
        self.standbyMaintenanceScheduler = standbyMaintenanceScheduler
        self.standbyMaintenanceAfterValidationHook = standbyMaintenanceAfterValidationHook
        self.crossfadeRampAfterValidationHook = crossfadeRampAfterValidationHook
        self.standbyPreparationBeforeNativeInvocationHook =
            standbyPreparationBeforeNativeInvocationHook
        self.crossfadeRunningBeforeDeliveryHook = crossfadeRunningBeforeDeliveryHook
        self.crossfadeFinishAfterCommitHook = crossfadeFinishAfterCommitHook
        self.scheduledCrossfadeTimerHook = scheduledCrossfadeTimerHook
        self.scheduledCrossfadeCancellationAfterClaimHook =
            scheduledCrossfadeCancellationAfterClaimHook
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
        let livePosition = logicalEngine.currentTime
        if livePosition > 0 {
            pendingRecoveryPosition = nil
            return livePosition
        }
        if let pendingRecoveryPosition,
           state == .loading || state == .seeking || state == .skipping {
            return pendingRecoveryPosition
        }
        return checkpointForCurrentIndex()?.position ?? livePosition
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

    var nowPlayingPlaybackRate: Float {
        switch state {
        case .playingSingle, .preloadingNext, .crossfading:
            return playWhenReady && logicalEngine.isPlaying ? rate : 0
        default:
            return 0
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
        let isUnchanged = queue.count == tracks.count && zip(queue, tracks).allSatisfy {
            $0.0 === $0.1
        }
        guard !isUnchanged else { return }
        let lastIndex = currentIndex >= 0 ? currentIndex : nil
        let lastPosition = currentTime
        let currentTrack = self.currentTrack
        let retainedIndex = currentTrack.flatMap { track in
            tracks.firstIndex(where: { $0 === track })
        }
        operationRegistry.invalidateAll(reason: "queue_changed")
        if retainedIndex != nil && (state == .crossfading || state == .pausedDuringCrossfade) {
            promoteLogicalEngineAfterCrossfadeCancellation(errorCode: "queue_changed")
        } else {
            emitCrossfadeCancellationIfNeeded(errorCode: "queue_changed")
        }
        cancelActiveCrossfade(errorCode: "queue_changed")
        cancelAllWork()
        queue = tracks
        if currentTrack != nil {
            if let newIndex = retainedIndex {
                currentIndex = newIndex
                activeEngineIndex = newIndex
                standbyEngine.pause()
                standbyEngine.reset()
                standbyEngineIndex = nil
                if state == .preloadingNext {
                    state = playWhenReady ? .playingSingle : .paused
                }
                if lastIndex != newIndex {
                    delegate?.playbackOrchestrator(
                        self,
                        didChangeActiveTrack: newIndex,
                        lastIndex: lastIndex,
                        lastTrack: currentTrack,
                        lastPosition: lastPosition
                    )
                }
                if playWhenReady && state == .playingSingle {
                    scheduleEndObserver()
                    preloadNextIfPossible()
                }
            } else {
                resetEngines()
                currentIndex = -1
                playWhenReady = false
                state = .idle
                delegate?.playbackOrchestrator(
                    self,
                    didChangeActiveTrack: nil,
                    lastIndex: lastIndex,
                    lastTrack: currentTrack,
                    lastPosition: lastPosition
                )
                emitStateIfNeeded()
            }
        } else if !tracks.indices.contains(currentIndex) {
            resetEngines()
            currentIndex = -1
            playWhenReady = false
            state = .idle
            emitStateIfNeeded()
        }
        IOSPlaybackLog.log("queue sync count=\(tracks.count) currentIndex=\(currentIndex)")
        refreshNowPlaying()
    }

    func replaceQueue(_ tracks: [Track], currentIndex: Int = -1) {
        operationRegistry.invalidateAll(reason: "queue_replaced")
        emitCrossfadeCancellationIfNeeded(errorCode: "queue_replaced")
        cancelActiveCrossfade(errorCode: "queue_replaced")
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

    func verifyPreparedForActivation(expectedIndex: Int?) throws {
        guard state != .error && state != .loading && state != .seeking && state != .skipping else {
            throw makeError(
                "playback_backend_activation_not_ready",
                "The ping-pong playback candidate is still transitioning."
            )
        }
        guard let expectedIndex = expectedIndex else { return }
        guard queue.indices.contains(expectedIndex),
              currentIndex == expectedIndex,
              activeEngineIndex == expectedIndex,
              activeEngine.isReady else {
            throw makeError(
                "playback_backend_activation_not_ready",
                "The ping-pong playback candidate did not restore the active track."
            )
        }
    }

    func preparePlaybackForActivation(
        playWhenReady: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard hasCurrentItem else {
            self.playWhenReady = false
            state = .idle
            if playWhenReady {
                completion(.failure(makeError(
                    "playback_backend_activation_not_ready",
                    "The ping-pong playback candidate has no active track to play."
                )))
            } else {
                completion(.success(()))
            }
            return
        }

        activeEngine.setVolume(0)
        self.playWhenReady = playWhenReady
        guard playWhenReady else {
            activeEngine.pause()
            standbyEngine.pause()
            state = .paused
            emitStateIfNeeded()
            completion(.success(()))
            return
        }

        activeEngine.play(rate: rate) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.state = .playingSingle
                self.scheduleEndObserver()
                self.emitStateIfNeeded()
                self.refreshNowPlaying()
                completion(.success(()))
            case .failure(let error):
                self.playWhenReady = false
                self.activeEngine.pause()
                self.state = .paused
                self.emitStateIfNeeded()
                completion(.failure(error))
            }
        }
    }

    func activatePreparedPlayback(playWhenReady: Bool, restoredVolume: Float) {
        volume = max(0, min(1, restoredVolume))
        self.playWhenReady = playWhenReady
        guard hasCurrentItem else {
            activeEngine.pause()
            standbyEngine.pause()
            state = .idle
            emitStateIfNeeded()
            refreshNowPlaying()
            return
        }

        activeEngine.setVolume(volume)
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
            let resumePosition = resumePositionForCurrentIndex()
            recoverCurrentItem(position: resumePosition, reason: "play_from_paused", completion: completion)
        case .idle, .ended:
            let indexToPlay = queue.indices.contains(currentIndex) ? currentIndex : 0
            guard queue.indices.contains(indexToPlay) else {
                completion?(.failure(makeError("empty_queue", "No track is available to play.")))
                return
            }
            loadIndex(indexToPlay, position: 0, autoPlay: true, completion: completion)
        case .loading:
            guard queue.indices.contains(currentIndex) else {
                completion?(.failure(makeError("empty_queue", "No track is available to play.")))
                return
            }
            let resumePosition = resumePositionForCurrentIndex()
            IOSPlaybackLog.log("play reload from loading index=\(currentIndex) position=\(resumePosition)")
            recoverCurrentItem(position: resumePosition, reason: "play_from_loading", completion: completion)
        case .seeking, .skipping, .preloadingNext:
            completion?(.success(()))
        case .playingSingle, .crossfading:
            completion?(.success(()))
        case .error:
            guard queue.indices.contains(currentIndex) else {
                completion?(.failure(makeError("player_error", "The orchestrator is in an error state.")))
                return
            }
            let resumePosition = resumePositionForCurrentIndex()
            IOSPlaybackLog.log("play recover from error index=\(currentIndex) position=\(resumePosition)")
            recoverCurrentItem(position: resumePosition, reason: "play_from_error", completion: completion)
        }
        refreshNowPlaying()
    }

    func pause() {
        IOSPlaybackLog.log("pause state=\(state)")
        checkpoint(reason: "pause")
        operationRegistry.invalidateAll(reason: "pause")
        playWhenReady = false
        if state == .crossfading || state == .pausedDuringCrossfade {
            promoteLogicalEngineAfterCrossfadeCancellation(errorCode: "pause")
        }
        cancelActiveCrossfade(errorCode: "pause")
        cancelScheduledPlaybackWork()
        activeEngine.pause()
        standbyEngine.pause()
        state = hasCurrentItem ? .paused : .idle
        emitStateIfNeeded()
        refreshNowPlaying()
    }

    func checkpointForSystemEvent(_ reason: String) {
        checkpoint(reason: reason)
        if !playWhenReady {
            scheduledStartWorkItem?.cancel()
            scheduledStartWorkItem = nil
            endObserverWorkItem?.cancel()
            endObserverWorkItem = nil
        }
        refreshNowPlaying()
    }

    func settleActiveTransition() {
        operationRegistry.invalidateAll(reason: "backend_swap")
        if state == .crossfading || state == .pausedDuringCrossfade {
            promoteLogicalEngineAfterCrossfadeCancellation(errorCode: "backend_swap")
        }
        cancelActiveCrossfade(errorCode: "backend_swap")
        cancelScheduledPlaybackWork()
        if state == .preloadingNext {
            state = playWhenReady ? .playingSingle : .paused
            emitStateIfNeeded()
            refreshNowPlaying()
        } else if state == .loading || state == .seeking || state == .skipping {
            resetEngines()
            state = hasCurrentItem ? .paused : .idle
            emitStateIfNeeded()
            refreshNowPlaying()
        }
        if playWhenReady && state == .playingSingle {
            scheduleEndObserver()
            preloadNextIfPossible()
        }
    }

    func stop() {
        IOSPlaybackLog.log("stop")
        operationRegistry.invalidateAll(reason: "stop")
        playWhenReady = false
        emitCrossfadeCancellationIfNeeded(errorCode: "stop")
        cancelActiveCrossfade(errorCode: "stop")
        cancelAllWork()
        resetEngines()
        currentIndex = -1
        checkpointStore.clear()
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
        cancelActiveCrossfade(errorCode: "seek")
        cancelScheduledPlaybackWork()

        let completionGate = PlaybackBackendCommandCompletion<Void> { result in
            completion?(result)
        }
        let ticket = operationRegistry.begin { [weak self, completionGate] reason in
            guard let self = self else { return }
            self.stabilizeCancelledOperation()
            completionGate.resolve(.failure(self.makeError(
                "cancelled",
                "Playback seek was cancelled by \(reason)."
            )))
        }
        state = .seeking
        emitStateIfNeeded()
        seekOperation(activeEngine, position) { [weak self, completionGate] result in
            guard let self = self else { return }
            guard self.operationRegistry.complete(ticket, perform: {
                switch result {
                case .success:
                    self.checkpoint(position: position, reason: "seek")
                    self.state = self.playWhenReady ? .playingSingle : .paused
                    if self.playWhenReady {
                        self.activeEngine.play(rate: self.rate)
                        self.scheduleEndObserver()
                    }
                case .failure:
                    self.state = .error
                }
                self.operationRegistry.performAfterCurrentMutation {
                    self.emitStateIfNeeded()
                    self.refreshNowPlaying()
                }
            }) else { return }
            completionGate.resolve(result)
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
        operationRegistry.invalidateAll(reason: "skip")
        emitCrossfadeCancellationIfNeeded(errorCode: "skip")
        cancelActiveCrossfade(errorCode: "skip")
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
        var fromIndex = -1
        var toIndex = -1
        var completionGate: PlaybackBackendCommandCompletion<Void>?
        var rejection: (event: String, code: String, error: NSError)?
        var normalizedPreloadState = false

        crossfadeMutationLock.lock()
        fromIndex = currentIndex
        toIndex = previous ? fromIndex - 1 : fromIndex + 1
        if !playWhenReady || (state != .playingSingle && state != .preloadingNext) {
            rejection = (
                "cancelled",
                "not_playing",
                makeError("crossfade_not_playing", "Crossfade cannot prepare while playback is not active.")
            )
        } else if state == .crossfading || state == .pausedDuringCrossfade {
            rejection = (
                "error",
                "crossfade_in_progress",
                makeError("crossfade_in_progress", "A crossfade is already in progress.")
            )
        } else if !canCrossfade(fromIndex: fromIndex, toIndex: toIndex, durationMs: 1) {
            rejection = (
                "error",
                "crossfade_target_unavailable",
                makeError("crossfade_target_unavailable", "No crossfade target track is available.")
            )
        } else if let admitted = crossfadeCommandSlot.begin(resolve: completion) {
            completionGate = admitted
            cancelStandbyMaintenanceLocked()
            if state == .preloadingNext {
                state = .playingSingle
                normalizedPreloadState = true
            }
        } else {
            rejection = (
                "error",
                "crossfade_in_progress",
                makeError("crossfade_in_progress", "A crossfade is already scheduled or in progress.")
            )
        }
        crossfadeMutationLock.unlock()

        if let rejection {
            emitCrossfadeState(
                rejection.event,
                fromIndex: fromIndex,
                toIndex: toIndex,
                errorCode: rejection.code
            )
            completion(.failure(rejection.error))
            return
        }
        guard let completionGate else { return }
        if normalizedPreloadState { emitStateIfNeeded() }

        let ticket = operationRegistry.begin { [weak self, completionGate] reason in
            guard let self = self else { return }
            self.crossfadeMutationLock.lock()
            self.standbyEngine.pause()
            self.standbyEngine.reset()
            self.standbyEngineIndex = nil
            self.crossfadeMutationLock.unlock()
            self.emitCrossfadeState(
                "cancelled",
                fromIndex: fromIndex,
                toIndex: toIndex,
                errorCode: reason
            )
            self.crossfadeCommandSlot.complete(completionGate, result: .failure(self.makeError(
                "cancelled",
                "Crossfade preparation was cancelled by \(reason)."
            )))
        }
        prepareStandby(index: toIndex, position: max(0, seekTo)) { [weak self, completionGate] result in
            guard let self = self else { return }
            guard self.operationRegistry.complete(ticket, perform: {
                self.crossfadeMutationLock.lock()
                switch result {
                case .success:
                    self.preparedFromIndex = fromIndex
                    self.preparedToIndex = toIndex
                    self.preparedSeekTo = max(0, seekTo)
                case .failure: break
                }
                self.crossfadeMutationLock.unlock()
                self.operationRegistry.performAfterCurrentMutation {
                    switch result {
                    case .success:
                        self.emitCrossfadeState(
                            "prepared",
                            fromIndex: fromIndex,
                            toIndex: toIndex,
                            elapsedMs: 0,
                            fromVolume: self.volume,
                            toVolume: 0,
                            errorCode: nil
                        )
                    case .failure:
                        self.emitCrossfadeState(
                            "error",
                            fromIndex: fromIndex,
                            toIndex: toIndex,
                            errorCode: "prepare_failed"
                        )
                    }
                }
            }) else { return }
            self.crossfadeCommandSlot.complete(completionGate, result: result)
        }
    }

    func crossFade(
        fadeDuration: Double,
        fadeInterval: Double,
        fadeToVolume: Double,
        waitUntil: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var fromIndex = -1
        var toIndex = -1
        let durationMs = max(1, Int(fadeDuration))
        var completionGate: PlaybackBackendCommandCompletion<Void>?
        var rejection: (event: String, code: String, error: NSError)?
        var normalizedPreloadState = false
        var currentRunId = -1
        var scheduledFromVolume: Float = 0
        var forcedScheduledCrossfade: IOSScheduledCrossfade?

        crossfadeMutationLock.lock()
        fromIndex = currentIndex
        toIndex = preparedFromIndex == fromIndex && preparedToIndex != nil
            ? preparedToIndex!
            : fromIndex + 1
        if crossfadeCommandSlot.isOccupied {
            if let scheduled = scheduledCrossfade,
               scheduled.fromIndex == fromIndex,
               scheduled.toIndex == toIndex,
               waitUntil <= currentTime * 1_000 {
                scheduledStartWorkItem?.cancel()
                scheduledStartWorkItem = nil
                forcedScheduledCrossfade = scheduled
            } else {
                rejection = (
                    "error",
                    "crossfade_in_progress",
                    makeError("crossfade_in_progress", "A crossfade is already scheduled or in progress.")
                )
            }
        } else if !playWhenReady || (state != .playingSingle && state != .preloadingNext) {
            rejection = (
                "cancelled",
                "not_playing",
                makeError("crossfade_not_playing", "Crossfade cannot start while playback is not active.")
            )
        } else if !canCrossfade(fromIndex: fromIndex, toIndex: toIndex, durationMs: durationMs) {
            rejection = (
                "error",
                "crossfade_unavailable",
                makeError("crossfade_unavailable", "Crossfade is not available for this transition.")
            )
        } else if let admitted = crossfadeCommandSlot.begin(resolve: completion) {
            completionGate = admitted
            cancelStandbyMaintenanceLocked()
            if state == .preloadingNext {
                state = .playingSingle
                normalizedPreloadState = true
            }
            runId += 1
            currentRunId = runId
            scheduledFromVolume = activeEngine.volume
            scheduledCrossfade = IOSScheduledCrossfade(
                runId: currentRunId,
                fromIndex: fromIndex,
                toIndex: toIndex,
                fromVolume: scheduledFromVolume,
                completionGate: admitted
            )
            enqueueCrossfadeEventLocked(
                "scheduled",
                fromIndex: fromIndex,
                toIndex: toIndex,
                elapsedMs: 0,
                fromVolume: scheduledFromVolume,
                toVolume: 0
            )
        } else {
            rejection = (
                "error",
                "crossfade_in_progress",
                makeError("crossfade_in_progress", "A crossfade is already scheduled or in progress.")
            )
        }
        crossfadeMutationLock.unlock()

        if let rejection {
            emitCrossfadeState(
                rejection.event,
                fromIndex: fromIndex,
                toIndex: toIndex,
                errorCode: rejection.code
            )
            completion(.failure(rejection.error))
            return
        }
        if let forcedScheduledCrossfade {
            completion(.success(()))
            let forcedRunId = forcedScheduledCrossfade.runId
            let forcedCompletionGate = forcedScheduledCrossfade.completionGate
            let forcedCompletion: (Result<Void, Error>) -> Void = { [weak self, forcedCompletionGate] result in
                guard let self else { return }
                self.crossfadeMutationLock.lock()
                let terminalResolver = self.crossfadeCommandSlot.takeResolver(
                    forcedCompletionGate,
                    result: result
                )
                if terminalResolver != nil,
                   self.scheduledCrossfade?.runId == forcedRunId,
                   self.scheduledCrossfade?.completionGate === forcedCompletionGate {
                    self.scheduledCrossfade = nil
                    self.scheduledStartWorkItem?.cancel()
                    self.scheduledStartWorkItem = nil
                }
                self.crossfadeMutationLock.unlock()
                terminalResolver?()
            }
            startCrossfade(
                runId: forcedRunId,
                fromIndex: fromIndex,
                toIndex: toIndex,
                durationMs: durationMs,
                intervalMs: max(10, Int(fadeInterval)),
                targetVolume: Float(max(0, min(1, fadeToVolume))),
                completionGate: forcedCompletionGate,
                completion: forcedCompletion
            )
            return
        }
        guard let completionGate else { return }
        if normalizedPreloadState { emitStateIfNeeded() }
        let transitionCompletion: (Result<Void, Error>) -> Void = { [weak self, completionGate] result in
            guard let self else { return }
            self.crossfadeMutationLock.lock()
            let terminalResolver = self.crossfadeCommandSlot.takeResolver(
                completionGate,
                result: result
            )
            if terminalResolver != nil,
               self.scheduledCrossfade?.runId == currentRunId,
               self.scheduledCrossfade?.completionGate === completionGate {
                self.scheduledCrossfade = nil
                self.scheduledStartWorkItem?.cancel()
                self.scheduledStartWorkItem = nil
            }
            self.crossfadeMutationLock.unlock()
            terminalResolver?()
        }
        let intervalMs = max(10, Int(fadeInterval))
        let targetVolume = Float(max(0, min(1, fadeToVolume)))

        func scheduleStartCheck() -> Bool {
            var nextCheck: (workItem: DispatchWorkItem, delayMs: Int)?
            self.crossfadeMutationLock.lock()
            guard let scheduled = self.scheduledCrossfade,
                  self.runId == currentRunId,
                  scheduled.runId == currentRunId,
                  scheduled.fromIndex == fromIndex,
                  scheduled.toIndex == toIndex,
                  scheduled.completionGate === completionGate,
                  self.crossfadeCommandSlot.isCurrent(completionGate) else {
                self.crossfadeMutationLock.unlock()
                return false
            }
            guard self.playWhenReady else {
                let error = self.makeError(
                    "crossfade_not_playing",
                    "Crossfade was cancelled because playback is paused."
                )
                let terminalResolver = self.crossfadeCommandSlot.takeResolver(
                    completionGate,
                    result: .failure(error)
                )
                if let terminalResolver {
                    self.runId += 1
                    self.scheduledCrossfade = nil
                    self.scheduledStartWorkItem?.cancel()
                    self.scheduledStartWorkItem = nil
                    self.crossfadeEventGeneration &+= 1
                    self.enqueueCrossfadeEventLocked(
                        "cancelled",
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        elapsedMs: 0,
                        fromVolume: scheduled.fromVolume,
                        toVolume: 0,
                        errorCode: "not_playing",
                        afterDelivery: terminalResolver
                    )
                }
                self.crossfadeMutationLock.unlock()
                return false
            }
            let remainingMs = Int(waitUntil - self.currentTime * 1000)
            if remainingMs <= 0 {
                self.scheduledStartWorkItem = nil
                self.crossfadeMutationLock.unlock()
                self.startCrossfade(
                    runId: currentRunId,
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    durationMs: durationMs,
                    intervalMs: intervalMs,
                    targetVolume: targetVolume,
                    completionGate: completionGate,
                    completion: transitionCompletion
                )
                return true
            }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scheduledCrossfadeTimerHook(scheduleStartCheck)
            }
            self.scheduledStartWorkItem = workItem
            nextCheck = (workItem, max(50, min(250, remainingMs)))
            self.crossfadeMutationLock.unlock()
            guard let nextCheck else { return false }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(nextCheck.delayMs),
                execute: nextCheck.workItem
            )
            return false
        }

        _ = scheduleStartCheck()
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

        let completionGate = PlaybackBackendCommandCompletion<Void> { result in
            completion?(result)
        }
        let ticket = operationRegistry.begin { [weak self, completionGate] reason in
            guard let self = self else { return }
            self.stabilizeCancelledOperation()
            completionGate.resolve(.failure(self.makeError(
                "cancelled",
                "Playback load was cancelled by \(reason)."
            )))
        }
        runId += 1
        let currentRunId = runId
        let lastIndex = currentIndex >= 0 ? currentIndex : nil
        let lastPosition = currentTime
        let lastTrack = currentTrack
        let track = queue[index]
        state = .loading
        emitStateIfNeeded()
        resetEngines()
        activeEngineIndex = index
        activeEngine.setVolume(autoPlay ? volume : 0)

        activeEngine.prepare(track: track, position: position) { [weak self] result in
            guard let self = self,
                  self.runId == currentRunId,
                  self.operationRegistry.isCurrent(ticket) else { return }
            switch result {
            case .success:
                if autoPlay {
                    guard self.operationRegistry.performIfCurrent(ticket, perform: {
                        self.currentIndex = index
                        self.checkpoint(position: position, reason: "load")
                        self.playWhenReady = true
                        self.activeEngine.setVolume(self.volume)
                        self.operationRegistry.performAfterCurrentMutation {
                            self.delegate?.playbackOrchestrator(
                                self,
                                didChangeActiveTrack: index,
                                lastIndex: lastIndex,
                                lastTrack: lastTrack,
                                lastPosition: lastPosition
                            )
                        }
                        self.activeEngine.play(rate: self.rate) { [weak self, completionGate] playResult in
                            guard let self = self else { return }
                            self.operationRegistry.performAfterCurrentMutation {
                                DispatchQueue.main.async {
                                    guard self.runId == currentRunId else { return }
                                    guard self.operationRegistry.complete(ticket, perform: {
                                        switch playResult {
                                        case .success:
                                            self.state = .playingSingle
                                            self.scheduleEndObserver()
                                        case .failure(let error):
                                            IOSPlaybackLog.log("loadIndex autoplay failed index=\(index) error=\(error.localizedDescription)")
                                            self.playWhenReady = false
                                            self.state = .paused
                                        }
                                        self.operationRegistry.performAfterCurrentMutation {
                                            if case .success = playResult {
                                                self.preloadNextIfPossible()
                                            }
                                            self.emitStateIfNeeded()
                                            self.refreshNowPlaying()
                                        }
                                    }) else { return }
                                    completionGate.resolve(playResult)
                                }
                            }
                        }
                    }) else { return }
                    return
                } else {
                    guard self.operationRegistry.complete(ticket, perform: {
                        self.currentIndex = index
                        self.checkpoint(position: position, reason: "load")
                        self.playWhenReady = false
                        self.state = .paused
                        self.activeEngine.setVolume(self.volume)
                        self.operationRegistry.performAfterCurrentMutation {
                            self.delegate?.playbackOrchestrator(
                                self,
                                didChangeActiveTrack: index,
                                lastIndex: lastIndex,
                                lastTrack: lastTrack,
                                lastPosition: lastPosition
                            )
                            self.emitStateIfNeeded()
                            self.refreshNowPlaying()
                        }
                    }) else { return }
                }
                completionGate.resolve(.success(()))
            case .failure(let error):
                guard self.operationRegistry.complete(ticket, perform: {
                    self.state = .error
                    self.operationRegistry.performAfterCurrentMutation {
                        self.emitStateIfNeeded()
                        self.refreshNowPlaying()
                    }
                }) else { return }
                completionGate.resolve(.failure(error))
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
        completionGate: PlaybackBackendCommandCompletion<Void>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        crossfadeMutationLock.lock()
        let admitted = isScheduledCrossfadeAdmittedLocked(
            runId: runId,
            fromIndex: fromIndex,
            toIndex: toIndex,
            completionGate: completionGate
        )
        crossfadeMutationLock.unlock()
        guard admitted else { return }

        let startPreparedStandby = { [weak self] in
            guard let self = self else { return }
            self.crossfadeMutationLock.lock()
            let admitted = self.isScheduledCrossfadeAdmittedLocked(
                runId: runId,
                fromIndex: fromIndex,
                toIndex: toIndex,
                completionGate: completionGate
            )
            self.crossfadeMutationLock.unlock()
            guard admitted else { return }
            IOSPlaybackLog.log("crossfade start from=\(fromIndex) to=\(toIndex)")
            let outgoingStartVolume = self.activeEngine.volume > 0 ? self.activeEngine.volume : self.volume
            self.activeEngine.setVolume(outgoingStartVolume)
            self.standbyEngine.setVolume(0)
            self.standbyEngine.play(rate: self.rate) { [weak self] result in
                guard let self = self, self.runId == runId else { return }
                switch result {
                case .success:
                    self.crossfadeMutationLock.lock()
                    guard self.isScheduledCrossfadeAdmittedLocked(
                        runId: runId,
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        completionGate: completionGate
                    ) else {
                        self.crossfadeMutationLock.unlock()
                        return
                    }
                    let lastPosition = self.activeEngine.currentTime
                    let lastTrack = self.queue.indices.contains(fromIndex)
                        ? self.queue[fromIndex]
                        : nil
                    self.currentIndex = toIndex
                    self.checkpoint(position: self.standbyEngine.currentTime, reason: "crossfade_start")
                    self.state = .crossfading
                    let context = IOSCrossfadeContext(
                        runId: runId,
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        durationMs: durationMs,
                        intervalMs: intervalMs,
                        targetVolume: targetVolume,
                        outgoingStartVolume: outgoingStartVolume,
                        incomingStartTime: self.standbyEngine.currentTime,
                        completionGate: completionGate
                    )
                    self.scheduledCrossfade = nil
                    self.scheduledStartWorkItem = nil
                    self.crossfadeEventGeneration &+= 1
                    self.crossfadeContext = context
                    let startedFromVolume = self.activeEngine.volume
                    let startedToVolume = self.standbyEngine.volume
                    self.crossfadeMutationLock.unlock()
                    self.delegate?.playbackOrchestrator(
                        self,
                        didChangeActiveTrack: toIndex,
                        lastIndex: fromIndex,
                        lastTrack: lastTrack,
                        lastPosition: lastPosition
                    )
                    self.refreshNowPlaying()
                    self.emitStateIfNeeded()
                    self.emitCrossfadeState(
                        "started",
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        elapsedMs: 0,
                        fromVolume: startedFromVolume,
                        toVolume: startedToVolume,
                        errorCode: nil
                    )
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
            self.crossfadeMutationLock.lock()
            let admitted = self.isScheduledCrossfadeAdmittedLocked(
                runId: runId,
                fromIndex: fromIndex,
                toIndex: toIndex,
                completionGate: completionGate
            )
            self.crossfadeMutationLock.unlock()
            guard admitted else { return }
            switch result {
            case .success:
                startPreparedStandby()
            case .failure(let error):
                if !self.isStandbyPreparationSuperseded(error) {
                    self.emitCrossfadeState(
                        "error",
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        errorCode: "prepare_failed"
                    )
                }
                completion(.failure(error))
            }
        }
    }

    private func isScheduledCrossfadeAdmittedLocked(
        runId: Int,
        fromIndex: Int,
        toIndex: Int,
        completionGate: PlaybackBackendCommandCompletion<Void>
    ) -> Bool {
        guard let scheduled = scheduledCrossfade else { return false }
        return self.runId == runId &&
            scheduled.runId == runId &&
            scheduled.fromIndex == fromIndex &&
            scheduled.toIndex == toIndex &&
            scheduled.completionGate === completionGate &&
            crossfadeCommandSlot.isCurrent(completionGate)
    }

    private func runCrossfadeRamp(
        context: IOSCrossfadeContext,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var shouldFallback = false
        var shouldFinish = false
        var firstFrame: (fromVolume: Float, toVolume: Float)?
        var nextWorkItem: DispatchWorkItem?

        crossfadeMutationLock.lock()
        guard runId == context.runId,
              state == .crossfading,
              crossfadeContext === context else {
            crossfadeMutationLock.unlock()
            return
        }
        crossfadeRampAfterValidationHook()

        if context.elapsedMs >= 2000,
           standbyEngine.currentTime <= context.incomingStartTime + 0.2 {
            shouldFallback = true
        } else if activeEngine.duration > 0,
                  activeEngine.currentTime >= max(0, activeEngine.duration - 0.15) {
            if standbyEngine.currentTime > context.incomingStartTime + 0.2 {
                context.elapsedMs = context.durationMs
                shouldFinish = true
            } else {
                shouldFallback = true
            }
        } else {
            let progress = min(1, max(0, Double(context.elapsedMs) / Double(context.durationMs)))
            let angle = progress * Double.pi / 2
            let fromVolume = context.outgoingStartVolume * Float(cos(angle))
            let toVolume = context.targetVolume * Float(sin(angle))
            activeEngine.setVolume(fromVolume)
            standbyEngine.setVolume(toVolume)

            if context.elapsedMs == 0 {
                firstFrame = (fromVolume, toVolume)
            }
            if context.elapsedMs - context.lastRunningEmitMs >= 250 ||
                context.elapsedMs >= context.durationMs {
                enqueueCrossfadeEventLocked(
                    "running",
                    fromIndex: context.fromIndex,
                    toIndex: context.toIndex,
                    elapsedMs: context.elapsedMs,
                    fromVolume: fromVolume,
                    toVolume: toVolume,
                    errorCode: nil,
                    admissionGeneration: crossfadeEventGeneration,
                    beforeDelivery: crossfadeRunningBeforeDeliveryHook
                )
                context.lastRunningEmitMs = context.elapsedMs
            }
            if context.elapsedMs >= context.durationMs {
                shouldFinish = true
            } else {
                context.elapsedMs = min(context.durationMs, context.elapsedMs + context.intervalMs)
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.runCrossfadeRamp(context: context, completion: completion)
                }
                crossfadeWorkItem = workItem
                nextWorkItem = workItem
            }
        }
        crossfadeMutationLock.unlock()

        if let firstFrame {
            IOSPlaybackLog.log(
                "crossfade first frame fromVolume=\(firstFrame.fromVolume) " +
                "toVolume=\(firstFrame.toVolume)"
            )
        }
        if shouldFallback {
            fallbackToTargetAfterStalledCrossfade(context: context, completion: completion)
        } else if shouldFinish {
            finishCrossfade(context: context)
        } else if let nextWorkItem {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(context.intervalMs),
                execute: nextWorkItem
            )
        }
    }

    private func finishCrossfade(context: IOSCrossfadeContext) {
        crossfadeMutationLock.lock()
        guard runId == context.runId,
              state == .crossfading,
              crossfadeContext === context else {
            crossfadeMutationLock.unlock()
            return
        }
        guard let terminalResolver = crossfadeCommandSlot.takeResolver(
            context.completionGate,
            result: .success(())
        ) else {
            crossfadeMutationLock.unlock()
            return
        }
        IOSPlaybackLog.log("crossfade completed from=\(context.fromIndex) to=\(context.toIndex)")
        activeEngine.setVolume(0)
        activeEngine.pause()

        let outgoingEngine = activeEngine
        activeEngine = standbyEngine
        standbyEngine = outgoingEngine
        activeEngineIndex = context.toIndex
        standbyEngineIndex = nil
        checkpoint(position: activeEngine.currentTime, reason: "crossfade_complete")
        activeEngine.setVolume(context.targetVolume)
        volume = context.targetVolume
        state = playWhenReady ? .playingSingle : .paused
        preparedFromIndex = nil
        preparedToIndex = nil
        preparedSeekTo = 0
        crossfadeContext = nil
        crossfadeWorkItem = nil
        crossfadeEventGeneration &+= 1
        enqueueCrossfadeEventLocked(
            "completed",
            fromIndex: context.fromIndex,
            toIndex: context.toIndex,
            elapsedMs: context.durationMs,
            fromVolume: 0,
            toVolume: context.targetVolume,
            errorCode: nil,
            beforeDelivery: crossfadeFinishAfterCommitHook,
            afterDelivery: terminalResolver
        )
        IOSPlaybackLog.log("active/standby swap activeIndex=\(activeEngineIndex ?? -1)")
        crossfadeMutationLock.unlock()
        emitStateIfNeeded()
        refreshNowPlaying()
        scheduleEndObserver()
        schedulePostCrossfadeStandbyMaintenance(afterCrossfadeDurationMs: context.durationMs)
    }

    private func schedulePostCrossfadeStandbyMaintenance(afterCrossfadeDurationMs crossfadeDurationMs: Int) {
        crossfadeMutationLock.lock()
        cancelStandbyMaintenanceLocked()
        guard playWhenReady, state == .playingSingle, nextIndex(after: currentIndex) != nil else {
            crossfadeMutationLock.unlock()
            return
        }

        let currentRunId = runId
        standbyMaintenanceGeneration += 1
        let currentMaintenanceGeneration = standbyMaintenanceGeneration
        let activeDuration = duration
        let activePosition = currentTime
        let preloadLeadSeconds = 8.0
        let settleSeconds = 1.5
        let crossfadeSeconds = max(0.001, Double(crossfadeDurationMs) / 1000)
        let targetPreloadPosition = activeDuration > 0
            ? max(activePosition + settleSeconds, activeDuration - crossfadeSeconds - preloadLeadSeconds)
            : activePosition + settleSeconds
        let delaySeconds = max(settleSeconds, targetPreloadPosition - activePosition)

        IOSPlaybackLog.log("post-crossfade standby maintenance scheduled delay=\(delaySeconds)")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.crossfadeMutationLock.lock()
            guard self.runId == currentRunId,
                  self.standbyMaintenanceGeneration == currentMaintenanceGeneration else {
                self.crossfadeMutationLock.unlock()
                return
            }
            self.standbyMaintenanceWorkItem = nil
            guard self.playWhenReady,
                  self.state == .playingSingle,
                  !self.crossfadeCommandSlot.isOccupied,
                  self.preparedToIndex == nil else {
                self.crossfadeMutationLock.unlock()
                return
            }
            self.standbyMaintenanceAfterValidationHook()
            self.standbyEngine.reset()
            self.standbyEngineIndex = nil
            let didStart = self.preloadNextIfPossibleLocked()
            self.crossfadeMutationLock.unlock()
            if didStart { self.emitStateIfNeeded() }
        }
        standbyMaintenanceWorkItem = workItem
        crossfadeMutationLock.unlock()
        standbyMaintenanceScheduler(delaySeconds, workItem)
    }

    private func fallbackToTargetAfterStalledCrossfade(
        context: IOSCrossfadeContext,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        crossfadeMutationLock.lock()
        guard runId == context.runId,
              state == .crossfading,
              crossfadeContext === context else {
            crossfadeMutationLock.unlock()
            return
        }
        let incomingNow = standbyEngine.currentTime
        let outgoingVolume = activeEngine.volume
        let incomingVolume = standbyEngine.volume
        crossfadeWorkItem?.cancel()
        crossfadeWorkItem = nil
        crossfadeContext = nil
        standbyEngine.pause()
        standbyEngine.reset()
        crossfadeEventGeneration &+= 1
        enqueueCrossfadeEventLocked(
            "error",
            fromIndex: context.fromIndex,
            toIndex: context.toIndex,
            elapsedMs: context.elapsedMs,
            fromVolume: outgoingVolume,
            toVolume: incomingVolume,
            errorCode: "incoming_stalled"
        )
        crossfadeMutationLock.unlock()
        IOSPlaybackLog.log("crossfade incoming stalled from=\(context.fromIndex) to=\(context.toIndex) incomingStart=\(context.incomingStartTime) incomingNow=\(incomingNow)")
        skip(to: context.toIndex, initialTime: 0, completion: completion)
    }

    private func resumeCrossfadeRamp() {
        guard let context = crossfadeContext else { return }
        runCrossfadeRamp(context: context) { _ in }
    }

    private func promoteLogicalEngineAfterCrossfadeCancellation(errorCode: String) {
        crossfadeMutationLock.lock()
        guard let context = crossfadeContext,
              state == .crossfading || state == .pausedDuringCrossfade else {
            crossfadeMutationLock.unlock()
            return
        }
        let cancellationElapsedMs = context.elapsedMs
        let cancellationFromVolume = activeEngine.volume
        let cancellationToVolume = standbyEngine.volume
        IOSPlaybackLog.log("crossfade cancel promote logical engine currentIndex=\(currentIndex)")
        crossfadeWorkItem?.cancel()
        crossfadeWorkItem = nil
        activeEngine.pause()
        activeEngine.reset()
        let outgoingEngine = activeEngine
        activeEngine = standbyEngine
        standbyEngine = outgoingEngine
        volume = context.targetVolume
        activeEngine.setVolume(context.targetVolume)
        currentIndex = context.toIndex
        activeEngineIndex = currentIndex
        standbyEngineIndex = nil
        checkpoint(position: activeEngine.currentTime, reason: "crossfade_cancel")
        crossfadeContext = nil
        state = playWhenReady ? .playingSingle : .paused
        crossfadeEventGeneration &+= 1
        enqueueCrossfadeEventLocked(
            "cancelled",
            fromIndex: context.fromIndex,
            toIndex: context.toIndex,
            elapsedMs: cancellationElapsedMs,
            fromVolume: cancellationFromVolume,
            toVolume: cancellationToVolume,
            errorCode: errorCode
        )
        crossfadeMutationLock.unlock()
    }

    private func prepareStandby(
        index: Int,
        position: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        crossfadeMutationLock.lock()
        let failure = enqueueStandbyPreparationLocked(
            index: index,
            position: position,
            completion: completion
        )
        crossfadeMutationLock.unlock()
        if let failure { completion(.failure(failure)) }
    }

    private func preloadNextIfPossible() {
        crossfadeMutationLock.lock()
        let didStart = preloadNextIfPossibleLocked()
        crossfadeMutationLock.unlock()
        if didStart { emitStateIfNeeded() }
    }

    @discardableResult
    private func preloadNextIfPossibleLocked() -> Bool {
        guard let next = nextIndex(after: currentIndex) else { return false }
        guard state == .playingSingle else { return false }
        guard canUseTrackForCrossfade(index: currentIndex), canUseTrackForCrossfade(index: next) else { return false }
        state = .preloadingNext
        let failure = enqueueStandbyPreparationLocked(index: next, position: 0) { [weak self] result in
            guard let self = self else { return }
            self.crossfadeMutationLock.lock()
            var logMessage: String?
            switch result {
            case .success:
                logMessage = "standby preload ready index=\(next)"
            case .failure(let error):
                if !self.isStandbyPreparationSuperseded(error) {
                    logMessage = "standby preload failed index=\(next) error=\(error.localizedDescription)"
                    self.standbyEngineIndex = nil
                }
            }
            let shouldEmit = self.state == .preloadingNext &&
                !self.isStandbyPreparationSupersededResult(result)
            if self.state == .preloadingNext {
                if shouldEmit {
                    self.state = self.playWhenReady ? .playingSingle : .paused
                }
            }
            self.crossfadeMutationLock.unlock()
            if let logMessage { IOSPlaybackLog.log(logMessage) }
            if shouldEmit { self.emitStateIfNeeded() }
        }
        if let failure {
            state = playWhenReady ? .playingSingle : .paused
            IOSPlaybackLog.log("standby preload rejected index=\(next) error=\(failure.localizedDescription)")
            return false
        }
        return true
    }

    private func enqueueStandbyPreparationLocked(
        index: Int,
        position: Double,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> Error? {
        guard queue.indices.contains(index) else {
            return makeError("index_out_of_bounds", "The track index is out of bounds.")
        }
        let track = queue[index]
        let engine = standbyEngine
        standbyPreparationGeneration += 1
        let preparationGeneration = standbyPreparationGeneration
        let supersededError = makeError(
            "standby_preparation_superseded",
            "Standby preparation was superseded by newer playback work."
        )
        let operation = standbyPrepareOperation
        IOSPlaybackLog.log("standby prepare reserved index=\(index) generation=\(preparationGeneration)")

        // Enqueue while the mutation lock is held. This preserves native invocation
        // order even though the operation and every terminal callback run unlocked.
        let terminalQueue = standbyPreparationInvocationQueue
        standbyPreparationInvocationQueue.async { [weak self] in
            guard let self else {
                completion(.failure(supersededError))
                return
            }
            self.standbyPreparationBeforeNativeInvocationHook()
            self.crossfadeMutationLock.lock()
            guard self.standbyPreparationGeneration == preparationGeneration,
                  self.standbyEngine === engine else {
                self.crossfadeMutationLock.unlock()
                completion(.failure(supersededError))
                return
            }
            let finish: (Result<Void, Error>) -> Void = { [weak self] result in
                // Always defer terminal processing. Test doubles may complete
                // synchronously while the native invocation still owns the lock.
                terminalQueue.async {
                    guard let self else {
                        completion(.failure(supersededError))
                        return
                    }
                    self.crossfadeMutationLock.lock()
                    let resolvedResult: Result<Void, Error>
                    if self.standbyPreparationGeneration != preparationGeneration ||
                        self.standbyEngine !== engine {
                        resolvedResult = .failure(supersededError)
                    } else {
                        switch result {
                        case .success:
                            self.standbyEngineIndex = index
                        case .failure:
                            self.standbyEngineIndex = nil
                        }
                        resolvedResult = result
                    }
                    self.crossfadeMutationLock.unlock()
                    completion(resolvedResult)
                }
            }
            // Explicit preparation often follows automatic preload. Replacing a
            // ready AVPlayerItem here can interrupt the other, audible engine.
            if self.standbyEngineIndex == index,
               engine.state == .ready, engine.isReady,
               engine.currentTime == position {
                finish(.success(()))
            } else {
                operation(engine, track, position, finish)
            }
            self.crossfadeMutationLock.unlock()
        }
        return nil
    }

    private func isStandbyPreparationSupersededResult(
        _ result: Result<Void, Error>
    ) -> Bool {
        guard case .failure(let error) = result else { return false }
        return isStandbyPreparationSuperseded(error)
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

    private func stabilizeCancelledOperation() {
        runId += 1
        pendingRecoveryPosition = nil
        guard state == .loading || state == .seeking || state == .skipping else { return }
        resetEngines()
        playWhenReady = false
        state = hasCurrentItem ? .paused : .idle
        emitStateIfNeeded()
        refreshNowPlaying()
    }

    private func cancelAllWork() {
        crossfadeMutationLock.lock()
        runId += 1
        standbyPreparationGeneration += 1
        crossfadeWorkItem?.cancel()
        crossfadeWorkItem = nil
        scheduledStartWorkItem?.cancel()
        scheduledStartWorkItem = nil
        endObserverWorkItem?.cancel()
        endObserverWorkItem = nil
        cancelStandbyMaintenanceLocked()
        crossfadeContext = nil
        preparedFromIndex = nil
        preparedToIndex = nil
        preparedSeekTo = 0
        crossfadeMutationLock.unlock()
    }

    private func checkpoint(reason: String) {
        guard hasCurrentItem else { return }
        checkpoint(position: currentTime, reason: reason)
    }

    private func checkpoint(position: Double, reason: String) {
        guard hasCurrentItem else { return }
        let safePosition = max(0, position.isFinite ? position : 0)
        if safePosition == 0,
           let existing = checkpointForCurrentIndex(),
           existing.position > 0,
           state == .loading || state == .seeking || state == .skipping {
            IOSPlaybackLog.log("checkpoint skip transient zero reason=\(reason) index=\(currentIndex) existing=\(existing.position)")
            return
        }
        let safeDuration = max(0, duration.isFinite ? duration : 0)
        let checkpoint = PlaybackCheckpoint(
            version: 1,
            updatedAt: Date().timeIntervalSince1970,
            queueHash: queueHash(),
            currentIndex: currentIndex,
            position: safePosition,
            duration: safeDuration,
            playWhenReady: playWhenReady,
            state: playbackState.rawValue
        )
        checkpointStore.save(checkpoint)
        IOSPlaybackLog.log("checkpoint reason=\(reason) index=\(currentIndex) position=\(safePosition) duration=\(safeDuration)")
    }

    private func resumePositionForCurrentIndex() -> Double {
        guard let checkpoint = checkpointForCurrentIndex() else {
            return max(0, currentTime)
        }
        return max(checkpoint.position, currentTime)
    }

    private func checkpointForCurrentIndex() -> PlaybackCheckpoint? {
        guard hasCurrentItem else { return nil }
        return checkpointStore.load(queueHash: queueHash(), currentIndex: currentIndex)
    }

    private func recoverCurrentItem(
        position: Double,
        reason: String,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        guard queue.indices.contains(currentIndex) else {
            completion?(.failure(makeError("empty_queue", "No track is available to play.")))
            return
        }
        IOSPlaybackLog.log("recover current reason=\(reason) index=\(currentIndex) position=\(position)")
        cancelScheduledPlaybackWork()
        pendingRecoveryPosition = max(0, position)
        loadIndex(currentIndex, position: max(0, position), autoPlay: true, completion: completion)
    }

    private func cancelScheduledPlaybackWork() {
        crossfadeMutationLock.lock()
        runId += 1
        standbyPreparationGeneration += 1
        crossfadeWorkItem?.cancel()
        crossfadeWorkItem = nil
        scheduledStartWorkItem?.cancel()
        scheduledStartWorkItem = nil
        endObserverWorkItem?.cancel()
        endObserverWorkItem = nil
        cancelStandbyMaintenanceLocked()
        crossfadeContext = nil
        preparedFromIndex = nil
        preparedToIndex = nil
        preparedSeekTo = 0
        pendingRecoveryPosition = nil
        standbyEngine.pause()
        standbyEngine.reset()
        standbyEngineIndex = nil
        crossfadeMutationLock.unlock()
    }

    private func cancelStandbyMaintenance() {
        crossfadeMutationLock.lock()
        cancelStandbyMaintenanceLocked()
        crossfadeMutationLock.unlock()
    }

    private func cancelStandbyMaintenanceLocked() {
        standbyMaintenanceGeneration += 1
        standbyMaintenanceWorkItem?.cancel()
        standbyMaintenanceWorkItem = nil
    }

    private func isStandbyPreparationSuperseded(_ error: Error) -> Bool {
        return (error as NSError).userInfo["code"] as? String ==
            "standby_preparation_superseded"
    }

    private func cancelActiveCrossfade(errorCode: String) {
        let error = makeError(
            "crossfade_cancelled",
            "Crossfade was cancelled by \(errorCode)."
        )
        crossfadeMutationLock.lock()
        let scheduled = scheduledCrossfade
        var didClaimScheduled = false
        if let scheduled {
            if let terminalResolver = crossfadeCommandSlot.takeResolver(
                scheduled.completionGate,
                result: .failure(error)
            ) {
                didClaimScheduled = true
                runId += 1
                scheduledCrossfade = nil
                scheduledStartWorkItem?.cancel()
                scheduledStartWorkItem = nil
                crossfadeEventGeneration &+= 1
                enqueueCrossfadeEventLocked(
                    "cancelled",
                    fromIndex: scheduled.fromIndex,
                    toIndex: scheduled.toIndex,
                    elapsedMs: 0,
                    fromVolume: scheduled.fromVolume,
                    toVolume: 0,
                    errorCode: errorCode,
                    afterDelivery: terminalResolver
                )
            }
        } else {
            let terminalResolver = crossfadeCommandSlot.takeCurrentResolver(
                result: .failure(error)
            )
            if let terminalResolver {
                crossfadeEventDeliveryQueue.async(execute: terminalResolver)
            }
        }
        crossfadeMutationLock.unlock()
        if didClaimScheduled {
            scheduledCrossfadeCancellationAfterClaimHook()
        }
    }

    private func queueHash() -> String {
        let raw = queue.map { track in
            "\(track.getSourceUrl())#\(track.duration ?? 0)"
        }.joined(separator: "|")
        var hash: UInt64 = 1469598103934665603
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private func emitCrossfadeCancellationIfNeeded(errorCode: String) {
        crossfadeMutationLock.lock()
        guard let context = crossfadeContext else {
            crossfadeMutationLock.unlock()
            return
        }
        crossfadeEventGeneration &+= 1
        enqueueCrossfadeEventLocked(
            "cancelled",
            fromIndex: context.fromIndex,
            toIndex: context.toIndex,
            elapsedMs: context.elapsedMs,
            fromVolume: activeEngine.volume,
            toVolume: standbyEngine.volume,
            errorCode: errorCode
        )
        crossfadeMutationLock.unlock()
    }

    private func resetEngines() {
        crossfadeMutationLock.lock()
        resetEnginesLocked()
        crossfadeMutationLock.unlock()
    }

    private func resetEnginesLocked() {
        standbyPreparationGeneration += 1
        activeEngine.reset()
        standbyEngine.reset()
        activeEngine = engineA
        standbyEngine = engineB
        activeEngineIndex = nil
        standbyEngineIndex = nil
    }

    private func enqueueCrossfadeEventLocked(
        _ eventState: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int? = nil,
        fromVolume: Float? = nil,
        toVolume: Float? = nil,
        errorCode: String? = nil,
        admissionGeneration: UInt64? = nil,
        beforeDelivery: @escaping () -> Void = {},
        afterDelivery: @escaping () -> Void = {}
    ) {
        crossfadeEventDeliveryQueue.async { [weak self] in
            guard let self else {
                afterDelivery()
                return
            }
            self.crossfadeMutationLock.lock()
            let isAdmitted = admissionGeneration.map {
                self.crossfadeEventGeneration == $0
            } ?? true
            self.crossfadeMutationLock.unlock()
            guard isAdmitted else { return }
            beforeDelivery()
            self.emitCrossfadeState(
                eventState,
                fromIndex: fromIndex,
                toIndex: toIndex,
                elapsedMs: elapsedMs,
                fromVolume: fromVolume,
                toVolume: toVolume,
                errorCode: errorCode
            )
            afterDelivery()
        }
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
        IOSPlaybackLog.log("nowPlaying update index=\(currentIndex) position=\(currentTime) rate=\(nowPlayingPlaybackRate)")
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
