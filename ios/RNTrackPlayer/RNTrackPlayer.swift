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

@objc(RNTrackPlayer)
public class RNTrackPlayer: RCTEventEmitter, AudioSessionControllerDelegate, IOSPlaybackOrchestratorDelegate {

    // MARK: - Attributes

    private var hasInitialized = false
    private let player = QueuedAudioPlayer()
    private let crossfadeCoordinator = IOSCrossfadeCoordinator()
    private let playbackOrchestrator = IOSPlaybackOrchestrator()
    private let audioSessionController = AudioSessionController.shared
    private var shouldEmitProgressEvent: Bool = false
    private var progressUpdateInterval: Double = 0
    private var orchestratedProgressWorkItem: DispatchWorkItem? = nil
    private var shouldResumePlaybackAfterInterruptionEnds: Bool = false
    private var crossfadeEnabled: Bool = false
    private var crossfadeEngineMode: String = "orchestratedDualEngine"
    private var crossfadeStartWorkItem: DispatchWorkItem? = nil
    private var crossfadeRunId: Int = 0
    private var crossfadePendingReject: RCTPromiseRejectBlock? = nil
    private var crossfadePendingFromIndex: Int? = nil
    private var crossfadePendingToIndex: Int? = nil
    private var preparedCrossfadeSeekTo: Double = 0
    private var autoUpdateNowPlayingInfo: Bool = true
    private var forwardJumpInterval: NSNumber? = nil;
    private var backwardJumpInterval: NSNumber? = nil;
    private var configuredCapabilityValues: Set<String> = []
    private var sessionCategory: AVAudioSession.Category = .playback
    private var sessionCategoryMode: AVAudioSession.Mode = .default
    private var sessionCategoryPolicy: AVAudioSession.RouteSharingPolicy = .default
    private var sessionCategoryOptions: AVAudioSession.CategoryOptions = []

    // MARK: - Lifecycle Methods

    public override init() {
        super.init()
        EventEmitter.shared.register(eventEmitter: self)
        playbackOrchestrator.delegate = self
        audioSessionController.delegate = self
        configurePlayerEvents()
        player.playWhenReady = false;
    }

    deinit {
        reset(resolve: { _ in }, reject: { _, _, _  in })
    }

    private func configurePlayerEvents() {
        player.event.receiveChapterMetadata.addListener(self) { [weak self] metadata in
            guard let self = self else { return }
            self.handleAudioPlayerChapterMetadataReceived(metadata: metadata)
        }
        player.event.receiveTimedMetadata.addListener(self) { [weak self] metadata in
            guard let self = self else { return }
            self.handleAudioPlayerTimedMetadataReceived(metadata: metadata)
        }
        player.event.receiveCommonMetadata.addListener(self) { [weak self] metadata in
            guard let self = self else { return }
            self.handleAudioPlayerCommonMetadataReceived(metadata: metadata)
        }
        player.event.stateChange.addListener(self) { [weak self] state in
            guard let self = self else { return }
            self.handleAudioPlayerStateChange(state: state)
        }
        player.event.fail.addListener(self) { [weak self] error in
            guard let self = self else { return }
            self.handleAudioPlayerFailed(error: error)
        }
        player.event.currentItem.addListener(self) { [weak self] data in
            guard let self = self else { return }
            self.handleAudioPlayerCurrentItemChange(
                item: data.item,
                index: data.index,
                lastItem: data.lastItem,
                lastIndex: data.lastIndex,
                lastPosition: data.lastPosition
            )
        }
        player.event.secondElapse.addListener(self) { [weak self] seconds in
            guard let self = self else { return }
            self.handleAudioPlayerSecondElapse(seconds: seconds)
        }
        player.event.playWhenReadyChange.addListener(self) { [weak self] playWhenReady in
            guard let self = self else { return }
            self.handlePlayWhenReadyChange(playWhenReady: playWhenReady)
        }
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
                    player.play()
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
        let rejected = index < (min ?? 0) || index > (max ?? player.items.count - 1);
        if (rejected) {
            reject("index_out_of_bounds", message, nil)
        }
        return rejected
    }

    private var useOrchestratedCrossfade: Bool {
        return crossfadeEnabled && crossfadeEngineMode != "legacyHybrid"
    }

    private func playerTracks() -> [Track] {
        return player.items.compactMap { $0 as? Track }
    }

    private func syncOrchestratorQueue() {
        guard useOrchestratedCrossfade else { return }
        playbackOrchestrator.setQueue(playerTracks())
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

        crossfadeEnabled = config["crossfade"] as? Bool ?? false
        crossfadeEngineMode = config["crossfadeEngineMode"] as? String ?? "orchestratedDualEngine"

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

        // setup event listeners
        player.remoteCommandController.handleChangePlaybackPositionCommand = { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.emit(event: EventType.RemoteSeek, body: ["position": event.positionTime])
                return MPRemoteCommandHandlerStatus.success
            }

            return MPRemoteCommandHandlerStatus.commandFailed
        }

        player.remoteCommandController.handleNextTrackCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteNext)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handlePauseCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePause)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handlePlayCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePlay)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handlePreviousTrackCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePrevious)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleSkipBackwardCommand = { [weak self] event in
            if let command = event.command as? MPSkipIntervalCommand,
               let interval = command.preferredIntervals.first {
                self?.emit(event: EventType.RemoteJumpBackward, body: ["interval": interval])
                return MPRemoteCommandHandlerStatus.success
            }

            return MPRemoteCommandHandlerStatus.commandFailed
        }

        player.remoteCommandController.handleSkipForwardCommand = { [weak self] event in
            if let command = event.command as? MPSkipIntervalCommand,
               let interval = command.preferredIntervals.first {
                self?.emit(event: EventType.RemoteJumpForward, body: ["interval": interval])
                return MPRemoteCommandHandlerStatus.success
            }

            return MPRemoteCommandHandlerStatus.commandFailed
        }

        player.remoteCommandController.handleStopCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteStop)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleTogglePlayPauseCommand = { [weak self] _ in
            guard let self = self else { return MPRemoteCommandHandlerStatus.commandFailed }
            if self.useOrchestratedCrossfade {
                self.emit(event: self.playbackOrchestrator.playbackState == .paused
                    ? EventType.RemotePlay
                    : EventType.RemotePause
                )
            } else {
                self.emit(event: self.player.playerState == .paused
                    ? EventType.RemotePlay
                    : EventType.RemotePause
                )
            }

            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleLikeCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteLike)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleDislikeCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteDislike)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleBookmarkCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteBookmark)
            return MPRemoteCommandHandlerStatus.success
        }

        hasInitialized = true
        resolve(NSNull())
    }


    private func configureAudioSession() {
        if useOrchestratedCrossfade {
            if !playbackOrchestrator.hasCurrentItem {
                try? audioSessionController.deactivateSession()
                return
            }
            if playbackOrchestrator.playWhenReady {
                activateAudioSessionForPlayback()
            }
            return
        }

        // deactivate the session when there is no current item to be played
        if (player.currentItem == nil) {
            try? audioSessionController.deactivateSession()
            return
        }
        
        // activate the audio session when there is an item to be played
        // and the player has been configured to start when it is ready loading:
        if (player.playWhenReady) {
            activateAudioSessionForPlayback()
        }
    }

    @objc(isServiceRunning:rejecter:)
    public func isServiceRunning(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        // TODO That is probably always true
        resolve(player != nil)
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

    private func refreshRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let logicalIndex = useOrchestratedCrossfade ? playbackOrchestrator.currentIndex : player.currentIndex
        let hasCurrentItem = useOrchestratedCrossfade
            ? playbackOrchestrator.hasCurrentItem
            : player.currentItem != nil

        center.nextTrackCommand.isEnabled = configuredCapabilityValues.contains(Capability.next.rawValue)
            && hasCurrentItem
            && logicalIndex >= 0
            && logicalIndex < player.items.count - 1
        center.previousTrackCommand.isEnabled = configuredCapabilityValues.contains(Capability.previous.rawValue)
            && hasCurrentItem
            && logicalIndex > 0
    }

    private func startOrchestratedProgressUpdates() {
        orchestratedProgressWorkItem?.cancel()
        orchestratedProgressWorkItem = nil
        guard useOrchestratedCrossfade, playbackOrchestrator.hasCurrentItem else { return }
        guard playbackOrchestrator.playbackState == .playing else { return }

        let interval = shouldEmitProgressEvent ? max(0.25, progressUpdateInterval) : 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.emitOrchestratedProgress()
            self.startOrchestratedProgressUpdates()
        }
        orchestratedProgressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func stopOrchestratedProgressUpdates() {
        orchestratedProgressWorkItem?.cancel()
        orchestratedProgressWorkItem = nil
    }

    private func emitOrchestratedProgress() {
        guard useOrchestratedCrossfade, playbackOrchestrator.hasCurrentItem else { return }
        updateNowPlayingForOrchestrator()
        guard shouldEmitProgressEvent else { return }
        emit(
            event: EventType.PlaybackProgressUpdated,
            body: [
                "position": playbackOrchestrator.currentTime,
                "duration": playbackOrchestrator.duration,
                "buffered": playbackOrchestrator.bufferedPosition,
                "track": playbackOrchestrator.currentIndex,
            ]
        )
    }

    private func cancelCrossfadeWork(errorCode: String = "cancelled", resetActivePlayback: Bool = false) {
        crossfadeRunId += 1
        crossfadeStartWorkItem?.cancel()
        crossfadeStartWorkItem = nil
        crossfadeCoordinator.cancelTransition(keepActivePlayback: false)
        player.volume = 1
        if let reject = crossfadePendingReject {
            if let fromIndex = crossfadePendingFromIndex, let toIndex = crossfadePendingToIndex {
                emitCrossfadeState(
                    state: "cancelled",
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    errorCode: errorCode
                )
            }
            reject(errorCode, "Crossfade was cancelled.", nil)
        }
        clearCrossfadePromise()
    }

    private func clearCrossfadePromise() {
        crossfadePendingReject = nil
        crossfadePendingFromIndex = nil
        crossfadePendingToIndex = nil
        preparedCrossfadeSeekTo = 0
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

    private func xfadeLog(_ message: String) {
        let time = CACurrentMediaTime()
        print("[XF][\(String(format: "%.6f", time))] \(message)")
    }

    private func cancelCrossfadeForManualAction() {
        if useOrchestratedCrossfade {
            player.volume = 0
            return
        }
        if crossfadeEnabled {
            cancelCrossfadeWork(resetActivePlayback: true)
            crossfadeCoordinator.reset()
            player.volume = 1
        }
    }

    private func mutePublicPlayerForInternalCrossfade() {
        player.volume = 0
        xfadeLog("onStarted: public player muted without jumpToItem")
        refreshRemoteCommandAvailability()
    }

    private func startPublicPlayerForHandback(
        toIndex: Int,
        targetVolume: Float,
        shouldContinue: @escaping () -> Bool,
        completion: @escaping () -> Void
    ) {
        guard shouldContinue(), toIndex >= 0, toIndex < player.items.count else { return }

        let livePosition = max(0, crossfadeCoordinator.incomingCurrentTime)
        xfadeLog("handback: prepare public player index=\(toIndex) position=\(livePosition)")

        player.volume = 0
        if player.currentIndex != toIndex {
            xfadeLog("handback: before public jumpToItem")
            try? player.jumpToItem(atIndex: toIndex, playWhenReady: false)
            xfadeLog("handback: after public jumpToItem")
        }

        xfadeLog("handback: before public seek")
        player.seek(to: livePosition)
        xfadeLog("handback: after public seek call")
        player.play()
        player.volume = 0

        waitUntilPublicPlayerStable(
            expectedIndex: toIndex,
            expectedPosition: livePosition,
            shouldContinue: shouldContinue
        ) { [weak self] stable in
            guard let self = self, shouldContinue() else { return }
            self.xfadeLog("handback: public stable=\(stable) state=\(self.player.playerState) index=\(self.player.currentIndex) position=\(self.player.currentTime)")
            self.crossfadeCoordinator.handbackToPublicPlayer(
                durationMs: 150,
                targetVolume: targetVolume,
                setPublicVolume: { [weak self] volume in
                    self?.player.volume = volume
                },
                completion: completion
            )
        }
    }

    private func waitUntilPublicPlayerStable(
        expectedIndex: Int,
        expectedPosition: Double,
        shouldContinue: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let startedAt = CACurrentMediaTime()
        let timeoutSeconds = 2.0

        func poll() {
            guard shouldContinue() else { return }

            let state = player.playerState
            let stateAllowsHandback = state == .playing || state == .ready || state == .buffering
            let indexMatches = player.currentIndex == expectedIndex
            let positionDelta = abs(player.currentTime - expectedPosition)
            let positionMatches = positionDelta <= 0.75

            if indexMatches && stateAllowsHandback && positionMatches {
                completion(true)
                return
            }

            if CACurrentMediaTime() - startedAt >= timeoutSeconds {
                completion(false)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                poll()
            }
        }

        poll()
        refreshRemoteCommandAvailability()
    }

    private func publicPlaybackPosition() -> Double {
        if useOrchestratedCrossfade {
            return playbackOrchestrator.currentTime
        }
        return player.currentTime
    }

    private func publicPlaybackDuration() -> Double {
        if useOrchestratedCrossfade {
            return playbackOrchestrator.duration
        }
        return player.duration
    }

    private func publicBufferedPosition() -> Double {
        if useOrchestratedCrossfade {
            return playbackOrchestrator.bufferedPosition
        }
        return player.bufferedPosition
    }

    private func publicPlaybackVolume() -> Float {
        if useOrchestratedCrossfade {
            return playbackOrchestrator.volume
        }
        return player.volume
    }

    private func crossfadePlaybackRate() -> Float {
        let rate = player.rate
        return rate.isFinite && rate > 0.01 ? rate : 1
    }

    @objc(add:before:resolver:rejecter:)
    public func add(
        trackDicts: [[String: Any]],
        before trackIndex: NSNumber,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        // -1 means no index was passed and therefore should be inserted at the end.
        let index = trackIndex.intValue == -1 ? player.items.count : trackIndex.intValue;
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: index,
            max: player.items.count,
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

        try? player.add(
            items: tracks,
            at: index
        )
        syncOrchestratorQueue()
        resolve(index)
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

        cancelCrossfadeForManualAction()
        player.load(item: track)
        if useOrchestratedCrossfade {
            player.volume = 0
            playbackOrchestrator.load(track: track) { result in
                switch result {
                case .success(let index):
                    resolve(index)
                case .failure(let error):
                    reject("ios_orchestrator_load_failed", "Unable to load the track.", error)
                }
            }
            return
        }
        resolve(player.currentIndex)
    }

    @objc(remove:resolver:rejecter:)
    public func remove(tracks indexes: [Int], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        for index in indexes {
            if (rejectWhenTrackIndexOutOfBounds(index: index, message: "One or more of the indexes were out of bounds.", reject: reject)) {
                return
            }
        }

        // Sort the indexes in descending order so we can safely remove them one by one
        // without having the next index possibly newly pointing to another item than intended:
        cancelCrossfadeForManualAction()
        for index in indexes.sorted().reversed() {
            try? player.removeItem(at: index)
        }
        syncOrchestratorQueue()

        resolve(NSNull())
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
        cancelCrossfadeForManualAction()
        try? player.moveItem(fromIndex: fromIndex.intValue, toIndex: toIndex.intValue)
        syncOrchestratorQueue()
        resolve(NSNull())
    }


    @objc(removeUpcomingTracks:rejecter:)
    public func removeUpcomingTracks(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        cancelCrossfadeForManualAction()
        player.removeUpcomingItems()
        syncOrchestratorQueue()
        resolve(NSNull())
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
        if useOrchestratedCrossfade {
            playbackOrchestrator.skip(to: index, initialTime: initialTime) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("skip_failed", "Unable to skip to track.", error)
                }
            }
            return
        }
        cancelCrossfadeForManualAction()
        try? player.jumpToItem(atIndex: index, playWhenReady: player.playerState == .playing)

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc(skipToNext:resolver:rejecter:)
    public func skipToNext(
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            playbackOrchestrator.skipToNext(initialTime: initialTime) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("skip_failed", "Unable to skip to next track.", error)
                }
            }
            return
        }
        cancelCrossfadeForManualAction()
        player.next()

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc(skipToPrevious:resolver:rejecter:)
    public func skipToPrevious(
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            playbackOrchestrator.skipToPrevious(initialTime: initialTime) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("skip_failed", "Unable to skip to previous track.", error)
                }
            }
            return
        }
        cancelCrossfadeForManualAction()
        player.previous()

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc(reset:rejecter:)
    public func reset(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if crossfadeEnabled {
            cancelCrossfadeWork(resetActivePlayback: true)
            crossfadeCoordinator.reset()
            playbackOrchestrator.stop()
        }
        player.stop()
        player.clear()
        player.volume = 1
        resolve(NSNull())
    }

    @objc(play:rejecter:)
    public func play(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if useOrchestratedCrossfade {
            player.volume = 0
            syncOrchestratorQueue()
            activateAudioSessionForPlayback()
            playbackOrchestrator.play { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("playback_failed", "Unable to start playback.", error)
                }
            }
            return
        }
        player.play()
        resolve(NSNull())
    }

    @objc(pause:rejecter:)
    public func pause(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            playbackOrchestrator.pause()
            resolve(NSNull())
            return
        }
        if crossfadeEnabled {
            cancelCrossfadeWork()
            crossfadeCoordinator.pause()
            player.pause()
            resolve(NSNull())
            return
        }

        player.pause()
        resolve(NSNull())
    }

    @objc(setPlayWhenReady:resolver:rejecter:)
    public func setPlayWhenReady(playWhenReady: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if useOrchestratedCrossfade {
            playbackOrchestrator.setPlayWhenReady(playWhenReady) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("playback_failed", "Unable to update playWhenReady.", error)
                }
            }
            return
        }
        if crossfadeEnabled && !playWhenReady {
            cancelCrossfadeWork()
            crossfadeCoordinator.pause()
            player.pause()
            resolve(NSNull())
            return
        }
        player.playWhenReady = playWhenReady
        resolve(NSNull())
    }

    @objc(getPlayWhenReady:rejecter:)
    public func getPlayWhenReady(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if useOrchestratedCrossfade {
            resolve(playbackOrchestrator.playWhenReady)
            return
        }
        resolve(player.playWhenReady)
    }

    @objc(stop:rejecter:)
    public func stop(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if crossfadeEnabled {
            cancelCrossfadeWork(resetActivePlayback: true)
            crossfadeCoordinator.reset()
            playbackOrchestrator.stop()
            player.volume = 1
        }
        player.stop()
        resolve(NSNull())
    }

    @objc(seekTo:resolver:rejecter:)
    public func seekTo(time: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            playbackOrchestrator.seek(to: time) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("seek_failed", "Unable to seek.", error)
                }
            }
            return
        }
        if crossfadeEnabled {
            cancelCrossfadeWork(resetActivePlayback: false)
        }
        player.seek(to: time)
        resolve(NSNull())
    }

    @objc(seekBy:resolver:rejecter:)
    public func seekBy(offset: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            playbackOrchestrator.seek(by: offset) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("seek_failed", "Unable to seek.", error)
                }
            }
            return
        }
        if crossfadeEnabled {
            cancelCrossfadeWork(resetActivePlayback: false)
        }
        player.seek(by: offset)
        resolve(NSNull())
    }

    @objc(retry:rejecter:)
    public func retry(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        player.reload(startFromCurrentTime: true)
        resolve(NSNull())
    }

    @objc(setRepeatMode:resolver:rejecter:)
    public func setRepeatMode(repeatMode: NSNumber, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: repeatMode.intValue) ?? .off
        resolve(NSNull())
    }

    @objc(getRepeatMode:rejecter:)
    public func getRepeatMode(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.repeatMode.rawValue)
    }

    @objc(setVolume:resolver:rejecter:)
    public func setVolume(level: Float, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            playbackOrchestrator.setVolume(level)
            resolve(NSNull())
            return
        }
        player.volume = level
        resolve(NSNull())
    }

    @objc(crossFadePrepare:seekTo:resolver:rejecter:)
    public func crossFadePrepare(
        previous: Bool,
        seekTo: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        guard crossfadeEnabled else {
            resolve(NSNull())
            return
        }
        if useOrchestratedCrossfade {
            playbackOrchestrator.prepareCrossfade(previous: previous, seekTo: seekTo) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("crossfade_prepare_failed", "Unable to prepare the crossfade target.", error)
                }
            }
            return
        }
        cancelCrossfadeWork()

        let fromIndex = player.currentIndex
        let toIndex = previous ? fromIndex - 1 : fromIndex + 1
        guard fromIndex >= 0, toIndex >= 0, toIndex < player.items.count else {
            reject("crossfade_target_unavailable", "No crossfade target track is available.", nil)
            return
        }

        guard let outgoingTrack = player.items[fromIndex] as? Track,
              let incomingTrack = player.items[toIndex] as? Track else {
            reject("crossfade_target_unavailable", "No crossfade target track is available.", nil)
            return
        }

        let prepareRunId = crossfadeRunId
        preparedCrossfadeSeekTo = max(0, seekTo)
        crossfadeCoordinator.prepare(
            outgoingTrack: outgoingTrack,
            outgoingPosition: publicPlaybackPosition(),
            fromIndex: fromIndex,
            incomingTrack: incomingTrack,
            incomingPosition: preparedCrossfadeSeekTo,
            toIndex: toIndex
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.crossfadeRunId == prepareRunId else { return }
                switch result {
                case .success:
                    self.emitCrossfadeState(
                        state: "prepared",
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        elapsedMs: 0,
                        fromVolume: self.publicPlaybackVolume(),
                        toVolume: 0
                    )
                    resolve(NSNull())
                case .failure(let error):
                    self.emitCrossfadeState(state: "error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "prepare_failed")
                    reject("crossfade_prepare_failed", "Unable to prepare the crossfade target.", error)
                }
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
        guard crossfadeEnabled else {
            resolve(NSNull())
            return
        }
        if useOrchestratedCrossfade {
            playbackOrchestrator.crossFade(
                fadeDuration: fadeDuration,
                fadeInterval: fadeInterval,
                fadeToVolume: fadeToVolume,
                waitUntil: waitUntil
            ) { result in
                switch result {
                case .success:
                    resolve(NSNull())
                case .failure(let error):
                    reject("crossfade_failed", "Unable to complete crossfade.", error)
                }
            }
            return
        }

        let fromIndex = player.currentIndex
        let preparedMatchesCurrent = crossfadeCoordinator.preparedFromIndex == fromIndex
            && crossfadeCoordinator.preparedToIndex != nil
        let toIndex = preparedMatchesCurrent
            ? crossfadeCoordinator.preparedToIndex!
            : fromIndex + 1

        guard fromIndex >= 0, toIndex >= 0, toIndex < player.items.count else {
            reject("crossfade_target_unavailable", "No prepared crossfade target track is available.", nil)
            return
        }
        guard let outgoingTrack = player.items[fromIndex] as? Track,
              let incomingTrack = player.items[toIndex] as? Track else {
            reject("crossfade_target_unavailable", "No prepared crossfade target track is available.", nil)
            return
        }

        let durationMs = max(0, Int(fadeDuration))
        let intervalMs = max(10, Int(fadeInterval))
        let targetVolume = Float(max(0, min(1, fadeToVolume)))

        let scheduleCrossfade = { [weak self] in
            guard let self = self else { return }
            self.crossfadeRunId += 1
            let runId = self.crossfadeRunId
            self.crossfadePendingReject = reject
            self.crossfadePendingFromIndex = fromIndex
            self.crossfadePendingToIndex = toIndex

            emitCrossfadeState(
                state: "scheduled",
                fromIndex: fromIndex,
                toIndex: toIndex,
                elapsedMs: 0,
                fromVolume: self.publicPlaybackVolume(),
                toVolume: 0
            )

            let start = DispatchWorkItem { [weak self] in
                guard let self = self, self.crossfadeRunId == runId else { return }
                self.crossfadeCoordinator.start(
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    durationMs: durationMs,
                    intervalMs: intervalMs,
                    targetVolume: targetVolume,
                    rate: self.crossfadePlaybackRate(),
                    publicVolume: self.publicPlaybackVolume(),
                    currentPublicPosition: { [weak self] in self?.player.currentTime ?? 0 },
                    onStarted: { [weak self] fromVolume, toVolume in
                        guard let self = self, self.crossfadeRunId == runId else { return }
                        self.mutePublicPlayerForInternalCrossfade()
                        self.emitCrossfadeState(
                            state: "started",
                            fromIndex: fromIndex,
                            toIndex: toIndex,
                            elapsedMs: 0,
                            fromVolume: fromVolume,
                            toVolume: toVolume
                        )
                    },
                    onRunning: { [weak self] elapsedMs, fromVolume, toVolume in
                        guard let self = self, self.crossfadeRunId == runId else { return }
                        self.emitCrossfadeState(
                            state: "running",
                            fromIndex: fromIndex,
                            toIndex: toIndex,
                            elapsedMs: elapsedMs,
                            fromVolume: fromVolume,
                            toVolume: toVolume
                        )
                    },
                    onCompleted: { [weak self] elapsedMs, fromVolume, toVolume, incomingPosition in
                        guard let self = self, self.crossfadeRunId == runId else { return }
                        self.xfadeLog("internal fade completed incomingPosition=\(incomingPosition)")
                        self.startPublicPlayerForHandback(
                            toIndex: toIndex,
                            targetVolume: toVolume,
                            shouldContinue: { [weak self] in
                                self?.crossfadeRunId == runId
                            }
                        ) { [weak self] in
                            guard let self = self, self.crossfadeRunId == runId else { return }
                            self.emitCrossfadeState(
                                state: "completed",
                                fromIndex: fromIndex,
                                toIndex: toIndex,
                                elapsedMs: elapsedMs,
                                fromVolume: fromVolume,
                                toVolume: toVolume
                            )
                            self.refreshRemoteCommandAvailability()
                            self.clearCrossfadePromise()
                            resolve(NSNull())
                        }
                    },
                    onError: { [weak self] error in
                        guard let self = self, self.crossfadeRunId == runId else { return }
                        self.emitCrossfadeState(state: "error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "crossfade_failed")
                        self.clearCrossfadePromise()
                        reject("crossfade_failed", "Unable to complete crossfade.", error)
                    }
                )
            }

            func scheduleStartCheck() {
                guard self.crossfadeRunId == runId else { return }
                guard self.player.currentIndex == fromIndex else {
                    self.emitCrossfadeState(
                        state: "cancelled",
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        errorCode: "current_track_changed"
                    )
                    self.clearCrossfadePromise()
                    reject("cancelled", "Crossfade source track changed before start.", nil)
                    return
                }

                let remainingMs = Int(waitUntil - self.publicPlaybackPosition() * 1000)
                if remainingMs <= 0 {
                    self.crossfadeStartWorkItem = start
                    DispatchQueue.main.async(execute: start)
                    return
                }

                let check = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    scheduleStartCheck()
                }
                self.crossfadeStartWorkItem = check
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(max(50, min(250, remainingMs))),
                    execute: check
                )
            }

            scheduleStartCheck()
        }

        if preparedMatchesCurrent {
            scheduleCrossfade()
            return
        }

        cancelCrossfadeWork()
        let prepareRunId = crossfadeRunId
        preparedCrossfadeSeekTo = 0
        crossfadeCoordinator.prepare(
            outgoingTrack: outgoingTrack,
            outgoingPosition: publicPlaybackPosition(),
            fromIndex: fromIndex,
            incomingTrack: incomingTrack,
            incomingPosition: 0,
            toIndex: toIndex
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.crossfadeRunId == prepareRunId else { return }
                switch result {
                case .success:
                    self.emitCrossfadeState(
                        state: "prepared",
                        fromIndex: fromIndex,
                        toIndex: toIndex,
                        elapsedMs: 0,
                        fromVolume: self.publicPlaybackVolume(),
                        toVolume: 0
                    )
                    scheduleCrossfade()
                case .failure(let error):
                    self.emitCrossfadeState(state: "error", fromIndex: fromIndex, toIndex: toIndex, errorCode: "prepare_failed")
                    reject("crossfade_prepare_failed", "Unable to prepare the crossfade target.", error)
                }
            }
        }
    }

    @objc(getVolume:rejecter:)
    public func getVolume(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(publicPlaybackVolume())
    }

    @objc(setRate:resolver:rejecter:)
    public func setRate(rate: Float, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            playbackOrchestrator.setRate(rate)
            resolve(NSNull())
            return
        }
        player.rate = rate
        resolve(NSNull())
    }

    @objc(getRate:rejecter:)
    public func getRate(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if useOrchestratedCrossfade {
            resolve(playbackOrchestrator.rate)
            return
        }
        resolve(player.rate)
    }

    @objc(getTrack:resolver:rejecter:)
    public func getTrack(index: NSNumber, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if (index.intValue >= 0 && index.intValue < player.items.count) {
            let track = player.items[index.intValue]
            resolve((track as? Track)?.toObject())
        } else {
            resolve(NSNull())
        }
    }

    @objc(getQueue:rejecter:)
    public func getQueue(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let serializedQueue = player.items.map { ($0 as! Track).toObject() }
        resolve(serializedQueue)
    }

    @objc(setQueue:resolver:rejecter:)
    public func setQueue(
        trackDicts: [[String: Any]],
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
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
        cancelCrossfadeForManualAction()
        player.clear()
        try? player.add(items: tracks)
        if useOrchestratedCrossfade {
            playbackOrchestrator.replaceQueue(tracks, currentIndex: -1)
            player.volume = 0
        }
        resolve(NSNull())
    }

    @objc(getActiveTrack:rejecter:)
    public func getActiveTrack(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let index = useOrchestratedCrossfade ? playbackOrchestrator.currentIndex : player.currentIndex
        if (index >= 0 && index < player.items.count) {
            let track = player.items[index]
            resolve((track as? Track)?.toObject())
        } else {
            resolve(NSNull())
        }
    }

    @objc(getActiveTrackIndex:rejecter:)
    public func getActiveTrackIndex(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let index = useOrchestratedCrossfade ? playbackOrchestrator.currentIndex : player.currentIndex
        if index < 0 || index >= player.items.count {
            resolve(NSNull())
        } else {
            resolve(index)
        }
    }

    @objc(getDuration:rejecter:)
    public func getDuration(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(publicPlaybackDuration())
    }

    @objc(getBufferedPosition:rejecter:)
    public func getBufferedPosition(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(publicBufferedPosition())
    }

    @objc(getPosition:rejecter:)
    public func getPosition(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(publicPlaybackPosition())
    }

    @objc(getProgress:rejecter:)
    public func getProgress(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolve([
            "position": publicPlaybackPosition(),
            "duration": publicPlaybackDuration(),
            "buffered": publicBufferedPosition()
        ])
    }

    @objc(getPlaybackState:rejecter:)
    public func getPlaybackState(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if useOrchestratedCrossfade {
            resolve(getPlaybackStateBodyKeyValues(state: playbackOrchestrator.playbackState))
            return
        }
        resolve(getPlaybackStateBodyKeyValues(state: player.playerState))
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

    private func getPlaybackStateErrorKeyValues() -> Dictionary<String, Any> {
        switch player.playbackError {
            case .failedToLoadKeyValue: return [
                "message": "Failed to load resource",
                "code": "ios_failed_to_load_resource"
            ]
            case .invalidSourceUrl: return [
                "message": "The source url was invalid",
                "code": "ios_invalid_source_url"
            ]
            case .notConnectedToInternet: return [
                "message": "A network resource was requested, but an internet connection has not been established and can’t be established automatically.",
                "code": "ios_not_connected_to_internet"
            ]
            case .playbackFailed: return [
                "message": "Playback of the track failed",
                "code": "ios_playback_failed"
            ]
            case .itemWasUnplayable: return [
                "message": "The track could not be played",
                "code": "ios_track_unplayable"
            ]
            default: return [
                "message": "A playback error occurred",
                "code": "ios_playback_error"
            ]
        }
    }

    private func getPlaybackStateBodyKeyValues(state: AudioPlayerState) -> Dictionary<String, Any> {
        var body: Dictionary<String, Any> = ["state": State.fromPlayerState(state: state).rawValue]
        if (state == AudioPlayerState.failed) {
            body["error"] = getPlaybackStateErrorKeyValues()
        }
        return body
    }

    private func getPlaybackStateBodyKeyValues(state: State) -> Dictionary<String, Any> {
        return ["state": state.rawValue]
    }

    // MARK: - QueuedAudioPlayer Event Handlers

    func handleAudioPlayerStateChange(state: AVPlayerWrapperState) {
        if useOrchestratedCrossfade { return }
        emit(event: EventType.PlaybackState, body: getPlaybackStateBodyKeyValues(state: state))
        if (state == .ended) {
            emit(event: EventType.PlaybackQueueEnded, body: [
                "track": player.currentIndex,
                "position": player.currentTime,
            ] as [String : Any])
        }
    }
    
    func handleAudioPlayerCommonMetadataReceived(metadata: [AVMetadataItem]) {
        let commonMetadata = MetadataAdapter.convertToCommonMetadata(metadata: metadata, skipRaw: true)
        emit(event: EventType.MetadataCommonReceived, body: ["metadata": commonMetadata])
    }
    
    func handleAudioPlayerChapterMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataChapterReceived, body:  ["metadata": metadataItems])
    }

    func handleAudioPlayerTimedMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataTimedReceived, body: ["metadata": metadataItems])
        
        // SwiftAudioEx was updated to return the array of timed metadata
        // Until we have support for that in RNTP, we take the first item to keep existing behaviour.
        let metadata = metadata.first?.items ?? []
        let metadataItem = MetadataAdapter.legacyConversion(metadata: metadata)
        emit(event: EventType.PlaybackMetadataReceived, body: metadataItem)
    }

    func handleAudioPlayerFailed(error: Error?) {
        emit(event: EventType.PlaybackError, body: ["error": error?.localizedDescription])
    }

    func handleAudioPlayerCurrentItemChange(
        item: AudioItem?,
        index: Int?,
        lastItem: AudioItem?,
        lastIndex: Int?,
        lastPosition: Double?
    ) {
        if useOrchestratedCrossfade { return }

        if let item = item {
            DispatchQueue.main.async {
                UIApplication.shared.beginReceivingRemoteControlEvents();
            }
            // Update now playing controller with isLiveStream option from track
            if self.player.automaticallyUpdateNowPlayingInfo {
                let isTrackLiveStream = (item as? Track)?.isLiveStream ?? false
                self.player.nowPlayingInfoController.set(keyValue: NowPlayingInfoProperty.isLiveStream(isTrackLiveStream))
            }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.endReceivingRemoteControlEvents();
            }
        }

        if ((item != nil && lastItem == nil) || item == nil) {
            configureAudioSession();
        }
        refreshRemoteCommandAvailability()

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

    func handleAudioPlayerSecondElapse(seconds: Double) {
        if useOrchestratedCrossfade { return }
        // because you cannot prevent the `event.secondElapse` from firing
        // do not emit an event if `progressUpdateEventInterval` is nil
        // additionally, there are certain instances in which this event is emitted
        // _after_ a manipulation to the queu causing no currentItem to exist (see reset)
        // in which case we shouldn't emit anything or we'll get an exception.
        if !shouldEmitProgressEvent || player.currentItem == nil { return }
        emit(
            event: EventType.PlaybackProgressUpdated,
            body: [
                "position": publicPlaybackPosition(),
                "duration": publicPlaybackDuration(),
                "buffered": publicBufferedPosition(),
                "track": player.currentIndex,
            ]
        )
    }

    func handlePlayWhenReadyChange(playWhenReady: Bool) {
        if useOrchestratedCrossfade { return }
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
        lastPosition: Double
    ) {
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

        var activeTrackBody: Dictionary<String, Any> = ["lastPosition": lastPosition]
        if let lastIndex = lastIndex {
            activeTrackBody["lastIndex"] = lastIndex
            if lastIndex >= 0 && lastIndex < player.items.count,
               let lastTrack = (player.items[lastIndex] as? Track)?.toObject() {
                activeTrackBody["lastTrack"] = lastTrack
            }
        }
        if let index = index {
            activeTrackBody["index"] = index
            if index >= 0 && index < player.items.count,
               let track = (player.items[index] as? Track)?.toObject() {
                activeTrackBody["track"] = track
            }
        }
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
        updateNowPlayingForOrchestrator()
    }

    private func updateNowPlayingForOrchestrator() {
        guard useOrchestratedCrossfade else { return }
        guard autoUpdateNowPlayingInfo else { return }
        let index = playbackOrchestrator.currentIndex
        guard index >= 0 && index < player.items.count,
              let track = player.items[index] as? Track else { return }

        var metadata = track.toObject()
        metadata["elapsedTime"] = playbackOrchestrator.currentTime
        if metadata["duration"] == nil, playbackOrchestrator.duration > 0 {
            metadata["duration"] = playbackOrchestrator.duration
        }
        Metadata.update(for: player, with: metadata)

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackOrchestrator.currentTime
        if playbackOrchestrator.duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = playbackOrchestrator.duration
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackOrchestrator.playWhenReady
            ? Double(playbackOrchestrator.rate)
            : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        IOSPlaybackLog.log("nowPlaying center index=\(index) elapsed=\(playbackOrchestrator.currentTime)")
    }
}
