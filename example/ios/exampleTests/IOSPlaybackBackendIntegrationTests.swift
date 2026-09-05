import XCTest
import AVFoundation
import MediaPlayer
import React
@testable import SwiftAudioEx
@testable import react_native_track_player

final class IOSPlaybackBackendIntegrationTests: XCTestCase {
    func test_realStandardSeekWaitsForActualNativeCompletionExactlyOnce() throws {
        let fixture = try makeStandardSeekFixture()
        let captured = expectation(description: "AVFoundation finished the retained seek")
        fixture.gate.didCapture = { seconds in if seconds == 5 { captured.fulfill() } }
        let completed = expectation(description: "standard seek completion")
        let results = StandardSeekResults()

        onMain {
            fixture.backend.seek(to: 5) { result in
                results.append(result)
                completed.fulfill()
            }
        }
        wait(for: [captured], timeout: 10)
        XCTAssertEqual(results.count, 0, "The command completed before its actual native seek callback was delivered")

        onMain { fixture.gate.releaseFirst(seconds: 5) }
        wait(for: [completed], timeout: 5)
        XCTAssertTrue(results.succeeded)

        // Re-delivery is an explicit callback fault injection, not another seek.
        onMain { fixture.player.AVWrapper(seekTo: 5, didFinish: true) }
        drainStandardSeekEvents(fixture.player)
        XCTAssertEqual(results.count, 1)
    }

    func test_realStandardSameIndexSkipWaitsForItsExplicitInitialTime() throws {
        let fixture = try makeStandardSeekFixture()
        let captured = expectation(description: "native skip position reached")
        fixture.gate.didCapture = { seconds in if seconds == 5 { captured.fulfill() } }
        let completed = expectation(description: "skip completion")
        let results = StandardSeekResults()

        onMain {
            fixture.backend.skip(to: 0, initialTime: 5) { result in
                results.append(result)
                completed.fulfill()
            }
        }
        wait(for: [captured], timeout: 10)
        XCTAssertEqual(results.count, 0, "skip(initialTime:) completed before the native position restore")
        XCTAssertFalse(fixture.gate.capturedSeconds.contains(0), "An explicit same-index skip must not issue a redundant seek to zero")

        onMain { fixture.gate.releaseFirst(seconds: 5) }
        wait(for: [completed], timeout: 5)
        XCTAssertTrue(results.succeeded)
        XCTAssertEqual(onMain { fixture.backend.currentIndex }, 0)
    }

    func test_realStandardPauseCancelsPendingSeekAndLateCompletionCannotResume() throws {
        let fixture = try makeStandardSeekFixture()
        let captured = expectation(description: "native seek retained before pause")
        fixture.gate.didCapture = { seconds in if seconds == 5 { captured.fulfill() } }
        let results = StandardSeekResults()

        onMain {
            fixture.player.play()
            fixture.backend.seek(to: 5) { results.append($0) }
        }
        wait(for: [captured], timeout: 10)
        onMain { fixture.backend.pause() }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.failed, "A real pause must invalidate the pending seek")
        XCTAssertFalse(onMain { fixture.backend.publicPlayWhenReady })

        onMain { fixture.gate.releaseFirst(seconds: 5) }
        drainStandardSeekEvents(fixture.player)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(onMain { fixture.backend.publicPlayWhenReady }, "A late seek callback undid the explicit pause")
    }

    func test_realStandardReplacementDrainsOldSamePositionCallbackBeforeNewSeek() throws {
        let fixture = try makeStandardSeekFixture()
        let firstCaptured = expectation(description: "old item seek retained")
        fixture.gate.didCapture = { seconds in if seconds == 5 { firstCaptured.fulfill() } }
        let oldResults = StandardSeekResults()
        onMain { fixture.backend.seek(to: 5) { oldResults.append($0) } }
        wait(for: [firstCaptured], timeout: 10)

        let replacement = makeTrack(id: "replacement-same-position", url: try bundledAudioURL(), duration: 28.2)
        let secondCaptured = expectation(description: "replacement item seek retained")
        fixture.gate.didCapture = { seconds in if seconds == 5 { secondCaptured.fulfill() } }
        let newResults = StandardSeekResults()
        let newCompleted = expectation(description: "replacement seek completion")
        onMain {
            XCTAssertNoThrow(try fixture.backend.replaceQueue([replacement]))
            fixture.backend.seek(to: 5) { result in
                newResults.append(result)
                newCompleted.fulfill()
            }
        }
        XCTAssertEqual(oldResults.count, 1)
        XCTAssertTrue(oldResults.failed, "Replacing the item must cancel its admitted seek")
        XCTAssertEqual(newResults.count, 0)

        // The SDK event carries only (seconds, didFinish): both operations use 5.
        // Releasing the OLD actual callback must never complete the NEW command.
        onMain { fixture.gate.releaseFirst(seconds: 5) }
        drainStandardSeekEvents(fixture.player)
        XCTAssertEqual(newResults.count, 0, "An old callback with the same target completed the new item's seek")
        wait(for: [secondCaptured], timeout: 10)

        onMain { fixture.gate.releaseFirst(seconds: 5) }
        wait(for: [newCompleted], timeout: 5)
        XCTAssertTrue(newResults.succeeded)
        XCTAssertEqual(oldResults.count, 1)
    }

    func test_realStandardDisposalCancelsPendingSeekExactlyOnce() throws {
        let fixture = try makeStandardSeekFixture()
        let captured = expectation(description: "native seek retained before disposal")
        fixture.gate.didCapture = { seconds in if seconds == 5 { captured.fulfill() } }
        let results = StandardSeekResults()
        onMain { fixture.backend.seek(to: 5) { results.append($0) } }
        wait(for: [captured], timeout: 10)

        onMain { XCTAssertNoThrow(try fixture.backend.dispose()) }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.failed)
        onMain { fixture.gate.releaseFirst(seconds: 5) }
        drainStandardSeekEvents(fixture.player)
        XCTAssertEqual(results.count, 1)
    }

    func test_iosPlaybackStateErrorContractUsesBackendReadLease() throws {
        let source = try sourceFile("ios/RNTrackPlayer/RNTrackPlayer.swift")
        let getter = source
            .substring(after: "public func getPlaybackState")
            .substring(before: "@objc(updateMetadataForTrack")
        let stateBody = source
            .substring(after: "state: State,")
            .substring(before: "// MARK: - QueuedAudioPlayer Event Handlers")

        XCTAssertTrue(getter.contains("$0.publicPlaybackError"))
        XCTAssertFalse(getter.contains("getPlaybackStateBodyKeyValues(state: $0.playbackState)"))
        XCTAssertTrue(stateBody.contains("error: IOSPlaybackErrorSnapshot? = nil"))
        XCTAssertTrue(stateBody.contains("if state == .error"))
        XCTAssertTrue(stateBody.contains("body[\"error\"]"))
    }

    func test_realRNTrackPlayerPreservesLoadedFixtureAcrossBackendRoundTrip() throws {
        let fixtureURL = try bundledAudioURL()
        let module: RNTrackPlayer = onMain {
            let module = RNTrackPlayer()
            module.setValue(RNTrackPlayerTestEventSink.shared, forKey: "callableJSModules")
            var setupResolved = false
            module.setupPlayer(
                config: ["crossfade": false, "autoUpdateMetadata": false],
                resolve: { _ in setupResolved = true },
                reject: rejecting("setupPlayer")
            )
            XCTAssertTrue(setupResolved)
            return module
        }

        let loaded = expectation(description: "load bundled audio")
        onMain {
            module.load(
                trackDict: [
                    "id": "bundled-pure-round-trip",
                    "url": fixtureURL.absoluteString,
                    "title": "Bundled pure fixture"
                ],
                resolve: { index in
                    XCTAssertEqual((index as? NSNumber)?.intValue, 0)
                    loaded.fulfill()
                },
                reject: rejecting("load", fulfilling: loaded)
            )
        }
        wait(for: [loaded], timeout: 10)

        let pingPong = awaitBackendSwap(
            module,
            config: [
                "type": "pingPong",
                "engineMode": "orchestratedDualEngine"
            ]
        )
        XCTAssertEqual(pingPong?["backend"] as? String, "pingPong")
        XCTAssertEqual((pingPong?["queueSize"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((pingPong?["activeTrackIndex"] as? NSNumber)?.intValue, 0)

        let standard = awaitBackendSwap(module, config: ["type": "standard"])
        XCTAssertEqual(standard?["backend"] as? String, "standard")
        XCTAssertEqual((standard?["queueSize"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((standard?["activeTrackIndex"] as? NSNumber)?.intValue, 0)

        var activeTrack: [String: Any]?
        let activeTrackRead = expectation(description: "read active track after round trip")
        onMain {
            module.getActiveTrack(
                resolve: {
                    activeTrack = $0 as? [String: Any]
                    activeTrackRead.fulfill()
                },
                reject: rejecting("getActiveTrack", fulfilling: activeTrackRead)
            )
        }
        wait(for: [activeTrackRead], timeout: 2)
        XCTAssertEqual(activeTrack?["id"] as? String, "bundled-pure-round-trip")

        let reset = expectation(description: "reset RNTrackPlayer")
        onMain {
            module.reset(
                resolve: { _ in reset.fulfill() },
                reject: rejecting("reset", fulfilling: reset)
            )
        }
        wait(for: [reset], timeout: 5)
    }

    func test_realStandardCandidateRestoresIdleNonemptyQueueWithoutActiveIndex() throws {
        let fixtureURL = try bundledAudioURL()
        let track = makeTrack(id: "nil-active-standard", url: fixtureURL, duration: 28.2)
        let player = QueuedAudioPlayer()
        let snapshot = PlaybackBackendSnapshot(
            queueIDs: ["nil-active-standard"],
            activeIndex: nil,
            activeTrackID: nil,
            position: 0,
            playWhenReady: false,
            volume: 0.7,
            rate: 1,
            repeatMode: SwiftAudioEx.RepeatMode.off.rawValue,
            transitionGeneration: 0
        )
        var committedCount = 0
        var activatedCount = 0
        let candidate = StandardPlaybackBackend(
            player: player,
            transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
            automaticallyUpdateNowPlayingInfo: { false },
            onCommitted: { _ in committedCount += 1 },
            onActivated: { _ in activatedCount += 1 },
            onDisposed: { _ in },
            incomingQueue: [track],
            queueProvider: { player.items.compactMap { $0 as? Track } }
        )

        try candidate.prepareSilently(snapshot)
        try candidate.restore(snapshot)
        try candidate.prepareActivation(snapshot)
        candidate.commitQueue(snapshot)
        candidate.activateAfterCommit(snapshot)

        XCTAssertEqual(player.items.count, 1)
        XCTAssertEqual(candidate.currentIndex, -1)
        XCTAssertFalse(candidate.publicPlayWhenReady)
        XCTAssertEqual(candidate.playbackState.rawValue, State.none.rawValue)
        XCTAssertEqual(committedCount, 1)
        XCTAssertEqual(activatedCount, 1)

        let appended = makeTrack(id: "nil-active-appended", url: fixtureURL, duration: 28.2)
        let third = makeTrack(id: "nil-active-third", url: fixtureURL, duration: 28.2)
        try candidate.add([appended, third], at: 1)
        XCTAssertEqual(candidate.currentIndex, -1)
        candidate.removeUpcomingTracks()
        XCTAssertEqual(candidate.queue.map(playbackBackendTrackID), [
            "nil-active-standard", "nil-active-appended", "nil-active-third"
        ])
        try candidate.replaceQueue([track])
        XCTAssertEqual(candidate.currentIndex, -1)
        try candidate.remove(at: [0])
        XCTAssertTrue(candidate.queue.isEmpty)
        try candidate.add([appended], at: 0)
        XCTAssertEqual(candidate.currentIndex, 0)

        try candidate.restore(snapshot)
        XCTAssertEqual(candidate.currentIndex, -1)
        try candidate.replaceQueue([])
        try candidate.add([appended], at: 0)
        XCTAssertEqual(candidate.currentIndex, 0)
    }

    func test_standardQueueMutationsDoNotCreateIdleSidecarWithoutRestoredSnapshot() throws {
        let fixtureURL = try bundledAudioURL()
        let first = makeTrack(id: "normal-add", url: fixtureURL, duration: 28.2)
        let replacement = makeTrack(id: "normal-replace", url: fixtureURL, duration: 28.2)
        let player = QueuedAudioPlayer()
        let backend = StandardPlaybackBackend(
            player: player,
            transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
            automaticallyUpdateNowPlayingInfo: { false },
            onCommitted: { _ in },
            onActivated: { _ in },
            onDisposed: { _ in },
            initiallyAuthoritative: true,
            queueProvider: { player.items.compactMap { $0 as? Track } }
        )

        try backend.add([first], at: 0)
        XCTAssertEqual(backend.currentIndex, 0)
        try backend.replaceQueue([replacement])
        XCTAssertEqual(backend.currentIndex, 0)
    }

    func test_realRNTrackPlayerFirstPlayFromRestoredStandardIdlePublishesCanonicalTrackAndRemoteAvailabilityOnce() throws {
        let recorder = RecordingEventObserver()
        EventEmitter.shared.onEmit = { [weak recorder] event, body in
            recorder?.record(event: event, body: body)
        }
        defer { EventEmitter.shared.onEmit = nil }

        let fixtureURL = try bundledAudioURL()
        let module: RNTrackPlayer = onMain {
            let module = RNTrackPlayer()
            module.setValue(RNTrackPlayerTestEventSink.shared, forKey: "callableJSModules")
            module.setupPlayer(
                config: ["crossfade": true, "autoUpdateMetadata": false],
                resolve: { _ in },
                reject: rejecting("setupPlayer")
            )
            module.update(
                options: ["capabilities": ["play", "pause", "next", "previous"]],
                resolve: { _ in },
                reject: rejecting("updateOptions")
            )
            return module
        }

        let added = expectation(description: "add idle queue")
        onMain {
            module.add(
                trackDicts: [
                    ["id": "idle-first", "url": fixtureURL.absoluteString, "duration": 28.2],
                    ["id": "idle-second", "url": fixtureURL.absoluteString, "duration": 28.2]
                ],
                before: -1,
                resolve: { _ in added.fulfill() },
                reject: rejecting("add", fulfilling: added)
            )
        }
        wait(for: [added], timeout: 5)

        let lifecycle = awaitBackendSwap(module, config: ["type": "standard"])
        XCTAssertTrue(lifecycle?["activeTrackIndex"] is NSNull)
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        XCTAssertFalse(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
        recorder.reset()

        let played = expectation(description: "play restored standard idle queue")
        onMain {
            module.play(
                resolve: { _ in
                    let activeEvents = recorder.events(for: .PlaybackActiveTrackChanged)
                    XCTAssertEqual(activeEvents.count, 1)
                    XCTAssertEqual(activeEvents.first?["index"] as? Int, 0)
                    XCTAssertEqual(
                        (activeEvents.first?["track"] as? [String: Any])?["id"] as? String,
                        "idle-first"
                    )
                    XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
                    XCTAssertFalse(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
                    played.fulfill()
                },
                reject: rejecting("play", fulfilling: played)
            )
        }
        wait(for: [played], timeout: 5)

        let duplicateWindow = expectation(description: "no duplicate canonical active-track event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { duplicateWindow.fulfill() }
        wait(for: [duplicateWindow], timeout: 1)
        XCTAssertEqual(recorder.events(for: .PlaybackActiveTrackChanged).count, 1)

        let reset = expectation(description: "reset idle activation module")
        onMain {
            module.reset(
                resolve: { _ in reset.fulfill() },
                reject: rejecting("reset", fulfilling: reset)
            )
        }
        wait(for: [reset], timeout: 5)
    }

    func test_standardIdleSkipNextActivatesIndexZeroAndPreviousRejects() throws {
        let fixtureURL = try bundledAudioURL()
        let tracks = [
            makeTrack(id: "idle-skip-first", url: fixtureURL, duration: 28.2),
            makeTrack(id: "idle-skip-second", url: fixtureURL, duration: 28.2)
        ]
        let player = QueuedAudioPlayer()
        let snapshot = PlaybackBackendSnapshot(
            queueIDs: tracks.map(playbackBackendTrackID),
            activeIndex: nil,
            activeTrackID: nil,
            position: 0,
            playWhenReady: false,
            volume: 1,
            rate: 1,
            repeatMode: SwiftAudioEx.RepeatMode.off.rawValue,
            transitionGeneration: 0
        )
        let candidate = StandardPlaybackBackend(
            player: player,
            transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
            automaticallyUpdateNowPlayingInfo: { false },
            onCommitted: { _ in },
            onActivated: { _ in },
            onDisposed: { _ in },
            incomingQueue: tracks,
            queueProvider: { player.items.compactMap { $0 as? Track } }
        )
        try candidate.prepareSilently(snapshot)
        try candidate.restore(snapshot)
        try candidate.prepareActivation(snapshot)
        candidate.commitQueue(snapshot)
        candidate.activateAfterCommit(snapshot)

        var nextResult: Result<Void, Error>?
        candidate.skipToNext(initialTime: -1) { nextResult = $0 }
        XCTAssertNoThrow(try nextResult?.get())
        XCTAssertEqual(candidate.currentIndex, 0)

        try candidate.restore(snapshot)
        XCTAssertEqual(candidate.currentIndex, -1)
        var previousResult: Result<Void, Error>?
        candidate.skipToPrevious(initialTime: -1) { previousResult = $0 }
        XCTAssertThrowsError(try previousResult?.get()) { error in
            XCTAssertEqual((error as NSError).userInfo["code"] as? String, "index_out_of_bounds")
        }
        XCTAssertEqual(candidate.currentIndex, -1)
    }

    func test_realStandardFinalRebaseUpdatesPositionWithoutReloadingSameQueue() throws {
        let fixtureURL = try bundledAudioURL()
        let track = makeTrack(
            id: "standard-idempotent-rebase",
            url: fixtureURL,
            duration: 28.2
        )
        let finished = expectation(description: "real standard final rebase")
        let result = ObjectBox<Result<StandardRebaseObservation, Error>>()

        DispatchQueue.global(qos: .userInitiated).async {
            let player = QueuedAudioPlayer()
            let initial = PlaybackBackendSnapshot(
                queueIDs: ["standard-idempotent-rebase"],
                activeIndex: 0,
                activeTrackID: "standard-idempotent-rebase",
                position: 0,
                playWhenReady: false,
                volume: 0.65,
                rate: 1,
                repeatMode: SwiftAudioEx.RepeatMode.off.rawValue,
                transitionGeneration: 3
            )
            let final = PlaybackBackendSnapshot(
                queueIDs: initial.queueIDs,
                activeIndex: 0,
                activeTrackID: initial.activeTrackID,
                position: 3,
                playWhenReady: false,
                volume: initial.volume,
                rate: initial.rate,
                repeatMode: initial.repeatMode,
                transitionGeneration: initial.transitionGeneration
            )
            let candidate = StandardPlaybackBackend(
                player: player,
                transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
                automaticallyUpdateNowPlayingInfo: { false },
                onCommitted: { _ in },
                onActivated: { _ in },
                onDisposed: { _ in },
                incomingQueueProvider: { [track] },
                queueProvider: { player.items.compactMap { $0 as? Track } }
            )

            do {
                try candidate.prepareSilently(initial)
                try candidate.restore(initial)
                try candidate.prepareActivation(initial)
                let loadedTrack = player.items.first as? Track

                try candidate.prepareSilently(final)
                try candidate.restore(final)
                try candidate.prepareActivation(final)

                result.value = .success(StandardRebaseObservation(
                    queueReloadCount: candidate.queueReloadCount,
                    retainedTrackObject: (player.items.first as? Track) === loadedTrack,
                    position: candidate.position
                ))
                try candidate.dispose()
            } catch {
                result.value = .failure(error)
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 15)
        switch try XCTUnwrap(result.value) {
        case .failure(let error):
            XCTFail("real standard final rebase failed: \(error)")
        case .success(let observation):
            XCTAssertEqual(observation.queueReloadCount, 1)
            XCTAssertTrue(observation.retainedTrackObject)
            XCTAssertEqual(observation.position, 3, accuracy: 0.75)
        }
    }

    func test_realPingPongFinalRebaseUpdatesPositionWithoutResettingSameQueue() throws {
        let fixtureURL = try bundledAudioURL()
        let track = makeTrack(
            id: "ping-pong-idempotent-rebase",
            url: fixtureURL,
            duration: 28.2
        )
        let finished = expectation(description: "real ping-pong final rebase")
        let result = ObjectBox<Result<PingPongRebaseObservation, Error>>()

        DispatchQueue.global(qos: .userInitiated).async {
            let player = QueuedAudioPlayer()
            let orchestrator = IOSPlaybackOrchestrator()
            let initial = PlaybackBackendSnapshot(
                queueIDs: ["ping-pong-idempotent-rebase"],
                activeIndex: 0,
                activeTrackID: "ping-pong-idempotent-rebase",
                position: 0,
                playWhenReady: false,
                volume: 0.55,
                rate: 1,
                repeatMode: SwiftAudioEx.RepeatMode.off.rawValue,
                transitionGeneration: 4
            )
            let final = PlaybackBackendSnapshot(
                queueIDs: initial.queueIDs,
                activeIndex: 0,
                activeTrackID: initial.activeTrackID,
                position: 3,
                playWhenReady: false,
                volume: initial.volume,
                rate: initial.rate,
                repeatMode: initial.repeatMode,
                transitionGeneration: initial.transitionGeneration
            )
            let candidate = PingPongPlaybackBackend(
                player: player,
                orchestrator: orchestrator,
                transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
                onCommitted: { _, _ in },
                onActivated: { _ in },
                onDisposed: { _, _ in },
                queueProvider: { [track] }
            )

            do {
                try candidate.prepareSilently(initial)
                try candidate.restore(initial)
                try candidate.prepareActivation(initial)

                try candidate.prepareSilently(final)
                try candidate.restore(final)
                try candidate.prepareActivation(final)

                result.value = .success(PingPongRebaseObservation(
                    queueResetCount: candidate.queueResetCount,
                    retainedTrackObject: orchestrator.currentTrack === track,
                    position: candidate.position
                ))
                try candidate.dispose()
            } catch {
                result.value = .failure(error)
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 20)
        switch try XCTUnwrap(result.value) {
        case .failure(let error):
            XCTFail("real ping-pong final rebase failed: \(error)")
        case .success(let observation):
            XCTAssertEqual(observation.queueResetCount, 1)
            XCTAssertTrue(observation.retainedTrackObject)
            XCTAssertEqual(observation.position, 3, accuracy: 0.75)
        }
    }

    func test_realPingPongQuiescenceSuppressesTransientStateBeforeCanonicalResume() {
        let track = makeTrack(id: "ping-pong-event-quarantine")
        let player = QueuedAudioPlayer()
        let orchestrator = IOSPlaybackOrchestrator()
        let delegate = RecordingOrchestratorDelegate()
        var committedCount = 0
        var canonicalResumeCount = 0
        let backend = PingPongPlaybackBackend(
            player: player,
            orchestrator: orchestrator,
            transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
            onCommitted: { committed, _ in
                committedCount += 1
                committed.delegate = delegate
            },
            onActivated: { _ in canonicalResumeCount += 1 },
            onDisposed: { _, _ in },
            initiallyAuthoritative: true,
            queueProvider: { [track] }
        )
        orchestrator.replaceQueue([track], currentIndex: 0)
        orchestrator.delegate = delegate
        delegate.states.removeAll()

        XCTAssertNoThrow(try backend.suspendEventDeliveryForHandoff())
        let snapshot = try? backend.beginHandoffQuiescence()
        XCTAssertNotNil(snapshot)
        if let snapshot {
            XCTAssertNoThrow(try backend.cancelHandoffQuiescence(snapshot))
            backend.resumeEventDeliveryAfterHandoff(snapshot)
        }

        XCTAssertTrue(delegate.states.isEmpty)
        XCTAssertEqual(committedCount, 1)
        XCTAssertEqual(canonicalResumeCount, 1)
        XCTAssertNoThrow(try backend.dispose())
    }

    func test_realOrchestratorQueueSyncRetainsPlayingTrackAndReschedulesEndObservation() throws {
        let fixtureURL = try bundledAudioURL()
        let active = makeTrack(id: "retained-playing", url: fixtureURL, duration: 28.2)
        let nonCrossfadeNext = makeTrack(
            id: "non-crossfade-next",
            url: fixtureURL,
            duration: 0,
            isLiveStream: true
        )
        let orchestrator = IOSPlaybackOrchestrator()
        let played = expectation(description: "orchestrator playing")
        let playResult = ObjectBox<Result<Void, Error>>()
        orchestrator.replaceQueue([active], currentIndex: 0)

        orchestrator.play {
            playResult.value = $0
            played.fulfill()
        }
        wait(for: [played], timeout: 10)
        if case .failure(let error) = try XCTUnwrap(playResult.value) {
            XCTFail("real orchestrator failed to play: \(error)")
        }
        XCTAssertTrue(orchestrator.playWhenReady)
        XCTAssertEqual(orchestrator.state, .playingSingle)
        XCTAssertTrue(orchestrator.isEndObservationScheduled)

        orchestrator.setQueue([active, nonCrossfadeNext])

        XCTAssertTrue(orchestrator.currentTrack === active)
        XCTAssertEqual(orchestrator.currentIndex, 0)
        XCTAssertTrue(orchestrator.playWhenReady)
        XCTAssertEqual(orchestrator.state, .playingSingle)
        XCTAssertTrue(orchestrator.isEndObservationScheduled)

        orchestrator.settleActiveTransition()

        XCTAssertTrue(orchestrator.playWhenReady)
        XCTAssertEqual(orchestrator.state, .playingSingle)
        XCTAssertTrue(orchestrator.isEndObservationScheduled)
        orchestrator.pause()
    }

    func test_realOrchestratorQueueSyncPromotesRetainedIncomingCrossfadeTrack() throws {
        let fixtureURL = try bundledAudioURL()
        let outgoing = makeTrack(id: "crossfade-outgoing", url: fixtureURL, duration: 28.2)
        let incoming = makeTrack(id: "crossfade-incoming", url: fixtureURL, duration: 28.2)
        let nonCrossfadeNext = makeTrack(
            id: "crossfade-new-next",
            url: fixtureURL,
            duration: 0,
            isLiveStream: true
        )
        let orchestrator = IOSPlaybackOrchestrator()
        let delegate = RecordingOrchestratorDelegate()
        orchestrator.delegate = delegate
        orchestrator.replaceQueue([outgoing, incoming], currentIndex: 0)

        let played = expectation(description: "crossfade source playing")
        orchestrator.play { result in
            if case .failure(let error) = result {
                XCTFail("crossfade source failed to play: \(error)")
            }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)

        let prepared = expectation(description: "crossfade target prepared")
        orchestrator.prepareCrossfade(previous: false, seekTo: 0) { result in
            if case .failure(let error) = result {
                XCTFail("crossfade target failed to prepare: \(error)")
            }
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 10)

        let started = expectation(description: "crossfade started")
        delegate.onCrossfadeState = { state, _ in
            if state == "started" { started.fulfill() }
        }
        let crossfadeFinished = expectation(description: "crossfade cancelled by queue sync")
        let crossfadeResult = ObjectBox<Result<Void, Error>>()
        orchestrator.crossFade(
            fadeDuration: 10_000,
            fadeInterval: 100,
            fadeToVolume: 1,
            waitUntil: 0
        ) {
            crossfadeResult.value = $0
            crossfadeFinished.fulfill()
        }
        wait(for: [started], timeout: 10)
        XCTAssertEqual(orchestrator.state, .crossfading)
        XCTAssertTrue(orchestrator.currentTrack === incoming)
        let activeTrackChangeCountBeforeQueueSync = delegate.activeTrackChanges.count

        orchestrator.setQueue([incoming, nonCrossfadeNext])
        wait(for: [crossfadeFinished], timeout: 2)

        if case .success = try XCTUnwrap(crossfadeResult.value) {
            XCTFail("queue sync unexpectedly completed the active crossfade")
        }
        XCTAssertTrue(orchestrator.currentTrack === incoming)
        XCTAssertEqual(orchestrator.currentIndex, 0)
        XCTAssertTrue(orchestrator.playWhenReady)
        XCTAssertEqual(orchestrator.state, .playingSingle)
        XCTAssertEqual(orchestrator.logicalEngineOutputVolume, 1, accuracy: 0.001)
        XCTAssertTrue(orchestrator.isEndObservationScheduled)
        XCTAssertEqual(
            delegate.activeTrackChanges.count,
            activeTrackChangeCountBeforeQueueSync + 1
        )
        XCTAssertEqual(delegate.activeTrackChanges.last!, 0)
        XCTAssertEqual(delegate.activeTrackLastIndexes.last!, 1)
        XCTAssertTrue(delegate.activeTrackLastTracks.last! === incoming)
        XCTAssertEqual(delegate.crossfadeEvents.filter {
            $0.state == "cancelled" && $0.errorCode == "queue_changed"
        }.count, 1)
        orchestrator.pause()
    }

    func test_awakenedScheduledCrossfadeTimerCannotRacePauseCancellation() throws {
        try assertAwakenedScheduledCrossfadeCancellation(.pause)
    }

    func test_awakenedScheduledCrossfadeTimerCannotRaceBackendSwapCancellation() throws {
        try assertAwakenedScheduledCrossfadeCancellation(.backendSwap)
    }

    func test_awakenedScheduledCrossfadeTimerCannotRaceQueueCancellation() throws {
        try assertAwakenedScheduledCrossfadeCancellation(.queueChange)
    }

    func test_awakenedScheduledCrossfadeTimerCannotRaceSeekCancellation() throws {
        try assertAwakenedScheduledCrossfadeCancellation(.seek)
    }

    func test_activeTrackRemapPayloadUsesCapturedPreviousTrack() throws {
        let fixtureURL = try bundledAudioURL()
        let retained = makeTrack(id: "payload-retained", url: fixtureURL, duration: 28.2)
        let unrelated = makeTrack(id: "payload-unrelated", url: fixtureURL, duration: 28.2)

        let body = orchestratedActiveTrackEventBody(
            index: 0,
            lastIndex: 1,
            lastTrack: retained,
            lastPosition: 4.25,
            queue: [retained, unrelated]
        )

        XCTAssertEqual(body["index"] as? Int, 0)
        XCTAssertEqual(body["lastIndex"] as? Int, 1)
        XCTAssertEqual((body["track"] as? [String: Any])?["id"] as? String, "payload-retained")
        XCTAssertEqual((body["lastTrack"] as? [String: Any])?["id"] as? String, "payload-retained")
    }

    func test_realCrossfadePreparationAndStartShareOneExclusiveSlot() throws {
        let fixtureURL = try bundledAudioURL()
        let first = makeTrack(id: "prepare-race-first", url: fixtureURL, duration: 28.2)
        let middle = makeTrack(id: "prepare-race-middle", url: fixtureURL, duration: 28.2)
        let third = makeTrack(id: "prepare-race-third", url: fixtureURL, duration: 28.2)
        let orchestrator = IOSPlaybackOrchestrator()
        orchestrator.replaceQueue([first, middle, third], currentIndex: 1)

        let played = expectation(description: "prepare race source playing")
        orchestrator.play { result in
            if case .failure(let error) = result {
                XCTFail("prepare race source failed to play: \(error)")
            }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)

        let preparationFinished = expectation(description: "inflight preparation finishes")
        let preparedCrossfadeFinished = expectation(description: "prepared crossfade finishes")
        var preparationCompletionCount = 0
        let preparationResult = ObjectBox<Result<Void, Error>>()
        let preparedCrossfadeResult = ObjectBox<Result<Void, Error>>()
        orchestrator.prepareCrossfade(previous: true, seekTo: 0) { result in
            preparationCompletionCount += 1
            preparationResult.value = result
            orchestrator.crossFade(
                fadeDuration: 50,
                fadeInterval: 10,
                fadeToVolume: 1,
                waitUntil: 0
            ) {
                preparedCrossfadeResult.value = $0
                preparedCrossfadeFinished.fulfill()
            }
            preparationFinished.fulfill()
        }

        let overlappingCrossfadeFinished = expectation(description: "overlapping crossfade rejected")
        let overlappingCrossfadeResult = ObjectBox<Result<Void, Error>>()
        orchestrator.crossFade(
            fadeDuration: 50,
            fadeInterval: 10,
            fadeToVolume: 1,
            waitUntil: 0
        ) {
            overlappingCrossfadeResult.value = $0
            overlappingCrossfadeFinished.fulfill()
        }

        wait(
            for: [preparationFinished, overlappingCrossfadeFinished, preparedCrossfadeFinished],
            timeout: 10
        )
        XCTAssertEqual(preparationCompletionCount, 1)
        XCTAssertNoThrow(try XCTUnwrap(preparationResult.value).get())
        XCTAssertThrowsError(try XCTUnwrap(overlappingCrossfadeResult.value).get()) { error in
            XCTAssertEqual((error as NSError).userInfo["code"] as? String, "crossfade_in_progress")
        }
        XCTAssertNoThrow(try XCTUnwrap(preparedCrossfadeResult.value).get())
        orchestrator.pause()
    }

    func test_postCrossfadeMaintenanceCannotSupersedeExplicitPreparation() throws {
        let fixtureURL = try bundledAudioURL()
        let previous = makeTrack(id: "maintenance-previous", url: fixtureURL, duration: 28.2)
        let current = makeTrack(id: "maintenance-current", url: fixtureURL, duration: 28.2)
        let next = makeTrack(id: "maintenance-next", url: fixtureURL, duration: 28.2)
        var holdExplicitPrevious = false
        var explicitNativeStart: (() -> Void)?
        var maintenanceWorkItem: DispatchWorkItem?
        let maintenanceEntered = DispatchSemaphore(value: 0)
        let releaseMaintenance = DispatchSemaphore(value: 0)
        let explicitPrepareObservedBeforeRelease = expectation(
            description: "explicit native prepare observed before maintenance release"
        )
        let explicitPrepareStarted = expectation(description: "explicit native prepare started")
        let orchestrator = IOSPlaybackOrchestrator(
            standbyPrepareOperation: { engine, track, position, completion in
                if holdExplicitPrevious && track === previous {
                    explicitNativeStart = {
                        engine.prepare(track: track, position: position, completion: completion)
                    }
                    explicitPrepareObservedBeforeRelease.fulfill()
                    explicitPrepareStarted.fulfill()
                } else {
                    engine.prepare(track: track, position: position, completion: completion)
                }
            },
            standbyMaintenanceScheduler: { _, workItem in
                maintenanceWorkItem = workItem
            },
            standbyMaintenanceAfterValidationHook: {
                maintenanceEntered.signal()
                _ = releaseMaintenance.wait(timeout: .now() + 5)
            }
        )
        orchestrator.replaceQueue([previous, current, next], currentIndex: 0)

        let played = expectation(description: "maintenance source playing")
        orchestrator.play { result in
            if case .failure(let error) = result {
                XCTFail("maintenance source failed to play: \(error)")
            }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)

        let firstPreparation = expectation(description: "first crossfade prepared")
        orchestrator.prepareCrossfade(previous: false, seekTo: 0) { result in
            if case .failure(let error) = result {
                XCTFail("first crossfade failed to prepare: \(error)")
            }
            firstPreparation.fulfill()
        }
        wait(for: [firstPreparation], timeout: 10)

        let firstCrossfade = expectation(description: "first crossfade completed")
        orchestrator.crossFade(
            fadeDuration: 50,
            fadeInterval: 10,
            fadeToVolume: 1,
            waitUntil: 0
        ) { result in
            if case .failure(let error) = result {
                XCTFail("first crossfade failed: \(error)")
            }
            firstCrossfade.fulfill()
        }
        wait(for: [firstCrossfade], timeout: 10)
        XCTAssertNotNil(maintenanceWorkItem)

        holdExplicitPrevious = true
        let maintenanceFinished = expectation(description: "maintenance work item returned")
        DispatchQueue.global(qos: .userInitiated).async {
            maintenanceWorkItem?.perform()
            maintenanceFinished.fulfill()
        }
        XCTAssertEqual(maintenanceEntered.wait(timeout: .now() + 2), .success)

        let explicitPreparation = expectation(description: "explicit preparation completed")
        let explicitResult = ObjectBox<Result<Void, Error>>()
        let explicitAttempted = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            explicitAttempted.signal()
            orchestrator.prepareCrossfade(previous: true, seekTo: 2) {
                explicitResult.value = $0
                explicitPreparation.fulfill()
            }
        }
        XCTAssertEqual(explicitAttempted.wait(timeout: .now() + 2), .success)

        // Give an unlocked implementation ample time to admit the explicit command
        // while maintenance is paused after its guard. A locked implementation keeps
        // the command at the critical-section boundary until maintenance is released.
        let explicitStartedBeforeMaintenanceRelease = XCTWaiter.wait(
            for: [explicitPrepareObservedBeforeRelease],
            timeout: 0.25
        ) == .completed
        releaseMaintenance.signal()
        if !explicitStartedBeforeMaintenanceRelease {
            wait(for: [explicitPrepareStarted], timeout: 5)
        }
        explicitNativeStart?()

        wait(for: [maintenanceFinished, explicitPreparation], timeout: 10)
        XCTAssertNoThrow(try XCTUnwrap(explicitResult.value).get())

        holdExplicitPrevious = false
        let acceptedCrossfade = expectation(description: "crossfade accepted after preparation")
        let acceptedCrossfadeResult = ObjectBox<Result<Void, Error>>()
        orchestrator.crossFade(
            fadeDuration: 50,
            fadeInterval: 10,
            fadeToVolume: 1,
            waitUntil: 0
        ) {
            acceptedCrossfadeResult.value = $0
            acceptedCrossfade.fulfill()
        }
        wait(for: [acceptedCrossfade], timeout: 10)
        XCTAssertNoThrow(try XCTUnwrap(acceptedCrossfadeResult.value).get())
        orchestrator.pause()
    }

    func test_crossfadeRampCannotRewriteVolumeAfterConcurrentPromotion() throws {
        let fixtureURL = try bundledAudioURL()
        let outgoing = makeTrack(id: "ramp-race-outgoing", url: fixtureURL, duration: 28.2)
        let incoming = makeTrack(id: "ramp-race-incoming", url: fixtureURL, duration: 28.2)
        let replacement = makeTrack(
            id: "ramp-race-replacement",
            url: fixtureURL,
            duration: 0,
            isLiveStream: true
        )
        let rampEntered = DispatchSemaphore(value: 0)
        let releaseRamp = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var shouldBlockRamp = true
        let orchestrator = IOSPlaybackOrchestrator(
            crossfadeRampAfterValidationHook: {
                hookLock.lock()
                let shouldBlock = shouldBlockRamp
                shouldBlockRamp = false
                hookLock.unlock()
                guard shouldBlock else { return }
                rampEntered.signal()
                _ = releaseRamp.wait(timeout: .now() + 5)
            }
        )
        let delegate = RecordingOrchestratorDelegate()
        orchestrator.delegate = delegate
        orchestrator.replaceQueue([outgoing, incoming], currentIndex: 0)

        let played = expectation(description: "ramp race source playing")
        orchestrator.play { result in
            if case .failure(let error) = result {
                XCTFail("ramp race source failed to play: \(error)")
            }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)

        let prepared = expectation(description: "ramp race target prepared")
        orchestrator.prepareCrossfade(previous: false, seekTo: 0) { result in
            if case .failure(let error) = result {
                XCTFail("ramp race target failed to prepare: \(error)")
            }
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 10)

        let promotionFinished = DispatchSemaphore(value: 0)
        let controllerFinished = expectation(description: "ramp race controller finished")
        let observationLock = NSLock()
        var promotionCompletedBeforeRampRelease = false
        DispatchQueue.global(qos: .userInitiated).async {
            guard rampEntered.wait(timeout: .now() + 10) == .success else {
                releaseRamp.signal()
                controllerFinished.fulfill()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                orchestrator.setQueue([incoming, replacement])
                promotionFinished.signal()
            }
            let completedEarly = promotionFinished.wait(timeout: .now() + 0.25) == .success
            observationLock.lock()
            promotionCompletedBeforeRampRelease = completedEarly
            observationLock.unlock()
            releaseRamp.signal()
            if !completedEarly {
                _ = promotionFinished.wait(timeout: .now() + 5)
            }
            controllerFinished.fulfill()
        }

        let crossfadeFinished = expectation(description: "ramp race crossfade cancelled once")
        var crossfadeCompletionCount = 0
        let crossfadeResult = ObjectBox<Result<Void, Error>>()
        orchestrator.crossFade(
            fadeDuration: 10_000,
            fadeInterval: 100,
            fadeToVolume: 1,
            waitUntil: 0
        ) {
            crossfadeCompletionCount += 1
            crossfadeResult.value = $0
            crossfadeFinished.fulfill()
        }

        wait(for: [controllerFinished, crossfadeFinished], timeout: 15)
        observationLock.lock()
        let completedBeforeRelease = promotionCompletedBeforeRampRelease
        observationLock.unlock()
        XCTAssertFalse(completedBeforeRelease)
        XCTAssertEqual(crossfadeCompletionCount, 1)
        XCTAssertThrowsError(try XCTUnwrap(crossfadeResult.value).get())
        XCTAssertTrue(orchestrator.currentTrack === incoming)
        XCTAssertEqual(orchestrator.currentIndex, 0)
        XCTAssertEqual(orchestrator.logicalEngineOutputVolume, 1, accuracy: 0.001)
        XCTAssertEqual(delegate.crossfadeEvents.filter {
            $0.state == "cancelled" && $0.errorCode == "queue_changed"
        }.count, 1)
        orchestrator.pause()
    }

    func test_runningEventCannotFollowConcurrentCrossfadeCancellation() throws {
        let fixtureURL = try bundledAudioURL()
        let outgoing = makeTrack(id: "event-race-outgoing", url: fixtureURL, duration: 28.2)
        let incoming = makeTrack(id: "event-race-incoming", url: fixtureURL, duration: 28.2)
        let replacement = makeTrack(
            id: "event-race-replacement",
            url: fixtureURL,
            duration: 0,
            isLiveStream: true
        )
        let runningDeliveryEntered = DispatchSemaphore(value: 0)
        let releaseRunningDelivery = DispatchSemaphore(value: 0)
        let orchestrator = IOSPlaybackOrchestrator(
            crossfadeRunningBeforeDeliveryHook: {
                runningDeliveryEntered.signal()
                _ = releaseRunningDelivery.wait(timeout: .now() + 2)
            }
        )
        let delegate = RecordingOrchestratorDelegate()
        orchestrator.delegate = delegate
        orchestrator.replaceQueue([outgoing, incoming], currentIndex: 0)

        let played = expectation(description: "event race source playing")
        orchestrator.play { result in
            if case .failure(let error) = result { XCTFail("play failed: \(error)") }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)

        let prepared = expectation(description: "event race target prepared")
        orchestrator.prepareCrossfade(previous: false, seekTo: 0) { result in
            if case .failure(let error) = result { XCTFail("prepare failed: \(error)") }
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 10)

        let queueMutationFinished = expectation(description: "event race queue mutation finished")
        DispatchQueue.global(qos: .userInitiated).async {
            guard runningDeliveryEntered.wait(timeout: .now() + 10) == .success else {
                releaseRunningDelivery.signal()
                queueMutationFinished.fulfill()
                return
            }
            orchestrator.setQueue([incoming, replacement])
            releaseRunningDelivery.signal()
            queueMutationFinished.fulfill()
        }

        let crossfadeFinished = expectation(description: "event race crossfade cancelled")
        let crossfadeResult = ObjectBox<Result<Void, Error>>()
        orchestrator.crossFade(
            fadeDuration: 10_000,
            fadeInterval: 100,
            fadeToVolume: 1,
            waitUntil: 0
        ) {
            crossfadeResult.value = $0
            crossfadeFinished.fulfill()
        }
        wait(for: [queueMutationFinished, crossfadeFinished], timeout: 15)

        XCTAssertThrowsError(try XCTUnwrap(crossfadeResult.value).get())
        let states = delegate.crossfadeEvents.map(\.state)
        let cancelledIndex = try XCTUnwrap(states.lastIndex(of: "cancelled"))
        XCTAssertFalse(states.dropFirst(cancelledIndex + 1).contains("running"))
        orchestrator.pause()
    }

    func test_crossfadeCommitClaimsSuccessBeforeConcurrentCancellation() throws {
        let fixtureURL = try bundledAudioURL()
        let outgoing = makeTrack(id: "terminal-race-outgoing", url: fixtureURL, duration: 28.2)
        let incoming = makeTrack(id: "terminal-race-incoming", url: fixtureURL, duration: 28.2)
        let replacement = makeTrack(
            id: "terminal-race-replacement",
            url: fixtureURL,
            duration: 0,
            isLiveStream: true
        )
        let finishCommitted = DispatchSemaphore(value: 0)
        let releaseFinishDelivery = DispatchSemaphore(value: 0)
        let orchestrator = IOSPlaybackOrchestrator(
            crossfadeFinishAfterCommitHook: {
                finishCommitted.signal()
                _ = releaseFinishDelivery.wait(timeout: .now() + 2)
            }
        )
        let delegate = RecordingOrchestratorDelegate()
        orchestrator.delegate = delegate
        orchestrator.replaceQueue([outgoing, incoming], currentIndex: 0)

        let played = expectation(description: "terminal race source playing")
        orchestrator.play { result in
            if case .failure(let error) = result { XCTFail("play failed: \(error)") }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)

        let prepared = expectation(description: "terminal race target prepared")
        orchestrator.prepareCrossfade(previous: false, seekTo: 0) { result in
            if case .failure(let error) = result { XCTFail("prepare failed: \(error)") }
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 10)

        let queueMutationFinished = expectation(description: "terminal race queue mutation finished")
        DispatchQueue.global(qos: .userInitiated).async {
            guard finishCommitted.wait(timeout: .now() + 10) == .success else {
                releaseFinishDelivery.signal()
                queueMutationFinished.fulfill()
                return
            }
            orchestrator.setQueue([incoming, replacement])
            releaseFinishDelivery.signal()
            queueMutationFinished.fulfill()
        }

        let crossfadeFinished = expectation(description: "terminal race crossfade resolved")
        let crossfadeResult = ObjectBox<Result<Void, Error>>()
        orchestrator.crossFade(
            fadeDuration: 50,
            fadeInterval: 10,
            fadeToVolume: 1,
            waitUntil: 0
        ) {
            crossfadeResult.value = $0
            crossfadeFinished.fulfill()
        }
        wait(for: [queueMutationFinished, crossfadeFinished], timeout: 15)

        XCTAssertNoThrow(try XCTUnwrap(crossfadeResult.value).get())
        XCTAssertEqual(delegate.crossfadeEvents.filter { $0.state == "completed" }.count, 1)
        XCTAssertFalse(delegate.crossfadeEvents.contains { $0.state == "cancelled" })
        XCTAssertTrue(orchestrator.currentTrack === incoming)
        orchestrator.pause()
    }

    func test_staleStandbyInvocationCannotResetNewActiveLoad() throws {
        let fixtureURL = try bundledAudioURL()
        let first = makeTrack(id: "stale-native-first", url: fixtureURL, duration: 28.2)
        let second = makeTrack(id: "stale-native-second", url: fixtureURL, duration: 28.2)
        let third = makeTrack(id: "stale-native-third", url: fixtureURL, duration: 28.2)
        let staleInvocationEntered = DispatchSemaphore(value: 0)
        let releaseStaleInvocation = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var blockNextInvocation = false
        var countStaleInvocations = false
        var staleNativeInvocationCount = 0
        let orchestrator = IOSPlaybackOrchestrator(
            standbyPrepareOperation: { engine, track, position, completion in
                hookLock.lock()
                let isStaleTarget = countStaleInvocations && track === third
                if isStaleTarget { staleNativeInvocationCount += 1 }
                hookLock.unlock()
                guard !isStaleTarget else {
                    completion(.failure(NSError(
                        domain: "RNTP-Stale-Native-Test",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Stale standby invocation executed."]
                    )))
                    return
                }
                engine.prepare(track: track, position: position, completion: completion)
            },
            standbyMaintenanceScheduler: { _, _ in },
            standbyPreparationBeforeNativeInvocationHook: {
                hookLock.lock()
                let shouldBlock = blockNextInvocation
                blockNextInvocation = false
                hookLock.unlock()
                guard shouldBlock else { return }
                staleInvocationEntered.signal()
                _ = releaseStaleInvocation.wait(timeout: .now() + 2)
            }
        )
        orchestrator.replaceQueue([first, second, third], currentIndex: 0)

        let played = expectation(description: "stale native source playing")
        orchestrator.play { result in
            if case .failure(let error) = result { XCTFail("play failed: \(error)") }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)

        let prepared = expectation(description: "stale native first target prepared")
        orchestrator.prepareCrossfade(previous: false, seekTo: 0) { result in
            if case .failure(let error) = result { XCTFail("prepare failed: \(error)") }
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 10)

        let firstCrossfade = expectation(description: "stale native first crossfade completed")
        orchestrator.crossFade(
            fadeDuration: 50,
            fadeInterval: 10,
            fadeToVolume: 1,
            waitUntil: 0
        ) { result in
            if case .failure(let error) = result { XCTFail("crossfade failed: \(error)") }
            firstCrossfade.fulfill()
        }
        wait(for: [firstCrossfade], timeout: 10)

        hookLock.lock()
        blockNextInvocation = true
        countStaleInvocations = true
        hookLock.unlock()
        let stalePreparationCancelled = expectation(description: "stale preparation cancelled")
        orchestrator.prepareCrossfade(previous: false, seekTo: 0) { result in
            if case .success = result { XCTFail("stale preparation unexpectedly succeeded") }
            stalePreparationCancelled.fulfill()
        }

        let activeLoadFinished = expectation(description: "new active load retained callback")
        let activeLoadResult = ObjectBox<Result<Void, Error>>()
        DispatchQueue.global(qos: .userInitiated).async {
            guard staleInvocationEntered.wait(timeout: .now() + 10) == .success else {
                releaseStaleInvocation.signal()
                return
            }
            orchestrator.skip(to: 0, initialTime: 1) {
                activeLoadResult.value = $0
                activeLoadFinished.fulfill()
            }
            releaseStaleInvocation.signal()
        }

        wait(for: [stalePreparationCancelled, activeLoadFinished], timeout: 10)
        XCTAssertNoThrow(try XCTUnwrap(activeLoadResult.value).get())
        hookLock.lock()
        let staleInvocationCount = staleNativeInvocationCount
        hookLock.unlock()
        XCTAssertEqual(staleInvocationCount, 0)
        XCTAssertTrue(orchestrator.currentTrack === first)
        XCTAssertEqual(orchestrator.currentIndex, 0)
        orchestrator.pause()
    }

    func test_realStandardToPingPongSwapPublishesAuthorityBeforeActivationCallbacks() throws {
        let authority = PlaybackBackendAuthority()
        let sidecar = PlaybackTransitionGenerationSidecar()
        let player = QueuedAudioPlayer()
        let delegate = RecordingOrchestratorDelegate()
        let facadeBox = ObjectBox<PlaybackBackendFacade>()
        var trace: [String] = []

        let initial = StandardPlaybackBackend(
            player: player,
            transitionGenerationSidecar: sidecar,
            automaticallyUpdateNowPlayingInfo: { false },
            onCommitted: { committed in
                XCTAssertTrue(authority.isAuthoritative(.standard, identity: committed))
                trace.append("standard.committed")
            },
            onActivated: { committed in
                XCTAssertTrue(authority.isAuthoritative(.standard, identity: committed))
                trace.append("standard.activated")
            },
            onDisposed: { _ in trace.append("standard.disposed") },
            initiallyAuthoritative: true,
            queueProvider: { [] }
        )
        let factory = IOSPlaybackBackendFactory { kind in
            XCTAssertEqual(kind.rawValue, PlaybackBackendKind.pingPong.rawValue)
            let orchestrator = IOSPlaybackOrchestrator()
            return PingPongPlaybackBackend(
                player: player,
                orchestrator: orchestrator,
                transitionGenerationSidecar: sidecar,
                onCommitted: { committed, _ in
                    XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: committed))
                    XCTAssertTrue(facadeBox.value?.currentBackend.identity === committed)
                    committed.delegate = delegate
                    trace.append("pingPong.committed")
                },
                onActivated: { committed in
                    XCTAssertTrue(committed.delegate === delegate)
                    XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: committed))
                    trace.append("pingPong.activated")
                },
                onDisposed: { _, _ in trace.append("pingPong.disposed") },
                queueProvider: { [] }
            )
        }
        let facade = PlaybackBackendFacade(initial: initial, factory: factory, authority: authority)
        facadeBox.value = facade

        XCTAssertEqual(Array(trace.prefix(2)), ["standard.committed", "standard.activated"])
        let finished = expectation(description: "real adapter swap")
        facade.setPlaybackBackend(.pingPong) { result in
            if case .failure(let error) = result {
                XCTFail("swap failed: \(error)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        let committed = trace.firstIndex(of: "pingPong.committed")
        let activated = trace.firstIndex(of: "pingPong.activated")
        XCTAssertNotNil(committed)
        XCTAssertNotNil(activated)
        XCTAssertLessThan(committed!, activated!)
        XCTAssertEqual(facade.currentBackend.kind.rawValue, PlaybackBackendKind.pingPong.rawValue)
    }

    func test_uncommittedRealPingPongCandidateDoesNotOwnSharedControlSurface() throws {
        let player = QueuedAudioPlayer()
        player.remoteCommands = [.play, .pause]
        player.volume = 0.42
        player.playWhenReady = false
        player.automaticallyUpdateNowPlayingInfo = true
        let sentinel = player.remoteCommands.map { $0.description }
        let sentinelVolume = player.volume
        let sentinelPlayWhenReady = player.playWhenReady
        let sentinelAutoMetadata = player.automaticallyUpdateNowPlayingInfo
        let orchestrator = IOSPlaybackOrchestrator()
        var committedCount = 0
        var activatedCount = 0
        var disposedCount = 0
        let candidate = PingPongPlaybackBackend(
            player: player,
            orchestrator: orchestrator,
            transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
            onCommitted: { _, _ in committedCount += 1 },
            onActivated: { _ in activatedCount += 1 },
            onDisposed: { _, _ in disposedCount += 1 },
            queueProvider: { [] }
        )

        XCTAssertNil(orchestrator.delegate)
        try candidate.prepareSilently(.empty)
        try candidate.restore(.empty)
        try candidate.prepareActivation(.empty)
        try candidate.stopAndMute()
        try candidate.dispose()

        XCTAssertEqual(player.remoteCommands.map { $0.description }, sentinel)
        XCTAssertEqual(player.volume, sentinelVolume, accuracy: 0.001)
        XCTAssertEqual(player.playWhenReady, sentinelPlayWhenReady)
        XCTAssertEqual(player.automaticallyUpdateNowPlayingInfo, sentinelAutoMetadata)
        XCTAssertEqual(committedCount, 0)
        XCTAssertEqual(activatedCount, 0)
        XCTAssertEqual(disposedCount, 1)
    }

    func test_standardReadinessRequiresStateIndexAndPosition() throws {
        let observations = [
            StandardPlaybackReadinessObservation(state: .loading, index: 2, position: 11),
            StandardPlaybackReadinessObservation(state: .ready, index: 2, position: 3),
            StandardPlaybackReadinessObservation(state: .paused, index: 2, position: 11.2)
        ]
        var observationIndex = 0

        try StandardPlaybackReadinessGate.wait(
            expectedIndex: 2,
            expectedPosition: 11,
            timeout: 1,
            observe: { observations[observationIndex] },
            waitForNextPoll: { observationIndex += 1 }
        )

        XCTAssertEqual(observationIndex, 2)
    }

    func test_standardReadinessRejectsFailureAndTimeout() {
        XCTAssertThrowsError(try StandardPlaybackReadinessGate.wait(
            expectedIndex: 0,
            expectedPosition: 8,
            timeout: 1,
            observe: {
                StandardPlaybackReadinessObservation(state: .failed, index: 0, position: 8)
            },
            waitForNextPoll: {}
        ))
        XCTAssertThrowsError(try StandardPlaybackReadinessGate.wait(
            expectedIndex: 0,
            expectedPosition: 8,
            timeout: 0,
            observe: {
                StandardPlaybackReadinessObservation(state: .buffering, index: 0, position: 8)
            },
            waitForNextPoll: {}
        ))
    }

    func test_realOrchestratorSeekCancellationWinsOverLateSuccessExactlyOnce() {
        var completeSeek: ((Result<Void, Error>) -> Void)?
        let orchestrator = IOSPlaybackOrchestrator { _, _, completion in
            completeSeek = completion
        }
        let track = Track(dictionary: [
            "id": "seek-race",
            "url": URL(fileURLWithPath: "/tmp/rntp-seek-race.m4a").absoluteString,
            "duration": 60.0
        ])!
        orchestrator.replaceQueue([track], currentIndex: 0)
        var results: [Result<Void, Error>] = []

        orchestrator.seek(to: 12) { results.append($0) }
        orchestrator.pause()

        XCTAssertEqual(results.count, 1)
        if case .success = results[0] { XCTFail("cancelled seek unexpectedly succeeded") }
        XCTAssertEqual(orchestrator.playbackState.rawValue, State.paused.rawValue)
        XCTAssertEqual(orchestrator.currentIndex, 0)

        completeSeek?(.success(()))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(orchestrator.playbackState.rawValue, State.paused.rawValue)
        XCTAssertEqual(orchestrator.currentIndex, 0)
    }

    func test_realOrchestratorRemovingActiveTrackPublishesIdleAndNilTrack() {
        let orchestrator = IOSPlaybackOrchestrator()
        let delegate = RecordingOrchestratorDelegate()
        orchestrator.delegate = delegate
        let active = makeTrack(id: "active")
        let replacement = makeTrack(id: "replacement")
        orchestrator.replaceQueue([active], currentIndex: 0)
        orchestrator.play()

        orchestrator.setQueue([replacement])

        XCTAssertFalse(orchestrator.playWhenReady)
        XCTAssertEqual(orchestrator.currentIndex, -1)
        XCTAssertEqual(orchestrator.playbackState.rawValue, State.none.rawValue)
        XCTAssertEqual(delegate.activeTrackChanges.count, 1)
        XCTAssertNil(delegate.activeTrackChanges[0])
        XCTAssertEqual(delegate.states.last, State.none.rawValue)
    }

    private func assertAwakenedScheduledCrossfadeCancellation(
        _ mutation: ScheduledCrossfadeCancellationMutation
    ) throws {
        let fixtureURL = try bundledAudioURL()
        let outgoing = makeTrack(
            id: "scheduled-race-\(mutation.label)-outgoing",
            url: fixtureURL,
            duration: 28.2
        )
        let incoming = makeTrack(
            id: "scheduled-race-\(mutation.label)-incoming",
            url: fixtureURL,
            duration: 28.2
        )
        let replacement = makeTrack(
            id: "scheduled-race-\(mutation.label)-replacement",
            url: fixtureURL,
            duration: 28.2
        )
        let timerAwakened = DispatchSemaphore(value: 0)
        let releaseTimer = DispatchSemaphore(value: 0)
        let timerFinished = DispatchSemaphore(value: 0)
        let cancellationClaimed = DispatchSemaphore(value: 0)
        let releaseCancellation = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var timerAttemptedStart = false
        var barrierFailure: String?
        let orchestrator = IOSPlaybackOrchestrator(
            scheduledCrossfadeTimerHook: { check in
                timerAwakened.signal()
                if releaseTimer.wait(timeout: .now() + 10) != .success {
                    observationLock.lock()
                    barrierFailure = "timer was not released"
                    observationLock.unlock()
                }
                let attemptedStart = check()
                observationLock.lock()
                timerAttemptedStart = attemptedStart
                observationLock.unlock()
                timerFinished.signal()
            },
            scheduledCrossfadeCancellationAfterClaimHook: {
                cancellationClaimed.signal()
                if releaseCancellation.wait(timeout: .now() + 10) != .success {
                    observationLock.lock()
                    barrierFailure = "cancellation was not released"
                    observationLock.unlock()
                }
            }
        )
        let delegate = RecordingOrchestratorDelegate()
        orchestrator.delegate = delegate
        orchestrator.replaceQueue([outgoing, incoming], currentIndex: 0)

        let played = expectation(description: "scheduled race source playing \(mutation.label)")
        orchestrator.play { result in
            if case .failure(let error) = result { XCTFail("play failed: \(error)") }
            played.fulfill()
        }
        wait(for: [played], timeout: 10)
        let scheduledStartTime = orchestrator.currentTime * 1_000 + 100

        let controllerFinished = expectation(
            description: "scheduled race barrier finished \(mutation.label)"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            guard timerAwakened.wait(timeout: .now() + 10) == .success else {
                observationLock.lock()
                barrierFailure = "scheduled timer did not awaken"
                observationLock.unlock()
                releaseTimer.signal()
                releaseCancellation.signal()
                controllerFinished.fulfill()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                switch mutation {
                case .pause:
                    orchestrator.pause()
                case .backendSwap:
                    orchestrator.settleActiveTransition()
                case .queueChange:
                    orchestrator.setQueue([outgoing, replacement])
                case .seek:
                    orchestrator.seek(to: 1) { _ in }
                }
                mutationFinished.signal()
            }
            if cancellationClaimed.wait(timeout: .now() + 10) != .success {
                observationLock.lock()
                barrierFailure = "scheduled cancellation did not claim the gate"
                observationLock.unlock()
            }
            let playbackDeadline = Date().addingTimeInterval(2)
            while orchestrator.currentTime * 1_000 < scheduledStartTime,
                  Date() < playbackDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if orchestrator.currentTime * 1_000 < scheduledStartTime {
                observationLock.lock()
                barrierFailure = "playback did not reach the scheduled start time"
                observationLock.unlock()
            }
            releaseTimer.signal()
            if timerFinished.wait(timeout: .now() + 10) != .success {
                observationLock.lock()
                barrierFailure = "awakened timer did not finish its check"
                observationLock.unlock()
            }
            releaseCancellation.signal()
            if mutationFinished.wait(timeout: .now() + 10) != .success {
                observationLock.lock()
                barrierFailure = "cancelling mutation did not finish"
                observationLock.unlock()
            }
            controllerFinished.fulfill()
        }

        let crossfadeFinished = expectation(
            description: "scheduled race crossfade terminal \(mutation.label)"
        )
        let crossfadeResult = ObjectBox<Result<Void, Error>>()
        var completionCount = 0
        var statesAtCompletion: [(state: String, errorCode: String?)] = []
        orchestrator.crossFade(
            fadeDuration: 1_000,
            fadeInterval: 50,
            fadeToVolume: 1,
            waitUntil: scheduledStartTime
        ) { result in
            completionCount += 1
            crossfadeResult.value = result
            statesAtCompletion = delegate.crossfadeEvents
            crossfadeFinished.fulfill()
        }

        wait(for: [controllerFinished, crossfadeFinished], timeout: 20)
        observationLock.lock()
        let recordedBarrierFailure = barrierFailure
        let recordedStartAttempt = timerAttemptedStart
        observationLock.unlock()
        XCTAssertNil(recordedBarrierFailure)
        XCTAssertFalse(recordedStartAttempt)
        XCTAssertEqual(completionCount, 1)
        XCTAssertThrowsError(try XCTUnwrap(crossfadeResult.value).get())
        XCTAssertEqual(statesAtCompletion.map(\.state), ["scheduled", "cancelled"])
        XCTAssertEqual(statesAtCompletion.last?.errorCode, mutation.expectedErrorCode)
        XCTAssertEqual(delegate.crossfadeEvents.filter {
            $0.state == "cancelled" && $0.errorCode == mutation.expectedErrorCode
        }.count, 1)
        XCTAssertFalse(delegate.crossfadeEvents.contains {
            $0.state == "started" || $0.state == "running" || $0.state == "completed"
        })
        XCTAssertNotEqual(orchestrator.state, .crossfading)
        orchestrator.pause()
    }

    private func makeStandardSeekFixture() throws -> StandardSeekFixture {
        let fixtureURL = try bundledAudioURL()
        let track = makeTrack(id: UUID().uuidString, url: fixtureURL, duration: 28.2)
        let loaded = expectation(description: "standard bundled fixture is loaded")
        let observer = NSObject()
        let readinessLock = NSLock()
        var reportedReady = false
        let player = onMain { QueuedAudioPlayer() }
        player.event.stateChange.addListener(observer) { state in
            guard state == .ready || state == .paused else { return }
            readinessLock.lock()
            let shouldReport = !reportedReady
            reportedReady = true
            readinessLock.unlock()
            if shouldReport { loaded.fulfill() }
        }
        onMain {
            player.automaticallyUpdateNowPlayingInfo = false
            player.remoteCommands = []
            player.add(items: [track], playWhenReady: false)
        }
        wait(for: [loaded], timeout: 10)
        player.event.stateChange.removeListener(observer)
        let fixture = onMain { () -> StandardSeekFixture in
            let gate = StandardSeekCallbackGate(forwarding: player)
            player.wrapper.delegate = gate
            let backend = StandardPlaybackBackend(
                player: player,
                transitionGenerationSidecar: PlaybackTransitionGenerationSidecar(),
                automaticallyUpdateNowPlayingInfo: { false },
                onCommitted: { _ in },
                onActivated: { _ in },
                onDisposed: { _ in },
                initiallyAuthoritative: true,
                queueProvider: { player.items.compactMap { $0 as? Track } }
            )
            return StandardSeekFixture(player: player, backend: backend, gate: gate)
        }
        addTeardownBlock {
            self.onMain {
                try? fixture.backend.dispose()
                fixture.player.wrapper.delegate = fixture.player
                fixture.player.clear()
            }
        }
        return fixture
    }

    private func drainStandardSeekEvents(_ player: QueuedAudioPlayer) {
        // The SDK delivers seek events on its private serial queue. This marker
        // drains that queue and all prior main-thread completion work without a sleep.
        let drained = expectation(description: "SwiftAudioEx seek event queue drained")
        let observer = NSObject()
        let marker = -987654.0
        player.event.seek.addListener(observer) { event in
            if event.seconds == marker {
                DispatchQueue.main.async { drained.fulfill() }
            }
        }
        onMain { player.AVWrapper(seekTo: marker, didFinish: false) }
        wait(for: [drained], timeout: 5)
        player.event.seek.removeListener(observer)
    }

    private func makeTrack(id: String) -> Track {
        return Track(dictionary: [
            "id": id,
            "url": URL(fileURLWithPath: "/tmp/\(id).m4a").absoluteString,
            "duration": 60.0
        ])!
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        root.appendPathComponent(relativePath)
        return try String(contentsOf: root, encoding: .utf8)
    }

    private func bundledAudioURL() throws -> URL {
        return try XCTUnwrap(
            Bundle(for: IOSPlaybackBackendIntegrationTests.self)
                .url(forResource: "pure", withExtension: "m4a")
        )
    }

    private func makeTrack(
        id: String,
        url: URL,
        duration: Double,
        isLiveStream: Bool = false
    ) -> Track {
        return Track(dictionary: [
            "id": id,
            "url": url.absoluteString,
            "duration": duration,
            "isLiveStream": isLiveStream
        ])!
    }

    private func awaitBackendSwap(
        _ module: RNTrackPlayer,
        config: [String: Any]
    ) -> [String: Any]? {
        let finished = expectation(description: "swap \(config["type"] ?? "unknown")")
        var lifecycle: [String: Any]?
        onMain {
            module.setPlaybackBackend(
                config: config,
                resolve: {
                    lifecycle = $0 as? [String: Any]
                    finished.fulfill()
                },
                reject: rejecting("setPlaybackBackend", fulfilling: finished)
            )
        }
        wait(for: [finished], timeout: 20)
        return lifecycle
    }

    private func rejecting(
        _ operation: String,
        fulfilling expectation: XCTestExpectation? = nil
    ) -> RCTPromiseRejectBlock {
        return { code, message, error in
            XCTFail(
                "\(operation) rejected: code=\(String(describing: code)) " +
                "message=\(String(describing: message)) error=\(String(describing: error))"
            )
            expectation?.fulfill()
        }
    }

    private func onMain<Value>(_ operation: () -> Value) -> Value {
        if Thread.isMainThread { return operation() }
        return DispatchQueue.main.sync(execute: operation)
    }
}

private struct StandardSeekFixture {
    let player: QueuedAudioPlayer
    let backend: StandardPlaybackBackend
    let gate: StandardSeekCallbackGate
}

private final class StandardSeekResults {
    private let lock = NSLock()
    private var values: [Result<Void, Error>] = []

    func append(_ value: Result<Void, Error>) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard values.count == 1, case .success = values[0] else { return false }
        return true
    }

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard values.count == 1, case .failure = values[0] else { return false }
        return true
    }
}

// Retains the real AVFoundation callback before AudioPlayer publishes it on
// event.seek. The player, file, queue and Standard backend all remain real.
// No production seam or invented item/generation field is used.
private final class StandardSeekCallbackGate: AVPlayerWrapperDelegate {
    private weak var forward: AVPlayerWrapperDelegate?
    private let lock = NSLock()
    private var pending: [(seconds: Double, didFinish: Bool)] = []
    private var captured: [Double] = []
    private var captureHandler: ((Double) -> Void)?

    init(forwarding delegate: AVPlayerWrapperDelegate) { forward = delegate }

    var didCapture: ((Double) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return captureHandler
        }
        set {
            lock.lock()
            captureHandler = newValue
            lock.unlock()
        }
    }

    var capturedSeconds: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func AVWrapper(seekTo seconds: Double, didFinish: Bool) {
        lock.lock()
        pending.append((seconds, didFinish))
        captured.append(seconds)
        let handler = captureHandler
        lock.unlock()
        handler?(seconds)
    }

    func releaseFirst(seconds: Double) {
        lock.lock()
        let index = pending.firstIndex { $0.seconds == seconds }
        let event = index.map { pending.remove(at: $0) }
        lock.unlock()
        guard let event else {
            XCTFail("No retained native seek callback for \(seconds)")
            return
        }
        forward?.AVWrapper(seekTo: event.seconds, didFinish: event.didFinish)
    }

    func AVWrapper(didChangeState state: AVPlayerWrapperState) { forward?.AVWrapper(didChangeState: state) }
    func AVWrapper(secondsElapsed seconds: Double) { forward?.AVWrapper(secondsElapsed: seconds) }
    func AVWrapper(failedWithError error: Error?) { forward?.AVWrapper(failedWithError: error) }
    func AVWrapper(didUpdateDuration duration: Double) { forward?.AVWrapper(didUpdateDuration: duration) }
    func AVWrapper(didReceiveCommonMetadata metadata: [AVMetadataItem]) { forward?.AVWrapper(didReceiveCommonMetadata: metadata) }
    func AVWrapper(didReceiveChapterMetadata metadata: [AVTimedMetadataGroup]) { forward?.AVWrapper(didReceiveChapterMetadata: metadata) }
    func AVWrapper(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) { forward?.AVWrapper(didReceiveTimedMetadata: metadata) }
    func AVWrapper(didChangePlayWhenReady playWhenReady: Bool) { forward?.AVWrapper(didChangePlayWhenReady: playWhenReady) }
    func AVWrapperItemDidPlayToEndTime() { forward?.AVWrapperItemDidPlayToEndTime() }
    func AVWrapperItemFailedToPlayToEndTime() { forward?.AVWrapperItemFailedToPlayToEndTime() }
    func AVWrapperItemPlaybackStalled() { forward?.AVWrapperItemPlaybackStalled() }
    func AVWrapperDidRecreateAVPlayer() { forward?.AVWrapperDidRecreateAVPlayer() }
}

private enum ScheduledCrossfadeCancellationMutation {
    case pause
    case backendSwap
    case queueChange
    case seek

    var label: String {
        switch self {
        case .pause: return "pause"
        case .backendSwap: return "backend-swap"
        case .queueChange: return "queue-change"
        case .seek: return "seek"
        }
    }

    var expectedErrorCode: String {
        switch self {
        case .pause: return "pause"
        case .backendSwap: return "backend_swap"
        case .queueChange: return "queue_changed"
        case .seek: return "seek"
        }
    }
}

private final class ObjectBox<Value> {
    var value: Value?
}

private enum RNTrackPlayerTestEventSink {
    static let shared = RCTCallableJSModules()
}

private final class RecordingEventObserver {
    private(set) var recorded: [(event: EventType, body: Any?)] = []

    func record(event: EventType, body: Any?) {
        recorded.append((event: event, body: body))
    }

    func reset() {
        recorded.removeAll()
    }

    func events(for event: EventType) -> [[String: Any]] {
        return recorded.compactMap { entry in
            guard entry.event == event else { return nil }
            return entry.body as? [String: Any]
        }
    }
}

private extension String {
    func substring(after marker: String) -> String {
        guard let range = range(of: marker) else { return "" }
        return String(self[range.upperBound...])
    }

    func substring(before marker: String) -> String {
        guard let range = range(of: marker) else { return self }
        return String(self[..<range.lowerBound])
    }
}

private struct StandardRebaseObservation {
    let queueReloadCount: Int
    let retainedTrackObject: Bool
    let position: Double
}

private struct PingPongRebaseObservation {
    let queueResetCount: Int
    let retainedTrackObject: Bool
    let position: Double
}

private final class RecordingOrchestratorDelegate: IOSPlaybackOrchestratorDelegate {
    var states: [String] = []
    var activeTrackChanges: [Int?] = []
    var activeTrackLastIndexes: [Int?] = []
    var activeTrackLastTracks: [Track?] = []
    var crossfadeEvents: [(state: String, errorCode: String?)] = []
    var onCrossfadeState: ((String, String?) -> Void)?

    func playbackOrchestrator(_ orchestrator: IOSPlaybackOrchestrator, didChangeState state: State) {
        states.append(state.rawValue)
    }

    func playbackOrchestrator(
        _ orchestrator: IOSPlaybackOrchestrator,
        didChangeActiveTrack index: Int?,
        lastIndex: Int?,
        lastTrack: Track?,
        lastPosition: Double
    ) {
        activeTrackChanges.append(index)
        activeTrackLastIndexes.append(lastIndex)
        activeTrackLastTracks.append(lastTrack)
    }

    func playbackOrchestrator(
        _ orchestrator: IOSPlaybackOrchestrator,
        didEndQueueAt index: Int,
        position: Double
    ) {}

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
        crossfadeEvents.append((state: state, errorCode: errorCode))
        onCrossfadeState?(state, errorCode)
    }

    func playbackOrchestratorDidUpdateNowPlaying(_ orchestrator: IOSPlaybackOrchestrator) {}
}
