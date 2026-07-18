//
//  RNTrackPlayer.swift
//  RNTrackPlayer
//
//  Created by David Chavez on 13.08.17.
//  Copyright © 2017 David Chavez. All rights reserved.
//

import Foundation
import MediaPlayer
import QuartzCore
import SwiftAudioEx

func orchestratedActiveTrackEventBody(
    index: Int?,
    lastIndex: Int?,
    lastTrack: Track?,
    lastPosition: Double,
    queue: [Track]
) -> [String: Any] {
    var body: [String: Any] = ["lastPosition": lastPosition]
    if let lastIndex = lastIndex {
        body["lastIndex"] = lastIndex
    }
    if let lastTrack = lastTrack?.toObject() {
        body["lastTrack"] = lastTrack
    }
    if let index = index {
        body["index"] = index
        if queue.indices.contains(index) {
            body["track"] = queue[index].toObject()
        }
    }
    return body
}

private struct StandardActiveTrackEventKey: Equatable {
    let source: ObjectIdentifier
    let trackID: String?
    let index: Int?
}

private struct PendingStandardIdleTrackActivation {
    let source: ObjectIdentifier
    var emittedByPhysicalPlayer: Bool
}

@objc(RNTrackPlayer)
public class RNTrackPlayer: RCTEventEmitter, AudioSessionControllerDelegate, IOSPlaybackOrchestratorDelegate {

    // MARK: - Attributes

    private var hasInitialized = false
    private var setupInProgress = false
    private var player = QueuedAudioPlayer()
    private var playbackOrchestrator = IOSPlaybackOrchestrator()
    private let playbackBackendAuthority = PlaybackBackendAuthority()
    private let playerEventTokensLock = NSLock()
    private var playerEventTokens: [ObjectIdentifier: PlaybackBackendEventToken] = [:]
    private let transitionGenerationSidecar = PlaybackTransitionGenerationSidecar()
    private var playbackBackendFacade: PlaybackBackendFacade? = nil
    private let audioSessionController = AudioSessionController.shared
    private var shouldEmitProgressEvent: Bool = false
    private var progressUpdateInterval: Double = 0
    private var orchestratedProgressWorkItem: DispatchWorkItem? = nil
    private var shouldResumePlaybackAfterInterruptionEnds: Bool = false
    private var crossfadeEnabled: Bool = false
    private var autoUpdateNowPlayingInfo: Bool = true
    private var forwardJumpInterval: NSNumber? = nil;
    private var backwardJumpInterval: NSNumber? = nil;
    private var configuredCapabilityValues: Set<String> = []
    private var configuredRemoteCommands: [RemoteCommand] = []
    private var pendingStandardIdleTrackActivation: PendingStandardIdleTrackActivation? = nil
    private var standardIdleActivationDuplicateGuard: StandardActiveTrackEventKey? = nil
    private var sessionCategory: AVAudioSession.Category = .playback
    private var sessionCategoryMode: AVAudioSession.Mode = .default
    private var sessionCategoryPolicy: AVAudioSession.RouteSharingPolicy = .default
    private var sessionCategoryOptions: AVAudioSession.CategoryOptions = []

    // MARK: - Lifecycle Methods

    public override init() {
        super.init()
        EventEmitter.shared.register(eventEmitter: self)
        audioSessionController.delegate = self
        configureSystemLifecycleEvents()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        reset(resolve: { _ in }, reject: { _, _, _  in })
    }

    private func configurePlayerEvents(_ source: QueuedAudioPlayer) {
        let identity = ObjectIdentifier(source)
        let token = PlaybackBackendEventToken()
        playerEventTokensLock.lock()
        guard playerEventTokens[identity] == nil else {
            playerEventTokensLock.unlock()
            return
        }
        playerEventTokens[identity] = token
        playerEventTokensLock.unlock()

        source.event.receiveChapterMetadata.addListener(self) { [weak self, weak source, token] metadata in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handleAudioPlayerChapterMetadataReceived(source: source, metadata: metadata)
        }
        source.event.receiveTimedMetadata.addListener(self) { [weak self, weak source, token] metadata in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handleAudioPlayerTimedMetadataReceived(source: source, metadata: metadata)
        }
        source.event.receiveCommonMetadata.addListener(self) { [weak self, weak source, token] metadata in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handleAudioPlayerCommonMetadataReceived(source: source, metadata: metadata)
        }
        source.event.stateChange.addListener(self) { [weak self, weak source, token] state in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handleAudioPlayerStateChange(source: source, state: state)
        }
        source.event.fail.addListener(self) { [weak self, weak source, token] error in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handleAudioPlayerFailed(source: source, error: error)
        }
        source.event.currentItem.addListener(self) { [weak self, weak source, token] data in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handleAudioPlayerCurrentItemChange(
                source: source,
                item: data.item,
                index: data.index,
                lastItem: data.lastItem,
                lastIndex: data.lastIndex,
                lastPosition: data.lastPosition
            )
        }
        source.event.secondElapse.addListener(self) { [weak self, weak source, token] seconds in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handleAudioPlayerSecondElapse(source: source, seconds: seconds)
        }
        source.event.playWhenReadyChange.addListener(self) { [weak self, weak source, token] playWhenReady in
            guard token.acceptsDelivery else { return }
            guard let source = source else { return }
            guard let self = self else { return }
            self.handlePlayWhenReadyChange(source: source, playWhenReady: playWhenReady)
        }
        token.activate()
    }

    private func removePlayerEvents(_ source: QueuedAudioPlayer) {
        playerEventTokensLock.lock()
        let token = playerEventTokens.removeValue(forKey: ObjectIdentifier(source))
        token?.invalidate()
        playerEventTokensLock.unlock()

        source.event.receiveChapterMetadata.removeListener(self)
        source.event.receiveTimedMetadata.removeListener(self)
        source.event.receiveCommonMetadata.removeListener(self)
        source.event.stateChange.removeListener(self)
        source.event.fail.removeListener(self)
        source.event.currentItem.removeListener(self)
        source.event.secondElapse.removeListener(self)
        source.event.playWhenReadyChange.removeListener(self)
    }

    private func configureSystemLifecycleEvents() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleApplicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleApplicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleApplicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        center.addObserver(
            self,
            selector: #selector(handleAudioSessionMediaServicesWereReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleApplicationWillResignActive() {
        checkpointOrchestratorForSystemEvent("willResignActive")
    }

    @objc private func handleApplicationDidEnterBackground() {
        checkpointOrchestratorForSystemEvent("didEnterBackground")
    }

    @objc private func handleApplicationWillEnterForeground() {
        checkpointOrchestratorForSystemEvent("willEnterForeground")
    }

    @objc private func handleApplicationDidBecomeActive() {
        checkpointOrchestratorForSystemEvent("didBecomeActive")
    }

    @objc private func handleAudioSessionInterruption(notification: Notification) {
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let reason = rawType.flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .ended
            ? "audioInterruptionEnded"
            : "audioInterruptionBegan"
        checkpointOrchestratorForSystemEvent(reason)
    }

    @objc private func handleAudioSessionRouteChange(notification: Notification) {
        checkpointOrchestratorForSystemEvent("audioRouteChange")
    }

    @objc private func handleAudioSessionMediaServicesWereReset() {
        checkpointOrchestratorForSystemEvent("mediaServicesWereReset")
    }

    private func checkpointOrchestratorForSystemEvent(_ reason: String) {
        guard useOrchestratedCrossfade else { return }
        IOSPlaybackLog.log("system event \(reason)")
        playbackOrchestrator.checkpointForSystemEvent(reason)
    }

    // MARK: - RCTEventEmitter

    override public static func requiresMainQueueSetup() -> Bool {
        return true;
    }

    @objc(constantsToExport)
    override public func constantsToExport() -> [AnyHashable: Any] {
        return [
            "STATE_NONE": State.none.rawValue,
            "STATE_READY": State.ready.rawValue,
            "STATE_PLAYING": State.playing.rawValue,
            "STATE_PAUSED": State.paused.rawValue,
            "STATE_STOPPED": State.stopped.rawValue,
            "STATE_BUFFERING": State.buffering.rawValue,
            "STATE_LOADING": State.loading.rawValue,
            "STATE_ERROR": State.error.rawValue,

            "TRACK_PLAYBACK_ENDED_REASON_END": PlaybackEndedReason.playedUntilEnd.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_JUMPED": PlaybackEndedReason.jumpedToIndex.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_NEXT": PlaybackEndedReason.skippedToNext.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_PREVIOUS": PlaybackEndedReason.skippedToPrevious.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_STOPPED": PlaybackEndedReason.playerStopped.rawValue,

            "PITCH_ALGORITHM_LINEAR": PitchAlgorithm.linear.rawValue,
            "PITCH_ALGORITHM_MUSIC": PitchAlgorithm.music.rawValue,
            "PITCH_ALGORITHM_VOICE": PitchAlgorithm.voice.rawValue,

            "CAPABILITY_PLAY": Capability.play.rawValue,
            "CAPABILITY_PLAY_FROM_ID": "NOOP",
            "CAPABILITY_PLAY_FROM_SEARCH": "NOOP",
            "CAPABILITY_PAUSE": Capability.pause.rawValue,
            "CAPABILITY_STOP": Capability.stop.rawValue,
            "CAPABILITY_SEEK_TO": Capability.seek.rawValue,
            "CAPABILITY_SKIP": "NOOP",
            "CAPABILITY_SKIP_TO_NEXT": Capability.next.rawValue,
            "CAPABILITY_SKIP_TO_PREVIOUS": Capability.previous.rawValue,
            "CAPABILITY_SET_RATING": "NOOP",
            "CAPABILITY_JUMP_FORWARD": Capability.jumpForward.rawValue,
            "CAPABILITY_JUMP_BACKWARD": Capability.jumpBackward.rawValue,
            "CAPABILITY_LIKE": Capability.like.rawValue,
            "CAPABILITY_DISLIKE": Capability.dislike.rawValue,
            "CAPABILITY_BOOKMARK": Capability.bookmark.rawValue,

            "REPEAT_OFF": RepeatMode.off.rawValue,
            "REPEAT_TRACK": RepeatMode.track.rawValue,
            "REPEAT_QUEUE": RepeatMode.queue.rawValue,
        ]
    }

    @objc(supportedEvents)
    override public func supportedEvents() -> [String] {
        return EventType.allRawValues()
    }

    private func emit(event: EventType, body: Any? = nil) {
        EventEmitter.shared.emit(event: event, body: body)
    }

    // MARK: - AudioSessionControllerDelegate

    public func handleInterruption(type: InterruptionType) {
        switch type {
        case .began:
            // Interruption began, take appropriate actions (save state, update user interface)
            emit(event: EventType.RemoteDuck, body: [
                "paused": true
            ])
        case let .ended(shouldResume):
            if shouldResume {
                if (shouldResumePlaybackAfterInterruptionEnds) {
                    withActivePlaybackBackendSerialized({ try $0.play() }) { _ in }
                }
                // Interruption Ended - playback should resume
                emit(event: EventType.RemoteDuck, body: [
                    "paused": false
                ])
            } else {
                // Interruption Ended - playback should NOT resume
                emit(event: EventType.RemoteDuck, body: [
                    "paused": true,
                    "permanent": true
                ])
            }
        }
    }

    // MARK: - Bridged Methods

    private func rejectWhenNotInitialized(reject: RCTPromiseRejectBlock) -> Bool {
        let rejected = !hasInitialized;
        if (rejected) {
            reject("player_not_initialized", "The player is not initialized. Call setupPlayer first.", nil)
        }
        return rejected;
    }

    private func rejectWhenTrackIndexOutOfBounds(
        index: Int,
        min: Int? = nil,
        max : Int? = nil,
        message : String? = "The track index is out of bounds",
        reject: RCTPromiseRejectBlock
    ) -> Bool {
        let queueSize = hasInitialized ? activePlaybackBackend.queue.count : player.items.count
        let rejected = index < (min ?? 0) || index > (max ?? queueSize - 1);
        if (rejected) {
            reject("index_out_of_bounds", message, nil)
        }
        return rejected
    }

    private var useOrchestratedCrossfade: Bool {
        return playbackBackendAuthority.isAuthoritative(.pingPong, identity: playbackOrchestrator)
    }

    private func playerTracks() -> [Track] {
        return player.items.compactMap { $0 as? Track }
    }

    private var activePlaybackBackend: IOSPlaybackBackendRouting {
        guard let backend = playbackBackendFacade?.currentBackend as? IOSPlaybackBackendRouting else {
            fatalError("Playback backend is not initialized. Call setupPlayer first.")
        }
        return backend
    }

    private func withActivePlaybackBackendAsync<Value>(
        _ operation: @escaping (
            IOSPlaybackBackendRouting,
            @escaping (Result<Value, Error>) -> Void
        ) throws -> Void,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        playbackBackendFacade!.withCurrentBackendAsync({ backend, routedCompletion in
            try operation(backend as! IOSPlaybackBackendRouting, routedCompletion)
        }, completion: completion)
    }

    private func withActivePlaybackBackendSerialized<Value>(
        _ operation: @escaping (IOSPlaybackBackendRouting) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        withActivePlaybackBackendAsync({ backend, routedCompletion in
            do {
                routedCompletion(.success(try operation(backend)))
            } catch {
                routedCompletion(.failure(error))
            }
        }, completion: completion)
    }

    private func withActivePlaybackBackendRead<Value>(
        _ operation: @escaping (IOSPlaybackBackendRouting) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        playbackBackendFacade!.withCurrentBackendRead({ backend in
            try operation(backend as! IOSPlaybackBackendRouting)
        }, completion: completion)
    }

    private func resolveActivePlaybackBackendRead<Value>(
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock,
        message: String,
        _ operation: @escaping (IOSPlaybackBackendRouting) throws -> Value
    ) {
        withActivePlaybackBackendRead(operation) { result in
            switch result {
            case .success(let value): resolve(value)
            case .failure(let error): reject("playback_read_failed", message, error)
            }
        }
    }

    private func makePlaybackBackend(
        _ kind: PlaybackBackendKind,
        initiallyAuthoritative: Bool = false
    ) -> PlaybackBackend {
        switch kind {
        case .standard:
            let incomingQueueProvider: (() -> [Track])?
            if initiallyAuthoritative {
                incomingQueueProvider = nil
            } else {
                incomingQueueProvider = { [weak self] in self?.playerTracks() ?? [] }
            }
            let source = initiallyAuthoritative ? player : makeStandardPlayerCandidate()
            return StandardPlaybackBackend(
                player: source,
                transitionGenerationSidecar: transitionGenerationSidecar,
                automaticallyUpdateNowPlayingInfo: { [weak self] in
                    self?.autoUpdateNowPlayingInfo ?? true
                },
                onCommitted: { [weak self] committed in
                    self?.commitStandardPlayer(committed)
                },
                onActivated: { [weak self] committed in
                    self?.publishCanonicalStandardState(committed)
                },
                onDisposed: { [weak self] disposed in
                    self?.removePlayerEvents(disposed)
                },
                onIdleTrackActivationWillBegin: { [weak self] source in
                    self?.beginStandardIdleTrackActivation(source: source)
                },
                onIdleTrackActivated: { [weak self] source, index in
                    self?.finishStandardIdleTrackActivation(source: source, index: index)
                },
                initiallyAuthoritative: initiallyAuthoritative,
                incomingQueueProvider: incomingQueueProvider,
                queueProvider: { [weak source] in
                    return source?.items.compactMap { $0 as? Track } ?? []
                })
        case .pingPong:
            let queuePlayer = player
            let orchestrator = IOSPlaybackOrchestrator()
            return PingPongPlaybackBackend(
                player: queuePlayer,
                orchestrator: orchestrator,
                transitionGenerationSidecar: transitionGenerationSidecar,
                onCommitted: { [weak self] committed, queuePlayer in
                    self?.commitPingPongOrchestrator(committed, queuePlayer: queuePlayer)
                },
                onActivated: { [weak self] committed in
                    self?.publishCanonicalPingPongState(committed)
                },
                onDisposed: { [weak self] disposed, _ in
                    disposed.delegate = nil
                    if self?.playbackOrchestrator === disposed {
                        self?.stopOrchestratedProgressUpdates()
                    }
                },
                initiallyAuthoritative: initiallyAuthoritative,
                queueProvider: { [weak queuePlayer] in
                    queuePlayer?.items.compactMap { $0 as? Track } ?? []
                }
            )
        }
    }

    private func makeStandardPlayerCandidate() -> QueuedAudioPlayer {
        let candidate = QueuedAudioPlayer()
        candidate.automaticallyUpdateNowPlayingInfo = false
        candidate.playWhenReady = false
        candidate.bufferDuration = player.bufferDuration
        candidate.automaticallyWaitsToMinimizeStalling = player.automaticallyWaitsToMinimizeStalling
        candidate.timeEventFrequency = player.timeEventFrequency
        return candidate
    }

    private func performOnMainSync(_ operation: () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.sync(execute: operation)
        }
    }

    private func commitStandardPlayer(_ committed: QueuedAudioPlayer) {
        performOnMainSync {
            pendingStandardIdleTrackActivation = nil
            standardIdleActivationDuplicateGuard = nil
            player = committed
            configurePlayerEvents(committed)
            committed.automaticallyUpdateNowPlayingInfo = autoUpdateNowPlayingInfo
            configureRemoteCommandHandlers(committed, kind: .standard, identity: committed)
            committed.remoteCommands = configuredRemoteCommands
            if autoUpdateNowPlayingInfo {
                committed.loadNowPlayingMetaValues()
            }
            refreshRemoteCommandAvailability(kind: .standard, sourcePlayer: committed)
        }
    }

    private func commitPingPongOrchestrator(
        _ committed: IOSPlaybackOrchestrator,
        queuePlayer: QueuedAudioPlayer
    ) {
        performOnMainSync {
            player = queuePlayer
            playbackOrchestrator = committed
            committed.delegate = self
            queuePlayer.automaticallyUpdateNowPlayingInfo = false
            configureRemoteCommandHandlers(queuePlayer, kind: .pingPong, identity: committed)
            queuePlayer.remoteCommands = configuredRemoteCommands
            refreshRemoteCommandAvailability(
                kind: .pingPong,
                sourcePlayer: queuePlayer,
                sourceOrchestrator: committed
            )
            updateNowPlayingForOrchestrator(force: true)
        }
    }

    private func publishCanonicalStandardState(_ committed: QueuedAudioPlayer) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: committed),
              committed === player else { return }
        let backend = playbackBackendFacade?.currentBackend as? IOSPlaybackBackendRouting
        stopOrchestratedProgressUpdates()
        emit(
            event: EventType.PlaybackState,
            body: getPlaybackStateBodyKeyValues(
                state: backend?.playbackState ?? State.fromPlayerState(state: committed.playerState),
                error: backend?.publicPlaybackError
            )
        )
        configureAudioSession()
        emit(
            event: EventType.PlaybackPlayWhenReadyChanged,
            body: ["playWhenReady": backend?.publicPlayWhenReady ?? committed.playWhenReady]
        )
    }

    private func standardActiveTrackEventKey(
        source: QueuedAudioPlayer,
        item: AudioItem?,
        index: Int?
    ) -> StandardActiveTrackEventKey {
        return StandardActiveTrackEventKey(
            source: ObjectIdentifier(source),
            trackID: (item as? Track).map(playbackBackendTrackID),
            index: index
        )
    }

    private func beginStandardIdleTrackActivation(source: QueuedAudioPlayer) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source),
              source === player else { return }
        standardIdleActivationDuplicateGuard = nil
        pendingStandardIdleTrackActivation = PendingStandardIdleTrackActivation(
            source: ObjectIdentifier(source),
            emittedByPhysicalPlayer: false
        )
    }

    private func finishStandardIdleTrackActivation(source: QueuedAudioPlayer, index: Int?) {
        let sourceID = ObjectIdentifier(source)
        guard let pending = pendingStandardIdleTrackActivation,
              pending.source == sourceID else { return }
        pendingStandardIdleTrackActivation = nil
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source),
              source === player,
              let index = index,
              source.items.indices.contains(index),
              !pending.emittedByPhysicalPlayer else { return }
        let item = source.items[index]
        let key = standardActiveTrackEventKey(source: source, item: item, index: index)

        handleAudioPlayerCurrentItemChange(
            source: source,
            item: item,
            index: index,
            lastItem: nil,
            lastIndex: nil,
            lastPosition: 0
        )
        standardIdleActivationDuplicateGuard = key
        DispatchQueue.main.async { [weak self] in
            guard self?.standardIdleActivationDuplicateGuard == key else { return }
            self?.standardIdleActivationDuplicateGuard = nil
        }
    }

    private func publishCanonicalPingPongState(_ committed: IOSPlaybackOrchestrator) {
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: committed),
              committed === playbackOrchestrator else { return }
        emit(
            event: EventType.PlaybackState,
            body: getPlaybackStateBodyKeyValues(state: committed.playbackState)
        )
        configureAudioSession()
        emit(
            event: EventType.PlaybackPlayWhenReadyChanged,
            body: ["playWhenReady": committed.playWhenReady]
        )
        if committed.playbackState == .playing {
            startOrchestratedProgressUpdates()
        } else {
            stopOrchestratedProgressUpdates()
        }
        updateNowPlayingForOrchestrator(committed, force: true)
    }

    private func configureRemoteCommandHandlers(
        _ source: QueuedAudioPlayer,
        kind: PlaybackBackendKind,
        identity: AnyObject
    ) {
        let expectedIdentity = ObjectIdentifier(identity)
        func isAuthoritative() -> Bool {
            return playbackBackendAuthority.isAuthoritative(kind, identity: expectedIdentity)
        }

        source.remoteCommandController.handleChangePlaybackPositionCommand = { [weak self] event in
            guard let self = self, isAuthoritative(),
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.emit(event: .RemoteSeek, body: ["position": event.positionTime])
            return .success
        }
        source.remoteCommandController.handleNextTrackCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemoteNext)
            return .success
        }
        source.remoteCommandController.handlePauseCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemotePause)
            return .success
        }
        source.remoteCommandController.handlePlayCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemotePlay)
            return .success
        }
        source.remoteCommandController.handlePreviousTrackCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemotePrevious)
            return .success
        }
        source.remoteCommandController.handleSkipBackwardCommand = { [weak self] event in
            guard let self = self, isAuthoritative(),
                  let command = event.command as? MPSkipIntervalCommand,
                  let interval = command.preferredIntervals.first else {
                return .commandFailed
            }
            self.emit(event: .RemoteJumpBackward, body: ["interval": interval])
            return .success
        }
        source.remoteCommandController.handleSkipForwardCommand = { [weak self] event in
            guard let self = self, isAuthoritative(),
                  let command = event.command as? MPSkipIntervalCommand,
                  let interval = command.preferredIntervals.first else {
                return .commandFailed
            }
            self.emit(event: .RemoteJumpForward, body: ["interval": interval])
            return .success
        }
        source.remoteCommandController.handleStopCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemoteStop)
            return .success
        }
        source.remoteCommandController.handleTogglePlayPauseCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: self.activePlaybackBackend.playbackState == .paused ? .RemotePlay : .RemotePause)
            return .success
        }
        source.remoteCommandController.handleLikeCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemoteLike)
            return .success
        }
        source.remoteCommandController.handleDislikeCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemoteDislike)
            return .success
        }
        source.remoteCommandController.handleBookmarkCommand = { [weak self] _ in
            guard let self = self, isAuthoritative() else { return .commandFailed }
            self.emit(event: .RemoteBookmark)
            return .success
        }
    }

    private func installPlaybackBackendFacade(initialKind: PlaybackBackendKind) {
        let factory = IOSPlaybackBackendFactory { [weak self] kind in
            guard let self = self else {
                fatalError("RNTrackPlayer was released during playback backend creation.")
            }
            return self.makePlaybackBackend(kind)
        }
        playbackBackendFacade = PlaybackBackendFacade(
            initial: makePlaybackBackend(initialKind, initiallyAuthoritative: true),
            factory: factory,
            authority: playbackBackendAuthority,
            onCleanupDiagnostic: { [weak self] diagnostic in
                DispatchQueue.main.async {
                    self?.emit(event: EventType.PlaybackError, body: [
                        "code": diagnostic.code,
                        "message": diagnostic.message
                    ])
                }
            }
        )
    }

    private func activateAudioSessionForPlayback() {
        try? audioSessionController.activateSession()
        if #available(iOS 11.0, *) {
            try? AVAudioSession.sharedInstance().setCategory(
                sessionCategory,
                mode: sessionCategoryMode,
                policy: sessionCategoryPolicy,
                options: sessionCategoryOptions
            )
        } else {
            try? AVAudioSession.sharedInstance().setCategory(
                sessionCategory,
                mode: sessionCategoryMode,
                options: sessionCategoryOptions
            )
        }
    }

    @objc(setupPlayer:resolver:rejecter:)
    public func setupPlayer(config: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if hasInitialized {
            reject("player_already_initialized", "The player has already been initialized via setupPlayer.", nil)
            return
        }
        setupInProgress = true
        defer { setupInProgress = false }

        crossfadeEnabled = config["crossfade"] as? Bool ?? false
        let initialBackend: PlaybackBackendKind = crossfadeEnabled ? .pingPong : .standard
        installPlaybackBackendFacade(initialKind: initialBackend)

        // configure buffer size
        if let bufferDuration = config["minBuffer"] as? TimeInterval {
            player.bufferDuration = bufferDuration
        }

        if let autoHandleInterruptions = config["autoHandleInterruptions"] as? Bool {
            self.shouldResumePlaybackAfterInterruptionEnds = autoHandleInterruptions
        }

        // configure wether player waits to play (deprecated)
        if let waitForBuffer = config["waitForBuffer"] as? Bool {
            player.automaticallyWaitsToMinimizeStalling = waitForBuffer
        }

        // configure wether control center metdata should auto update
        autoUpdateNowPlayingInfo = config["autoUpdateMetadata"] as? Bool ?? true
        player.automaticallyUpdateNowPlayingInfo = useOrchestratedCrossfade
            ? false
            : autoUpdateNowPlayingInfo
        if useOrchestratedCrossfade {
            player.volume = 0
        }

        // configure audio session - category, options & mode
        if
            let sessionCategoryStr = config["iosCategory"] as? String,
            let mappedCategory = SessionCategory(rawValue: sessionCategoryStr) {
            sessionCategory = mappedCategory.mapConfigToAVAudioSessionCategory()
        }

        if
            let sessionCategoryModeStr = config["iosCategoryMode"] as? String,
            let mappedCategoryMode = SessionCategoryMode(rawValue: sessionCategoryModeStr) {
            sessionCategoryMode = mappedCategoryMode.mapConfigToAVAudioSessionCategoryMode()
        }

        if
            let sessionCategoryPolicyStr = config["iosCategoryPolicy"] as? String,
            let mappedCategoryPolicy = SessionCategoryPolicy(rawValue: sessionCategoryPolicyStr) {
            sessionCategoryPolicy = mappedCategoryPolicy.mapConfigToAVAudioSessionCategoryPolicy()
        }

        let sessionCategoryOptsStr = config["iosCategoryOptions"] as? [String]
        let mappedCategoryOpts = sessionCategoryOptsStr?.compactMap { SessionCategoryOptions(rawValue: $0)?.mapConfigToAVAudioSessionCategoryOptions() } ?? []
        sessionCategoryOptions = AVAudioSession.CategoryOptions(mappedCategoryOpts)

        configureAudioSession()

        hasInitialized = true
        resolve(NSNull())
    }


    private func configureAudioSession() {
        if useOrchestratedCrossfade {
            if playbackOrchestrator.currentIndex < 0 {
                try? audioSessionController.deactivateSession()
                return
            }
            if playbackOrchestrator.playWhenReady {
                activateAudioSessionForPlayback()
            }
            return
        }

        let routedBackend = playbackBackendFacade?.currentBackend as? IOSPlaybackBackendRouting
        let hasLogicalCurrentItem = routedBackend?.kind == .standard
            ? (routedBackend!.currentIndex >= 0)
            : (player.currentItem != nil)
        if !hasLogicalCurrentItem {
            try? audioSessionController.deactivateSession()
            return
        }
        
        // activate the audio session when there is an item to be played
        // and the player has been configured to start when it is ready loading:
        if (routedBackend?.publicPlayWhenReady ?? player.playWhenReady) {
            activateAudioSessionForPlayback()
        }
    }

    @objc(isServiceRunning:rejecter:)
    public func isServiceRunning(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(hasInitialized)
    }

    @objc(getPlayerLifecycle:rejecter:)
    public func getPlayerLifecycle(
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        guard hasInitialized else {
            resolve(playerLifecycleDictionary(backend: nil))
            return
        }
        withActivePlaybackBackendRead({ self.playerLifecycleDictionary(backend: $0) }) { result in
            switch result {
            case .success(let lifecycle): resolve(lifecycle)
            case .failure(let error): reject("playback_read_failed", "Unable to read player lifecycle.", error)
            }
        }
    }

    private func playerLifecycleDictionary(
        backend: IOSPlaybackBackendRouting?
    ) -> [String: Any] {
        let playbackState = backend?.playbackState ?? .none
        let activeIndex = backend?.currentIndex ?? -1
        let queueSize = backend?.queue.count ?? 0
        let normalizedActiveIndex: Any = activeIndex >= 0 && activeIndex < queueSize ? activeIndex : NSNull()
        let phase = setupInProgress ? "settingUp" : (hasInitialized ? "ready" : "uninitialized")
        let backendName = backend?.kind.rawValue ?? "none"
        let playWhenReady = backend?.publicPlayWhenReady ?? false

        return [
            "phase": phase,
            "serviceBound": hasInitialized,
            "playerInitialized": hasInitialized,
            "setupInProgress": setupInProgress,
            "canAcceptCommands": hasInitialized,
            "playbackState": playbackState.rawValue,
            "playWhenReady": playWhenReady,
            "backend": backendName,
            "queueSize": queueSize,
            "activeTrackIndex": normalizedActiveIndex
        ]
    }

    @objc(setPlaybackBackend:resolver:rejecter:)
    public func setPlaybackBackend(
        config: [String: Any],
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        guard let type = config["type"] as? String,
              let kind = PlaybackBackendKind(rawValue: type),
              Set(config.keys).isSubset(of: kind == .standard
                ? Set(["type"])
                : Set(["type", "engineMode"])),
              type != PlaybackBackendKind.pingPong.rawValue ||
                config["engineMode"] == nil ||
                config["engineMode"] as? String == "orchestratedDualEngine",
              let facade = playbackBackendFacade else {
            reject("invalid_playback_backend_config", "Invalid playback backend config.", nil)
            return
        }

        facade.setPlaybackBackend(kind) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    self.withActivePlaybackBackendRead({ self.playerLifecycleDictionary(backend: $0) }) {
                        switch $0 {
                        case .success(let lifecycle): resolve(lifecycle)
                        case .failure(let error):
                            reject("playback_read_failed", "Unable to read player lifecycle.", error)
                        }
                    }
                case .failure(let error):
                    reject("playback_backend_swap_failed", "Unable to change playback backend.", error)
                }
            }
        }
    }

    @objc(updateOptions:resolver:rejecter:)
    public func update(options: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        var capabilitiesStr = options["capabilities"] as? [String] ?? []
        if (capabilitiesStr.contains("play") && capabilitiesStr.contains("pause")) {
            capabilitiesStr.append("togglePlayPause");
        }

        forwardJumpInterval = options["forwardJumpInterval"] as? NSNumber ?? forwardJumpInterval
        backwardJumpInterval = options["backwardJumpInterval"] as? NSNumber ?? backwardJumpInterval

        let remoteCommands = capabilitiesStr
            .compactMap { Capability(rawValue: $0) }
            .map { capability in
                capability.mapToPlayerCommand(
                    forwardJumpInterval: forwardJumpInterval,
                    backwardJumpInterval: backwardJumpInterval,
                    likeOptions: options["likeOptions"] as? [String: Any],
                    dislikeOptions: options["dislikeOptions"] as? [String: Any],
                    bookmarkOptions: options["bookmarkOptions"] as? [String: Any]
                )
            }
        configuredCapabilityValues = Set(capabilitiesStr)
        configuredRemoteCommands = remoteCommands
        player.remoteCommands = remoteCommands
        refreshRemoteCommandAvailability()

        configureProgressUpdateEvent(
            interval: ((options["progressUpdateEventInterval"] as? NSNumber) ?? 0).doubleValue
        )

        resolve(NSNull())
    }

    private func configureProgressUpdateEvent(interval: Double) {
        shouldEmitProgressEvent = interval > 0
        progressUpdateInterval = interval
        self.player.timeEventFrequency = shouldEmitProgressEvent
            ? .custom(time: CMTime(seconds: interval, preferredTimescale: 1000))
            : .everySecond
        if useOrchestratedCrossfade {
            startOrchestratedProgressUpdates()
        }
    }

    private func refreshRemoteCommandAvailability(
        kind: PlaybackBackendKind? = nil,
        sourcePlayer: QueuedAudioPlayer? = nil,
        sourceOrchestrator: IOSPlaybackOrchestrator? = nil
    ) {
        let queuePlayer = sourcePlayer ?? player
        let orchestrator = sourceOrchestrator ?? playbackOrchestrator
        let backendKind = kind ?? (useOrchestratedCrossfade ? .pingPong : .standard)
        let routedBackend = playbackBackendFacade?.currentBackend as? IOSPlaybackBackendRouting
        let center = MPRemoteCommandCenter.shared()
        let logicalIndex = backendKind == .pingPong
            ? orchestrator.currentIndex
            : (routedBackend?.kind == .standard ? routedBackend!.currentIndex : queuePlayer.currentIndex)
        let hasCurrentItem = backendKind == .pingPong
            ? orchestrator.hasCurrentItem
            : logicalIndex >= 0

        center.nextTrackCommand.isEnabled = configuredCapabilityValues.contains(Capability.next.rawValue)
            && hasCurrentItem
            && logicalIndex >= 0
            && logicalIndex < queuePlayer.items.count - 1
        center.previousTrackCommand.isEnabled = configuredCapabilityValues.contains(Capability.previous.rawValue)
            && hasCurrentItem
            && logicalIndex > 0
    }

    private func startOrchestratedProgressUpdates() {
        orchestratedProgressWorkItem?.cancel()
        orchestratedProgressWorkItem = nil
        let owner = playbackOrchestrator
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: owner),
              owner.hasCurrentItem else { return }
        guard owner.playbackState == .playing else { return }

        let interval = shouldEmitProgressEvent ? max(0.25, progressUpdateInterval) : 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.playbackBackendAuthority.isAuthoritative(.pingPong, identity: owner),
                  self.playbackOrchestrator === owner else { return }
            self.emitOrchestratedProgress(owner)
            self.startOrchestratedProgressUpdates()
        }
        orchestratedProgressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func stopOrchestratedProgressUpdates() {
        orchestratedProgressWorkItem?.cancel()
        orchestratedProgressWorkItem = nil
    }

    private func emitOrchestratedProgress(_ orchestrator: IOSPlaybackOrchestrator) {
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: orchestrator),
              playbackOrchestrator === orchestrator,
              orchestrator.hasCurrentItem else { return }
        updateNowPlayingForOrchestrator(orchestrator)
        guard shouldEmitProgressEvent else { return }
        emit(
            event: EventType.PlaybackProgressUpdated,
            body: [
                "position": orchestrator.currentTime,
                "duration": orchestrator.duration,
                "buffered": orchestrator.bufferedPosition,
                "track": orchestrator.currentIndex,
            ]
        )
    }

    private func emitCrossfadeState(
        state: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int? = nil,
        fromVolume: Float? = nil,
        toVolume: Float? = nil,
        errorCode: String? = nil
    ) {
        var body: [String: Any] = [
            "state": state,
            "fromIndex": fromIndex,
            "toIndex": toIndex
        ]
        if let elapsedMs = elapsedMs {
            body["elapsedMs"] = elapsedMs
        }
        if let fromVolume = fromVolume {
            body["fromVolume"] = fromVolume
        }
        if let toVolume = toVolume {
            body["toVolume"] = toVolume
        }
        if let errorCode = errorCode {
            body["errorCode"] = errorCode
        }
        emit(event: EventType.PlaybackCrossfadeState, body: body)
    }

    private func publicPlaybackPosition() -> Double {
        return activePlaybackBackend.position
    }

    private func publicPlaybackDuration() -> Double {
        return activePlaybackBackend.duration
    }

    private func publicBufferedPosition() -> Double {
        return activePlaybackBackend.bufferedPosition
    }

    private func publicPlaybackVolume() -> Float {
        return activePlaybackBackend.publicVolume
    }

    private func crossfadePlaybackRate() -> Float {
        let rate = activePlaybackBackend.publicRate
        return rate.isFinite && rate > 0.01 ? rate : 1
    }

    @objc(add:before:resolver:rejecter:)
    public func add(
        trackDicts: [[String: Any]],
        before trackIndex: NSNumber,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        // -1 means no index was passed and therefore should be inserted at the end.
        let index = trackIndex.intValue == -1 ? activePlaybackBackend.queue.count : trackIndex.intValue;
        if (rejectWhenTrackIndexOutOfBounds(
            index: index,
            max: activePlaybackBackend.queue.count,
            reject: reject
        )) { return }

        var tracks = [Track]()
        for trackDict in trackDicts {
            guard let track = Track(dictionary: trackDict) else {
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }

            tracks.append(track)
        }

        withActivePlaybackBackendSerialized({ try $0.add(tracks, at: index) }) { result in
            switch result {
            case .success:
                resolve(index)
            case .failure(let error):
                reject("queue_add_failed", "Unable to add tracks to the playback backend.", error)
            }
        }
    }

    @objc(load:resolver:rejecter:)
    public func load(
        trackDict: [String: Any],
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        guard let track = Track(dictionary: trackDict) else {
            reject("invalid_track_object", "Track is missing a required key", nil)
            return
        }

        withActivePlaybackBackendAsync({ backend, completion in
            backend.load(track, completion: completion)
        }) { result in
            switch result {
            case .success(let index):
                resolve(index)
            case .failure(let error):
                reject("playback_backend_load_failed", "Unable to load the track.", error)
            }
        }
    }

    @objc(remove:resolver:rejecter:)
    public func remove(tracks indexes: [Int], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        for index in indexes {
            if (rejectWhenTrackIndexOutOfBounds(index: index, message: "One or more of the indexes were out of bounds.", reject: reject)) {
                return
            }
        }

        withActivePlaybackBackendSerialized({ try $0.remove(at: indexes) }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("queue_remove_failed", "Unable to remove tracks from the playback backend.", error)
            }
        }
    }

    @objc(move:toIndex:resolver:rejecter:)
    public func move(
        fromIndex: NSNumber,
        toIndex: NSNumber,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: fromIndex.intValue,
            message: "The fromIndex is out of bounds",
            reject: reject)
        ) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: toIndex.intValue,
            max: Int.max,
            message: "The toIndex is out of bounds",
            reject: reject)
        ) { return }
        withActivePlaybackBackendSerialized({
            try $0.move(from: fromIndex.intValue, to: toIndex.intValue)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("queue_move_failed", "Unable to move the track in the playback backend.", error)
            }
        }
    }


    @objc(removeUpcomingTracks:rejecter:)
    public func removeUpcomingTracks(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendSerialized({ $0.removeUpcomingTracks() }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error):
                reject("queue_remove_failed", "Unable to remove upcoming tracks.", error)
            }
        }
    }

    @objc(skip:initialTime:resolver:rejecter:)
    public func skip(
        to trackIndex: NSNumber,
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let index = trackIndex.intValue;
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(index: index, reject: reject)) { return }

        print("Skipping to track:", index)
        withActivePlaybackBackendAsync({ backend, completion in
            backend.skip(to: index, initialTime: initialTime, completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("skip_failed", "Unable to skip to track.", error)
            }
        }
    }

    @objc(skipToNext:resolver:rejecter:)
    public func skipToNext(
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendAsync({ backend, completion in
            backend.skipToNext(initialTime: initialTime, completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("skip_failed", "Unable to skip to next track.", error)
            }
        }
    }

    @objc(skipToPrevious:resolver:rejecter:)
    public func skipToPrevious(
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendAsync({ backend, completion in
            backend.skipToPrevious(initialTime: initialTime, completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("skip_failed", "Unable to skip to previous track.", error)
            }
        }
    }

    @objc(reset:rejecter:)
    public func reset(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendSerialized({ backend in
            backend.stop()
            backend.clearQueue()
        }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error): reject("reset_failed", "Unable to reset playback.", error)
            }
        }
    }

    @objc(play:rejecter:)
    public func play(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        withActivePlaybackBackendAsync({ backend, completion in
            backend.syncQueue(self.playerTracks())
            if backend.kind == .pingPong {
                self.activateAudioSessionForPlayback()
            }
            backend.play(completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("playback_failed", "Unable to start playback.", error)
            }
        }
    }

    @objc(pause:rejecter:)
    public func pause(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendSerialized({ $0.pause() }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error): reject("playback_failed", "Unable to pause playback.", error)
            }
        }
    }

    @objc(setPlayWhenReady:resolver:rejecter:)
    public func setPlayWhenReady(playWhenReady: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        withActivePlaybackBackendAsync({ backend, completion in
            backend.setPlayWhenReady(playWhenReady, completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("playback_failed", "Unable to update playWhenReady.", error)
            }
        }
    }

    @objc(getPlayWhenReady:rejecter:)
    public func getPlayWhenReady(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read playWhenReady."
        ) { $0.publicPlayWhenReady }
    }

    @objc(stop:rejecter:)
    public func stop(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendSerialized({ $0.stop() }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error): reject("playback_failed", "Unable to stop playback.", error)
            }
        }
    }

    @objc(seekTo:resolver:rejecter:)
    public func seekTo(time: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendAsync({ backend, completion in
            backend.seek(to: time, completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("seek_failed", "Unable to seek.", error)
            }
        }
    }

    @objc(seekBy:resolver:rejecter:)
    public func seekBy(offset: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendAsync({ backend, completion in
            backend.seek(by: offset, completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("seek_failed", "Unable to seek.", error)
            }
        }
    }

    @objc(retry:rejecter:)
    public func retry(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        withActivePlaybackBackendSerialized({ $0.retry() }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error): reject("retry_failed", "Unable to retry playback.", error)
            }
        }
    }

    @objc(setRepeatMode:resolver:rejecter:)
    public func setRepeatMode(repeatMode: NSNumber, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendSerialized({ $0.setRepeatMode(repeatMode.intValue) }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error): reject("repeat_mode_failed", "Unable to set repeat mode.", error)
            }
        }
    }

    @objc(getRepeatMode:rejecter:)
    public func getRepeatMode(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read repeat mode."
        ) { $0.publicRepeatMode }
    }

    @objc(setVolume:resolver:rejecter:)
    public func setVolume(level: Float, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendSerialized({ $0.setVolume(level) }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error): reject("volume_failed", "Unable to set volume.", error)
            }
        }
    }

    @objc(crossFadePrepare:seekTo:resolver:rejecter:)
    public func crossFadePrepare(
        previous: Bool,
        seekTo: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        withActivePlaybackBackendAsync({ backend, completion in
            guard backend.kind == .pingPong else {
                completion(.success(()))
                return
            }
            backend.prepareCrossfade(previous: previous, seekTo: seekTo, completion: completion)
        }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("crossfade_prepare_failed", "Unable to prepare the crossfade target.", error)
            }
        }
    }

    @objc(crossFade:fadeInterval:fadeToVolume:waitUntil:resolver:rejecter:)
    public func crossFade(
        fadeDuration: Double,
        fadeInterval: Double,
        fadeToVolume: Double,
        waitUntil: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        do {
            withActivePlaybackBackendAsync({ backend, completion in
                guard backend.kind == .pingPong else {
                    completion(.success(()))
                    return
                }
                backend.crossFade(
                    fadeDuration: fadeDuration,
                    fadeInterval: fadeInterval,
                    fadeToVolume: fadeToVolume,
                    waitUntil: waitUntil,
                    completion: completion
                )
            }) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("crossfade_failed", "Unable to complete crossfade.", error)
                }
            }
            return
        }

    }

    @objc(getVolume:rejecter:)
    public func getVolume(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read volume."
        ) { $0.publicVolume }
    }

    @objc(setRate:resolver:rejecter:)
    public func setRate(rate: Float, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        withActivePlaybackBackendSerialized({ $0.setRate(rate) }) { result in
            switch result {
            case .success: resolve(NSNull())
            case .failure(let error): reject("rate_failed", "Unable to set playback rate.", error)
            }
        }
    }

    @objc(getRate:rejecter:)
    public func getRate(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read playback rate."
        ) { $0.publicRate }
    }

    @objc(getTrack:resolver:rejecter:)
    public func getTrack(index: NSNumber, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read track."
        ) { backend -> Any in
            let queue = backend.queue
            return queue.indices.contains(index.intValue)
                ? queue[index.intValue].toObject()
                : NSNull()
        }
    }

    @objc(getQueue:rejecter:)
    public func getQueue(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read queue."
        ) { $0.queue.map { $0.toObject() } }
    }

    @objc(setQueue:resolver:rejecter:)
    public func setQueue(
        trackDicts: [[String: Any]],
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        var tracks = [Track]()
        for trackDict in trackDicts {
            guard let track = Track(dictionary: trackDict) else {
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }

            tracks.append(track)
        }
        withActivePlaybackBackendSerialized({ try $0.replaceQueue(tracks) }) { result in
            switch result {
            case .success:
                resolve(NSNull())
            case .failure(let error):
                reject("queue_replace_failed", "Unable to replace the playback backend queue.", error)
            }
        }
    }

    @objc(getActiveTrack:rejecter:)
    public func getActiveTrack(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read active track."
        ) { backend -> Any in
            let index = backend.currentIndex
            let queue = backend.queue
            return queue.indices.contains(index) ? queue[index].toObject() : NSNull()
        }
    }

    @objc(getActiveTrackIndex:rejecter:)
    public func getActiveTrackIndex(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(
            resolve: resolve,
            reject: reject,
            message: "Unable to read active track index."
        ) { backend -> Any in
            let index = backend.currentIndex
            return backend.queue.indices.contains(index) ? index : NSNull()
        }
    }

    @objc(getDuration:rejecter:)
    public func getDuration(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(resolve: resolve, reject: reject, message: "Unable to read duration.") {
            $0.duration
        }
    }

    @objc(getBufferedPosition:rejecter:)
    public func getBufferedPosition(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(resolve: resolve, reject: reject, message: "Unable to read buffered position.") {
            $0.bufferedPosition
        }
    }

    @objc(getPosition:rejecter:)
    public func getPosition(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(resolve: resolve, reject: reject, message: "Unable to read position.") {
            $0.position
        }
    }

    @objc(getProgress:rejecter:)
    public func getProgress(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(resolve: resolve, reject: reject, message: "Unable to read progress.") {
            [
                "position": $0.position,
                "duration": $0.duration,
                "buffered": $0.bufferedPosition
            ]
        }
    }

    @objc(getPlaybackState:rejecter:)
    public func getPlaybackState(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolveActivePlaybackBackendRead(resolve: resolve, reject: reject, message: "Unable to read playback state.") {
            self.getPlaybackStateBodyKeyValues(
                state: $0.playbackState,
                error: $0.publicPlaybackError
            )
        }
    }

    @objc(updateMetadataForTrack:metadata:resolver:rejecter:)
    public func updateMetadata(for trackIndex: NSNumber, metadata: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        let index = trackIndex.intValue;
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(index: index, reject: reject)) { return }

        let track : Track = player.items[index] as! Track;
        track.updateMetadata(dictionary: metadata)

        if ((useOrchestratedCrossfade && playbackOrchestrator.currentIndex == index) || (!useOrchestratedCrossfade && player.currentIndex == index)) {
            Metadata.update(for: player, with: metadata)
        }

        resolve(NSNull())
    }

    @objc(clearNowPlayingMetadata:rejecter:)
    public func clearNowPlayingMetadata(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.nowPlayingInfoController.clear()
        resolve(NSNull())
    }

    @objc(updateNowPlayingMetadata:resolver:rejecter:)
    public func updateNowPlayingMetadata(metadata: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        Metadata.update(for: player, with: metadata)
        resolve(NSNull())
    }

    private func getPlaybackStateBodyKeyValues(
        state: AudioPlayerState,
        error: IOSPlaybackErrorSnapshot? = nil
    ) -> Dictionary<String, Any> {
        var body: Dictionary<String, Any> = ["state": State.fromPlayerState(state: state).rawValue]
        if (state == AudioPlayerState.failed) {
            body["error"] = error?.dictionary ?? [:]
        }
        return body
    }

    private func getPlaybackStateBodyKeyValues(
        state: State,
        error: IOSPlaybackErrorSnapshot? = nil
    ) -> Dictionary<String, Any> {
        var body: Dictionary<String, Any> = ["state": state.rawValue]
        if state == .error {
            body["error"] = error?.dictionary ?? [:]
        }
        return body
    }

    // MARK: - QueuedAudioPlayer Event Handlers

    func handleAudioPlayerStateChange(source: QueuedAudioPlayer, state: AVPlayerWrapperState) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }
        emit(
            event: EventType.PlaybackState,
            body: getPlaybackStateBodyKeyValues(
                state: state,
                error: iosPlaybackErrorSnapshot(from: source.playbackError)
            )
        )
        if (state == .ended) {
            emit(event: EventType.PlaybackQueueEnded, body: [
                "track": source.currentIndex,
                "position": source.currentTime,
            ] as [String : Any])
        }
    }
    
    func handleAudioPlayerCommonMetadataReceived(source: QueuedAudioPlayer, metadata: [AVMetadataItem]) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }
        let commonMetadata = MetadataAdapter.convertToCommonMetadata(metadata: metadata, skipRaw: true)
        emit(event: EventType.MetadataCommonReceived, body: ["metadata": commonMetadata])
    }
    
    func handleAudioPlayerChapterMetadataReceived(source: QueuedAudioPlayer, metadata: [AVTimedMetadataGroup]) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataChapterReceived, body:  ["metadata": metadataItems])
    }

    func handleAudioPlayerTimedMetadataReceived(source: QueuedAudioPlayer, metadata: [AVTimedMetadataGroup]) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataTimedReceived, body: ["metadata": metadataItems])
        
        // SwiftAudioEx was updated to return the array of timed metadata
        // Until we have support for that in RNTP, we take the first item to keep existing behaviour.
        let metadata = metadata.first?.items ?? []
        let metadataItem = MetadataAdapter.legacyConversion(metadata: metadata)
        emit(event: EventType.PlaybackMetadataReceived, body: metadataItem)
    }

    func handleAudioPlayerFailed(source: QueuedAudioPlayer, error: Error?) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }
        emit(event: EventType.PlaybackError, body: ["error": error?.localizedDescription])
    }

    func handleAudioPlayerCurrentItemChange(
        source: QueuedAudioPlayer,
        item: AudioItem?,
        index: Int?,
        lastItem: AudioItem?,
        lastIndex: Int?,
        lastPosition: Double?
    ) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }

        if pendingStandardIdleTrackActivation?.source == ObjectIdentifier(source) {
            pendingStandardIdleTrackActivation?.emittedByPhysicalPlayer = true
        }

        let eventKey = standardActiveTrackEventKey(source: source, item: item, index: index)
        if standardIdleActivationDuplicateGuard == eventKey {
            standardIdleActivationDuplicateGuard = nil
            return
        }

        if let item = item {
            DispatchQueue.main.async {
                UIApplication.shared.beginReceivingRemoteControlEvents();
            }
            // Update now playing controller with isLiveStream option from track
            if source.automaticallyUpdateNowPlayingInfo {
                let isTrackLiveStream = (item as? Track)?.isLiveStream ?? false
                source.nowPlayingInfoController.set(keyValue: NowPlayingInfoProperty.isLiveStream(isTrackLiveStream))
            }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.endReceivingRemoteControlEvents();
            }
        }

        if ((item != nil && lastItem == nil) || item == nil) {
            configureAudioSession();
        }
        refreshRemoteCommandAvailability(kind: .standard, sourcePlayer: source)

        var a: Dictionary<String, Any> = ["lastPosition": lastPosition ?? 0]
        if let lastIndex = lastIndex {
            a["lastIndex"] = lastIndex
        }

        if let lastTrack = (lastItem as? Track)?.toObject() {
            a["lastTrack"] = lastTrack
        }

        if let index = index {
            a["index"] = index
        }

        if let track = (item as? Track)?.toObject() {
            a["track"] = track
        }
        emit(event: EventType.PlaybackActiveTrackChanged, body: a)

        // deprecated:
        var b: Dictionary<String, Any> = ["position": lastPosition ?? 0]
        if let lastIndex = lastIndex {
            b["lastIndex"] = lastIndex
        }
        if let index = index {
            b["nextTrack"] = index
        }
        emit(event: EventType.PlaybackTrackChanged, body: b)
    }

    func handleAudioPlayerSecondElapse(source: QueuedAudioPlayer, seconds: Double) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }
        // because you cannot prevent the `event.secondElapse` from firing
        // do not emit an event if `progressUpdateEventInterval` is nil
        // additionally, there are certain instances in which this event is emitted
        // _after_ a manipulation to the queu causing no currentItem to exist (see reset)
        // in which case we shouldn't emit anything or we'll get an exception.
        if !shouldEmitProgressEvent || source.currentItem == nil { return }
        emit(
            event: EventType.PlaybackProgressUpdated,
            body: [
                "position": source.currentTime,
                "duration": source.duration,
                "buffered": source.bufferedPosition,
                "track": source.currentIndex,
            ]
        )
    }

    func handlePlayWhenReadyChange(source: QueuedAudioPlayer, playWhenReady: Bool) {
        guard playbackBackendAuthority.isAuthoritative(.standard, identity: source) else { return }
        configureAudioSession();
        emit(
            event: EventType.PlaybackPlayWhenReadyChanged,
            body: [
                "playWhenReady": playWhenReady
            ]
        )
    }

    // MARK: - IOSPlaybackOrchestratorDelegate

    func playbackOrchestrator(_ orchestrator: IOSPlaybackOrchestrator, didChangeState state: State) {
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: orchestrator),
              orchestrator === playbackOrchestrator else { return }
        emit(event: EventType.PlaybackState, body: getPlaybackStateBodyKeyValues(state: state))
        configureAudioSession()
        if state == .playing {
            startOrchestratedProgressUpdates()
        } else {
            stopOrchestratedProgressUpdates()
        }
        updateNowPlayingForOrchestrator()
    }

    func playbackOrchestrator(
        _ orchestrator: IOSPlaybackOrchestrator,
        didChangeActiveTrack index: Int?,
        lastIndex: Int?,
        lastTrack: Track?,
        lastPosition: Double
    ) {
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: orchestrator),
              orchestrator === playbackOrchestrator else { return }
        if index != nil {
            DispatchQueue.main.async {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.endReceivingRemoteControlEvents()
            }
        }

        refreshRemoteCommandAvailability()
        updateNowPlayingForOrchestrator()

        let activeTrackBody = orchestratedActiveTrackEventBody(
            index: index,
            lastIndex: lastIndex,
            lastTrack: lastTrack,
            lastPosition: lastPosition,
            queue: player.items.compactMap { $0 as? Track }
        )
        emit(event: EventType.PlaybackActiveTrackChanged, body: activeTrackBody)

        var trackChangedBody: Dictionary<String, Any> = ["position": lastPosition]
        if let lastIndex = lastIndex {
            trackChangedBody["lastIndex"] = lastIndex
        }
        if let index = index {
            trackChangedBody["nextTrack"] = index
        }
        emit(event: EventType.PlaybackTrackChanged, body: trackChangedBody)
    }

    func playbackOrchestrator(_ orchestrator: IOSPlaybackOrchestrator, didEndQueueAt index: Int, position: Double) {
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: orchestrator),
              orchestrator === playbackOrchestrator else { return }
        emit(event: EventType.PlaybackQueueEnded, body: [
            "track": index,
            "position": position,
        ] as [String : Any])
    }

    func playbackOrchestrator(
        _ orchestrator: IOSPlaybackOrchestrator,
        didEmitCrossfadeState state: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int?,
        fromVolume: Float?,
        toVolume: Float?,
        errorCode: String?
    ) {
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: orchestrator),
              orchestrator === playbackOrchestrator else { return }
        emitCrossfadeState(
            state: state,
            fromIndex: fromIndex,
            toIndex: toIndex,
            elapsedMs: elapsedMs,
            fromVolume: fromVolume,
            toVolume: toVolume,
            errorCode: errorCode
        )
    }

    func playbackOrchestratorDidUpdateNowPlaying(_ orchestrator: IOSPlaybackOrchestrator) {
        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: orchestrator),
              orchestrator === playbackOrchestrator else { return }
        updateNowPlayingForOrchestrator(orchestrator)
    }

    private func updateNowPlayingForOrchestrator(
        _ orchestrator: IOSPlaybackOrchestrator? = nil,
        queuePlayer: QueuedAudioPlayer? = nil,
        force: Bool = false
    ) {
        let source = orchestrator ?? playbackOrchestrator
        let sourcePlayer = queuePlayer ?? player
        guard force || playbackBackendAuthority.isAuthoritative(.pingPong, identity: source) else { return }
        guard autoUpdateNowPlayingInfo else { return }
        let index = source.currentIndex
        guard index >= 0 && index < sourcePlayer.items.count,
              let track = sourcePlayer.items[index] as? Track else { return }

        var metadata = track.toObject()
        metadata["elapsedTime"] = source.currentTime
        if metadata["duration"] == nil, source.duration > 0 {
            metadata["duration"] = source.duration
        }
        Metadata.update(for: sourcePlayer, with: metadata)

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = source.currentTime
        if source.duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = source.duration
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = Double(source.nowPlayingPlaybackRate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        IOSPlaybackLog.log("nowPlaying center index=\(index) elapsed=\(source.currentTime)")
    }
}
