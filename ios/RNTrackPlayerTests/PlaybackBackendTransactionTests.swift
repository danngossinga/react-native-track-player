import AVFoundation
import Network
import XCTest
@testable import RNTrackPlayerBackendCore

final class PlaybackBackendTransactionTests: XCTestCase {
    // The crossfade engines' load timeout (`prepareTimeoutMs`): parser, stored value, backend step.

    func testPrepareTimeoutOptionTakesMillisecondsFromOneTo2147483646() {
        XCTAssertEqual(timeoutOption(NSNumber(value: 12_000)), 12_000)
        XCTAssertEqual(timeoutOption(NSNumber(value: 8_000.9)), 8_000)
        XCTAssertEqual(timeoutOption(NSNumber(value: 1)), 1)
        XCTAssertEqual(timeoutOption(NSNumber(value: 2_147_483_646)), 2_147_483_646)
    }

    func testPrepareTimeoutOptionIgnoresEverythingElse() {
        XCTAssertNil(timeoutOption(nil))
        XCTAssertNil(timeoutOption("12000"))
        XCTAssertNil(timeoutOption(NSNumber(value: true)))
        XCTAssertNil(timeoutOption(NSNumber(value: 0)))
        XCTAssertNil(timeoutOption(NSNumber(value: -5_000)))
        XCTAssertNil(timeoutOption(NSNumber(value: 0.5)))
        XCTAssertNil(timeoutOption(NSNumber(value: Double.nan)))
        XCTAssertNil(timeoutOption(NSNumber(value: Double.infinity)))
        XCTAssertNil(timeoutOption(NSNumber(value: 2_147_483_647)))
    }

    func testPrepareTimeoutSettingKeepsTheDefaultUntilTheAppGivesAValidValue() {
        let setting = TimeoutSetting(optionKey: "prepareTimeoutMs", defaultMs: prepareTimeoutDefaultMs)
        XCTAssertEqual(setting.milliseconds, 60_000)
        XCTAssertNil(setting.apply(["capabilities": ["play"]]))
        XCTAssertEqual(setting.milliseconds, 60_000)
        XCTAssertEqual(setting.apply(["prepareTimeoutMs": NSNumber(value: 15_000)]), true)
        XCTAssertEqual(setting.milliseconds, 15_000)
        // An invalid or missing value keeps the current one; a new valid value replaces it.
        XCTAssertEqual(setting.apply(["prepareTimeoutMs": "30000"]), false)
        XCTAssertNil(setting.apply([:]))
        XCTAssertEqual(setting.milliseconds, 15_000)
        XCTAssertEqual(setting.apply(["prepareTimeoutMs": NSNumber(value: 30_000)]), true)
        XCTAssertEqual(setting.milliseconds, 30_000)
    }

    func testEachPlayerTimeoutHasItsDefaultUntilTheAppSetsIt() {
        // Each wait reads its own option; the total limits are safety caps, the stall timeout
        // decides first.
        let cases: [(String, Int, Int)] = [
            ("playStartTimeoutMs", playStartTimeoutDefaultMs, 60_000),
            ("standardReadyTimeoutMs", standardReadyTimeoutDefaultMs, 60_000),
            ("standardSeekTimeoutMs", standardSeekTimeoutDefaultMs, 60_000),
            ("stallTimeoutMs", stallTimeoutDefaultMs, 10_000),
            ("incomingStallGraceMs", incomingStallGraceDefaultMs, 2_000),
        ]
        for (key, defaultMs, expectedDefault) in cases {
            XCTAssertEqual(defaultMs, expectedDefault, key)
            let setting = TimeoutSetting(optionKey: key, defaultMs: defaultMs)
            XCTAssertEqual(setting.milliseconds, expectedDefault, key)
            XCTAssertNil(setting.apply(["prepareTimeoutMs": NSNumber(value: 1_234)]), key)
            XCTAssertEqual(setting.apply([key: NSNumber(value: 40_000)]), true, key)
            XCTAssertEqual(setting.milliseconds, 40_000, key)
        }
    }

    func testBackendStepTimeoutCoversALoadThenAPlayStartAndNeverBelowTen() {
        // The defaults: 60 s load + 60 s play start + 5 s.
        XCTAssertEqual(backendStepTimeout(loadTimeoutMs: prepareTimeoutDefaultMs, playStartTimeoutMs: playStartTimeoutDefaultMs), 125)
        XCTAssertEqual(backendStepTimeout(loadTimeoutMs: 1_000, playStartTimeoutMs: 1_000), 10)
        XCTAssertEqual(backendStepTimeout(loadTimeoutMs: 30_000, playStartTimeoutMs: 8_000), 43)
        XCTAssertEqual(backendStepTimeout(loadTimeoutMs: 2_500, playStartTimeoutMs: 5_000), 12.5)
        // A longer play-start limit makes the step wait longer too.
        XCTAssertEqual(backendStepTimeout(loadTimeoutMs: 5_000, playStartTimeoutMs: 20_000), 30)
    }

    // The track after an ended one fails to start: no command waits for it, so the app is told
    // with a playback error (as Android's orchestrator), unless a newer command cancelled it.

    func testAStalledAdvanceIsReportedWithItsCodeAndMessage() {
        let stall = NSError(domain: "RNTP-Crossfade", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Crossfade engine did not become ready (no progress for 10000 ms).",
            "code": "crossfade_prepare_timeout"
        ])
        XCTAssertEqual(
            PlaybackAdvanceFailure(.failure(stall)),
            PlaybackAdvanceFailure(
                code: "crossfade_prepare_timeout",
                message: "Crossfade engine did not become ready (no progress for 10000 ms)."
            )
        )
    }

    func testAnAdvanceErrorWithoutACodeIsReportedAsAnEngineError() {
        let playerError = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed"
        ])
        XCTAssertEqual(
            PlaybackAdvanceFailure(.failure(playerError)),
            PlaybackAdvanceFailure(code: "crossfade_engine_error", message: "The operation could not be completed")
        )
    }

    func testAnAdvanceThatStartedOrWasCancelledIsNotReported() {
        XCTAssertNil(PlaybackAdvanceFailure(.success(())))
        let cancelled = NSError(domain: "RNTP-Orchestrator", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Playback load was cancelled by skip.",
            "code": "cancelled"
        ])
        XCTAssertNil(PlaybackAdvanceFailure(.failure(cancelled)))
    }

    func testAnAdvanceWhosePlayStartGaveUpIsReportedOnceByThePlayStart() {
        // The next track loaded but did not start: loadIndex's autoplay failure reported it (the
        // player is paused, not in error), so the advance reports nothing more. A load that
        // failed (the player in error) is the advance's to report.
        let playStart = NSError(domain: "RNTP-Crossfade", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Crossfade engine did not start playing.",
            "code": "crossfade_play_start_timeout"
        ])
        XCTAssertNil(PlaybackAdvanceFailure(.failure(playStart), playerInError: false))
        var reports: [PlaybackAdvanceFailure] = []
        advanceAfterTrackEnd(
            skip: { $0(.failure(playStart)) },
            playerInError: { false },
            report: { reports.append($0) }
        )
        XCTAssertTrue(reports.isEmpty, "the play start already reported it")
        let stall = NSError(domain: "RNTP-Crossfade", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Crossfade engine did not become ready (no progress for 10000ms).",
            "code": "crossfade_prepare_timeout"
        ])
        XCTAssertEqual(
            PlaybackAdvanceFailure(.failure(stall), playerInError: true),
            PlaybackAdvanceFailure(code: "crossfade_prepare_timeout", message: "Crossfade engine did not become ready (no progress for 10000ms).")
        )
    }

    func testAnAdvanceAfterATrackEndReportsItsFailureOnce() {
        var reports: [PlaybackAdvanceFailure] = []
        var skips = 0
        let stall = NSError(domain: "RNTP-Crossfade", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Crossfade engine did not become ready (no progress for 10000 ms).",
            "code": "crossfade_prepare_timeout"
        ])
        advanceAfterTrackEnd(
            skip: { completion in skips += 1; completion(.failure(stall)) },
            report: { reports.append($0) }
        )
        XCTAssertEqual(skips, 1)
        XCTAssertEqual(reports, [PlaybackAdvanceFailure(
            code: "crossfade_prepare_timeout",
            message: "Crossfade engine did not become ready (no progress for 10000 ms)."
        )])
    }

    func testAnAdvanceAfterATrackEndReportsNothingWhenItStartsOrIsCancelled() {
        var reports: [PlaybackAdvanceFailure] = []
        let cancelled = NSError(domain: "RNTP-Orchestrator", code: 1, userInfo: ["code": "cancelled"])
        advanceAfterTrackEnd(skip: { $0(.success(())) }, report: { reports.append($0) })
        advanceAfterTrackEnd(skip: { $0(.failure(cancelled)) }, report: { reports.append($0) })
        XCTAssertTrue(reports.isEmpty)
    }

    func testAnAdvanceFailureIsEmittedWithTheFieldsAndroidSends() {
        let body = PlaybackAdvanceFailure(code: "crossfade_prepare_timeout", message: "stalled").eventBody
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body["code"] as? String, "crossfade_prepare_timeout")
        XCTAssertEqual(body["message"] as? String, "stalled")
    }

    func testStoppingALoadRemovesTheItemFromARealPlayer() {
        let player = AVPlayer(playerItem: AVPlayerItem(url: URL(string: "http://127.0.0.1:9/never.m3u8")!))
        XCTAssertNotNil(player.currentItem)
        stopLoading(player)
        XCTAssertNil(player.currentItem, "the player keeps no item, so it requests nothing more")
    }

    func testFailedLoadRuleFollowsTheSharedScenarios() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/failed-load-scenarios.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        XCTAssertEqual(scenarios.count, 18)
        for scenario in scenarios {
            let id = scenario["id"] as? String ?? "?"
            var items: [String: NSObject] = [:]
            func identity(_ name: Any?) -> ObjectIdentifier? {
                guard let name = name as? String else { return nil }
                let item = items[name] ?? NSObject()
                items[name] = item
                return ObjectIdentifier(item)
            }
            func name(_ item: ObjectIdentifier?) -> String {
                return items.first { ObjectIdentifier($0.value) == item }?.key ?? "none"
            }
            func phaseName(_ phase: FailedLoadRule.Phase) -> String {
                switch phase {
                case .selecting: return "selecting"
                case let .loading(item): return "loading \(name(item))"
                case let .loaded(item): return "loaded \(name(item))"
                case let .failed(item): return "failed \(name(item))"
                }
            }
            let rule = FailedLoadRule()
            for (index, step) in try XCTUnwrap(scenario["steps"] as? [[String: Any]]).enumerated() {
                let at = "\(id) step \(index)"
                // The change expected (no key: none), to and from which track (null: none).
                let expected = (step["report"] as? [String: Any]).map {
                    FailedLoadRule.Report(to: identity($0["to"]), from: identity($0["from"]))
                }
                switch step["event"] as? String ?? "" {
                case "load": XCTAssertEqual(rule.moved(identity(step["item"])), step["report"] as? Bool, at)
                case "ready": XCTAssertEqual(rule.ready(), expected, at)
                case "fail": XCTAssertEqual(rule.failed(), expected, at)
                case "command": XCTAssertEqual(rule.command(), expected, at)
                case "skip": rule.skipped()
                case "play": XCTAssertEqual(rule.play(), identity(step["reload"]), at)
                case "reset": rule.reset()
                case "remove": XCTAssertEqual(rule.removed(identity(step["item"])), expected, at)
                case "activate": rule.activating(identity(step["item"]))
                case "publish": rule.published(identity(step["item"]))
                case "adopt": rule.adopted(identity(step["item"]))
                case "replace": rule.replaced(identity(step["item"]), with: identity(step["with"]))
                case "error":
                    // As the backends: the first error while the player has one fails the load.
                    let isNew = rule.playerErrorSeen()
                    XCTAssertEqual(isNew, step["new"] as? Bool, "\(at) new")
                    XCTAssertEqual(isNew ? rule.failed() : nil, expected, at)
                case "recover": XCTAssertEqual(rule.playerErrorGone(), step["cleared"] as? Bool, "\(at) cleared")
                default: XCTFail("unknown event in \(at)")
                }
                XCTAssertEqual(phaseName(rule.phase), step["phase"] as? String, "\(at) phase")
                XCTAssertEqual(rule.playerError == .reported ? "reported" : "none", step["playerError"] as? String, "\(at) playerError")
                XCTAssertEqual(rule.active, identity(step["active"]), "\(at) active")
                XCTAssertEqual(rule.reported, identity(step["reported"]), "\(at) reported")
            }
        }
    }

    // The standard player's load watch (same rules as Android's StandardLoadWatchTest).

    private final class LoadWatchHarness {
        var now: TimeInterval = 0
        var stallMs = 10_000
        lazy var watch = StandardLoadWatch(stallTimeoutMs: { self.stallMs }, totalTimeoutMs: { 60_000 }, now: { self.now })
        let a = NSObject()
        let b = NSObject()

        func observe(_ item: NSObject?, _ phase: StandardLoadPhase, buffered: Double = 0, owned: Bool = false) -> StallVerdict? {
            return watch.check(StandardLoadObservation(item: item.map(ObjectIdentifier.init), phase: phase, readings: [buffered], ownedElsewhere: owned))
        }
    }

    func testReportedTrackProgressIsTheReportedTracksWhileAnotherLoads() {
        // Android: ReportedTrackTest, the same steps.
        let a = NSObject(), b = NSObject(), c = NSObject()
        let ia = ObjectIdentifier(a), ib = ObjectIdentifier(b), ic = ObjectIdentifier(c)
        let progress = ReportedTrackProgress()
        let playing = TrackProgress(position: 60, duration: 180, buffered: 90)
        XCTAssertEqual(progress.read(reported: ia, playerItem: ia, live: playing), playing)
        // The player left it at 61 s for B, which loads: A's last position, duration and buffer.
        progress.left(ia, position: 61)
        progress.left(ib, position: 5)
        XCTAssertEqual(progress.read(reported: ia, playerItem: ib, live: .none), TrackProgress(position: 61, duration: 180, buffered: 90))
        // B loaded and is reported: its live values.
        let playingB = TrackProgress(position: 0.2, duration: 240, buffered: 10)
        XCTAssertEqual(progress.read(reported: ib, playerItem: ib, live: playingB), playingB)
        // New metadata for B keeps what it had; C loads.
        let b2 = NSObject()
        progress.replaced(ib, with: ObjectIdentifier(b2))
        progress.left(ObjectIdentifier(b2), position: 0.3)
        XCTAssertEqual(progress.read(reported: ObjectIdentifier(b2), playerItem: ic, live: .none), TrackProgress(position: 0.3, duration: 240, buffered: 10))
        // No reported track: none; a reported track never played here: none yet.
        XCTAssertEqual(progress.read(reported: nil, playerItem: ic, live: playingB), .none)
        XCTAssertEqual(ReportedTrackProgress().read(reported: ia, playerItem: ib, live: playingB), .none)
    }

    func testReportedNowPlayingShowsTheReportedTrackWhileAnotherLoads() {
        let a = NSObject(), b = NSObject(), c = NSObject()
        let ia = ObjectIdentifier(a), ib = ObjectIdentifier(b), ic = ObjectIdentifier(c)
        let nowPlaying = ReportedNowPlaying()
        XCTAssertNil(nowPlaying.follow(reported: ia, playerItem: ia), "on the reported track: the player's own")
        XCTAssertEqual(nowPlaying.follow(reported: ia, playerItem: ib), .init(item: ia, held: true))
        XCTAssertTrue(nowPlaying.isHeld)
        XCTAssertNil(nowPlaying.follow(reported: ia, playerItem: ib), "nothing new")
        // The player moved again (it shows its own item at every move): A again.
        XCTAssertEqual(nowPlaying.follow(reported: ia, playerItem: ic), .init(item: ia, held: true))
        // C loaded and is reported: released, C shown.
        XCTAssertEqual(nowPlaying.follow(reported: ic, playerItem: ic), .init(item: ic, held: false))
        XCTAssertFalse(nowPlaying.isHeld)
        XCTAssertNil(nowPlaying.follow(reported: nil, playerItem: ib))
        // Held, then the reported track left the queue: released to the player's own item.
        _ = nowPlaying.follow(reported: ic, playerItem: ib)
        XCTAssertEqual(nowPlaying.follow(reported: nil, playerItem: ib), .init(item: nil, held: false))
    }

    func testTheBridgeSendsTheSameRejectionCodesAsAndroid() {
        // Android sends every command failure's own code; iOS the same codes. Standard seeks
        // (before: all `seek_failed` on iOS) and crossfade seeks.
        for code in ["standard_seek_timeout", "standard_seek_cancelled", "standard_seek_unavailable", "crossfade_seek_timeout",
                     "crossfade_prepare_timeout", "crossfade_engine_error", "cancelled", "crossfade_play_start_timeout",
                     "crossfade_start_failed", audioFocusRefusedCode] {
            XCTAssertEqual(bridgeRejectionCode(code, fallback: "seek_failed"), code)
        }
        // iOS alone checks the position is finite: the command's own code.
        XCTAssertEqual(bridgeRejectionCode("standard_seek_invalid_position", fallback: "seek_failed"), "seek_failed")
        XCTAssertEqual(bridgeRejectionCode(nil, fallback: "skip_failed"), "skip_failed")
    }

    func testAPlayAfterAFailedFirstLoadRetriesTheTrackThatFailed() {
        // The crossfade rule on both platforms (Android: startTrackAt of failedLoadIndex), as the
        // standard backends' FailedLoadRule (LOAD-03): the active track when there is one, else
        // the track that failed, retried.
        XCTAssertEqual(indexToPlayAfterFailedLoad(currentIndex: 1, failedIndex: 2, count: 3), 1)
        XCTAssertEqual(indexToPlayAfterFailedLoad(currentIndex: -1, failedIndex: 2, count: 3), 2)
        XCTAssertNil(indexToPlayAfterFailedLoad(currentIndex: -1, failedIndex: nil, count: 3))
        XCTAssertNil(indexToPlayAfterFailedLoad(currentIndex: -1, failedIndex: 5, count: 3))
    }

    func testAStandardSeekThatEndsUnfinishedStopsLoadingUnlessANewerOneReplacedIt() {
        // As settleCrossfadeSeek: the latest seek that fails stops loading; a replaced one does not.
        XCTAssertTrue(standardSeekEndStopsLoading(didFinish: false, sameTrack: true, isLatest: true, seekable: true))
        XCTAssertFalse(standardSeekEndStopsLoading(didFinish: false, sameTrack: true, isLatest: false, seekable: true))
        XCTAssertFalse(standardSeekEndStopsLoading(didFinish: false, sameTrack: false, isLatest: true, seekable: true))
        XCTAssertFalse(standardSeekEndStopsLoading(didFinish: true, sameTrack: true, isLatest: true, seekable: true))
        // On an item AVPlayer cannot seek in, it completes where the player is: no stop.
        XCTAssertFalse(standardSeekEndStopsLoading(didFinish: false, sameTrack: true, isLatest: true, seekable: false))
    }

    func testAStandardSeekOnAnItemAVPlayerCannotSeekInCompletesWhereThePlayerIs() {
        // A stream with no length (a raw ADTS radio stream): no seekable range, and SwiftAudioEx's
        // duration stays 0. Android: ExoPlayer lands such a seek at the start and completes it.
        // Issued once the item is ready (before: it waited for a duration, then timed out).
        XCTAssertFalse(standardSeekCanBeIssued(duration: 0, item: StandardSeekItem(ready: false, seekable: true)))
        XCTAssertTrue(standardSeekCanBeIssued(duration: 0, item: StandardSeekItem(ready: true, seekable: false)))
        XCTAssertTrue(standardSeekCanBeIssued(duration: 30, item: StandardSeekItem(ready: false, seekable: true)))
        // AVPlayer ends it unfinished when the target is past the data it loaded, and stays: it
        // completes there. Finished (within the loaded data): done at the target.
        XCTAssertTrue(standardSeekEndCompletes(didFinish: false, sameTrack: true, seekable: false))
        XCTAssertTrue(standardSeekEndCompletes(didFinish: true, sameTrack: true, seekable: false))
        XCTAssertTrue(standardSeekEndCompletes(didFinish: true, sameTrack: true, seekable: true))
        // Unfinished on an item AVPlayer can seek in, or on another track: interrupted.
        XCTAssertFalse(standardSeekEndCompletes(didFinish: false, sameTrack: true, seekable: true))
        XCTAssertFalse(standardSeekEndCompletes(didFinish: true, sameTrack: false, seekable: false))
        XCTAssertFalse(standardSeekEndCompletes(didFinish: false, sameTrack: false, seekable: false))
        // The item as the seek reads it: none, or another layout, keeps the usual rules.
        XCTAssertEqual(standardSeekItem(.unavailable), StandardSeekItem(ready: false, seekable: true))
        XCTAssertEqual(standardSeekItem(.item(nil)), StandardSeekItem(ready: false, seekable: true))
        let loading = AVPlayerItem(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent.aac"))
        XCTAssertFalse(standardSeekItem(.item(loading)).ready, "not ready before it loaded")
        XCTAssertFalse(standardSeekItem(.item(loading)).seekable, "an item with no seekable range")
    }

    func testAFailedStandardSeekKeepsItsTargetAsThePosition() {
        // SwiftAudioEx's stop resets its position to 0; the backend reports the seek's target,
        // as a failed crossfade seek and Android's standard player (ExoPlayer keeps it).
        let failed = StandardGiveUp(failure: "standard_seek_timeout", keptPosition: 20)
        XCTAssertEqual(failed.position(live: 0), 20)
        let load = StandardGiveUp<String>(failure: "crossfade_prepare_timeout", keptPosition: nil)
        XCTAssertEqual(load.position(live: 3), 3)
    }

    func testStandardLoadARebufferAfterASeekThatWasCancelledIsNotALoad() {
        // Same as Android's StandardLoadWatchTest.aRebufferAfterASeekThatWasCancelledIsNotALoad.
        let h = LoadWatchHarness()
        _ = h.observe(h.a, .ready)
        XCTAssertNil(h.observe(h.a, .loading, owned: true))
        XCTAssertNil(h.observe(h.a, .loading))
        h.now = 30
        XCTAssertNil(h.observe(h.a, .loading))
        // While the seek owns it, nothing is given up, however long it takes (its own limits).
        XCTAssertNil(h.observe(h.b, .loading, owned: true))
        h.now = 60
        XCTAssertNil(h.observe(h.b, .loading, owned: true))
        XCTAssertNil(h.observe(h.b, .loading))
        h.now = 70
        XCTAssertEqual(h.observe(h.b, .loading), .stalled)
    }

    func testStandardLoadTheNextCheckIsAtTheGiveUpOrATenthOfTheStallTimeoutAndNoneWithoutALoad() {
        let h = LoadWatchHarness()
        XCTAssertNil(h.watch.nextCheckInMs())
        _ = h.observe(h.a, .loading)
        XCTAssertEqual(h.watch.nextCheckInMs(), 1_000)
        h.now = 9.5
        _ = h.observe(h.a, .loading)
        XCTAssertEqual(h.watch.nextCheckInMs(), 500)
        h.stallMs = 2_000
        _ = h.observe(h.b, .loading)
        XCTAssertEqual(h.watch.nextCheckInMs(), 200)
        _ = h.observe(h.b, .ready)
        XCTAssertNil(h.watch.nextCheckInMs())
        XCTAssertEqual(standardLoadSampleIntervalMs(5), 1)
    }

    func testStandardLoadDriverSetsOneTimerOnlyWhileALoadIsWatchedAndGivesUpAtIt() {
        let h = LoadWatchHarness()
        var phase = StandardLoadPhase.ready
        var delays: [Int] = []
        var pending: (() -> Void)?
        var verdicts: [StallVerdict] = []
        let driver = StandardLoadDriver(
            watch: h.watch,
            observe: { StandardLoadObservation(item: ObjectIdentifier(h.a), phase: phase, readings: [0]) },
            giveUp: { verdicts.append($0) },
            schedule: { delay, work in delays.append(delay); pending = work; return DispatchWorkItem {} }
        )
        driver.poke()
        XCTAssertFalse(driver.isScheduled, "a ready item: no timer")
        phase = .idle
        driver.poke()
        phase = .loading
        driver.poke()
        XCTAssertTrue(driver.isScheduled)
        XCTAssertEqual(delays, [1_000])
        // Nothing progresses: the timer fires every second, then at the give-up.
        for _ in 0..<10 {
            h.now += Double(delays.last!) / 1000
            pending?()
        }
        XCTAssertEqual(verdicts, [.stalled])
        XCTAssertFalse(driver.isScheduled, "no load watched after a give-up: no timer")
        driver.stop()
    }

    func testStandardLoadBeforeItsItemExistsOnlyTheTotalLimitEndsALoadAndTheStallRuleRunsFromTheItemsCreation() {
        // SwiftAudioEx creates the AVPlayerItem once the asset is playable (an HLS master and
        // media playlist arrived): before it nothing shows progress (nil readings), so only
        // prepareTimeoutMs ends that stage, as crossfade's prepare (StallWaitDriver, capVerdict). A
        // playlist slower than stallTimeoutMs does not fail the track (Android counts playlist
        // bytes as progress). Android: StandardLoadWatchTest, the same steps.
        let h = LoadWatchHarness()
        func see(_ readings: [Double]?) -> StallVerdict? {
            return h.watch.check(StandardLoadObservation(item: ObjectIdentifier(h.a), phase: .loading, readings: readings))
        }
        XCTAssertNil(see(nil))
        h.now = 15
        XCTAssertNil(see(nil), "no item after the stall timeout: the load goes on")
        // The item appears at 20 s: progress (its creation), then the stall rule.
        h.now = 20
        XCTAssertNil(see([1, 0]))
        h.now = 29.999
        XCTAssertNil(see([1, 0]))
        h.now = 30
        XCTAssertEqual(see([1, 0]), .stalled, "no progress for stallTimeoutMs from the item's creation")
        // With no item at all, the total limit.
        h.now = 100
        _ = h.observe(h.b, .ready)
        _ = h.observe(h.b, .idle)
        XCTAssertNil(h.watch.check(StandardLoadObservation(item: ObjectIdentifier(h.b), phase: .loading, readings: nil)))
        h.now = 159.999
        XCTAssertNil(h.watch.check(StandardLoadObservation(item: ObjectIdentifier(h.b), phase: .loading, readings: nil)))
        h.now = 160
        XCTAssertEqual(h.watch.check(StandardLoadObservation(item: ObjectIdentifier(h.b), phase: .loading, readings: nil)), .capExceeded)
    }

    func testStandardLoadBeforeItsItemExistsTheNextCheckIsAtTheTotalLimitOrATenthOfTheStallTimeout() {
        // The stall deadline does not end that stage, so it does not bring the next check forward
        // (a timer at 0 ms, firing in a loop): every tenth of the stall timeout, to see the item
        // appear, then at the total limit.
        let h = LoadWatchHarness()
        var delays: [Int] = []
        var pending: (() -> Void)?
        var verdicts: [StallVerdict] = []
        let driver = StandardLoadDriver(
            watch: h.watch,
            observe: { StandardLoadObservation(item: ObjectIdentifier(h.a), phase: .loading, readings: nil) },
            giveUp: { verdicts.append($0) },
            schedule: { delay, work in delays.append(delay); pending = work; return DispatchWorkItem {} }
        )
        driver.poke()
        while verdicts.isEmpty, delays.count < 100 {
            h.now += Double(delays.last!) / 1000
            pending?()
        }
        XCTAssertEqual(verdicts, [.capExceeded])
        XCTAssertEqual(delays.count, 60, "every second until the total limit")
        XCTAssertFalse(delays.contains(0))
        XCTAssertEqual(h.now, 60, accuracy: 0.0001)
        driver.stop()
    }

    func testStandardLoadReadingsAreNoneWhileThePlayerHasNoItem() {
        let item = AVPlayerItem(url: URL(string: "https://example.invalid/a.m3u8")!)
        XCTAssertNil(standardLoadReadings(.item(nil), bytes: 3, buffered: 0), "no item: no progress signal")
        XCTAssertEqual(standardLoadReadings(.item(item), bytes: 3, buffered: 1), [3, 1])
        // SwiftAudioEx's layout changed (its item cannot be read): the stall rule as before.
        XCTAssertEqual(standardLoadReadings(.unavailable, bytes: 3, buffered: 1), [3, 1])
    }

    func testStandardLoadAnItemLoadingThatNeverWasReadyGivesUpAtTheStallTimeout() {
        let h = LoadWatchHarness()
        XCTAssertNil(h.observe(h.a, .loading))
        h.now = 9.999
        XCTAssertNil(h.observe(h.a, .loading))
        h.now = 10
        XCTAssertEqual(h.observe(h.a, .loading), .stalled)
    }

    func testStandardLoadASlowButProgressingLoadGoesOnUntilTheTotalLimit() {
        let h = LoadWatchHarness()
        var buffered = 0.0
        while h.now < 59 {
            XCTAssertNil(h.observe(h.a, .loading, buffered: buffered), "\(h.now)")
            h.now += 1
            buffered += 0.1
        }
        h.now = 60
        XCTAssertEqual(h.observe(h.a, .loading, buffered: buffered), .capExceeded)
    }

    func testStandardLoadARebufferAfterReadyIsNotALoad() {
        let h = LoadWatchHarness()
        _ = h.observe(h.a, .ready)
        _ = h.observe(h.a, .loading)
        h.now = 30
        XCTAssertNil(h.observe(h.a, .loading))
    }

    func testStandardLoadAnotherItemIsANewLoadWithTheSettingsOfThatMoment() {
        let h = LoadWatchHarness()
        _ = h.observe(h.a, .ready)
        h.stallMs = 2_000
        XCTAssertNil(h.observe(h.b, .loading))
        h.now = 2
        XCTAssertEqual(h.observe(h.b, .loading), .stalled)
        XCTAssertEqual(h.watch.lastStallTimeoutMs, 2_000)
    }

    func testStandardLoadARetryAfterAStopOrAFailureIsANewLoad() {
        let h = LoadWatchHarness()
        _ = h.observe(h.a, .ready)
        _ = h.observe(h.a, .idle)
        XCTAssertNil(h.observe(h.a, .loading))
        h.now = 10
        XCTAssertEqual(h.observe(h.a, .loading), .stalled)
        _ = h.observe(h.a, .failed)
        h.now = 20
        XCTAssertNil(h.observe(h.a, .loading))
        h.now = 30
        XCTAssertEqual(h.observe(h.a, .loading), .stalled)
    }

    // A standard load's progress from its item's access log (StandardLoadBytes), as Android's
    // LoadedBytes counts a load's bytes: read as the backend's observeLoad reads it.

    private final class LoadBytesHarness {
        let watch = LoadWatchHarness()
        let bytes = StandardLoadBytes()
        let url = URL(string: "https://media.example/a.m3u8")
        /// The player's current AVPlayerItem (nil: none yet).
        var playerItem: NSObject?
        /// The bytes per access-log entry of each item.
        var logs: [ObjectIdentifier: [Int64]] = [:]
        /// Each item's whole reading, when a test sets one (else its `logs`' bytes, no events).
        var snapshots: [ObjectIdentifier: ItemLoadSnapshot] = [:]
        var buffered = 0.0

        func observe(_ phase: StandardLoadPhase = .loading, owned: Bool = false) -> StallVerdict? {
            let item = ObjectIdentifier(watch.a)
            if watch.watch.startsLoad(StandardLoadObservation(item: item, phase: phase, readings: [], ownedElsewhere: owned)) {
                bytes.startLoad(url: url)
            }
            bytes.playerItem(playerItem)
            let progress = bytes.read { [unowned self] in
                self.snapshots[ObjectIdentifier($0)] ?? loggedBytes(self.logs[ObjectIdentifier($0)] ?? [])
            }
            // As observeLoad: the item's buffered time once the load has its item.
            return watch.watch.check(StandardLoadObservation(item: item, phase: phase, readings: [progress, bytes.buffered ?? buffered], ownedElsewhere: owned))
        }
    }

    func testStandardLoadBytesArrivingKeepALoadGoingWhileItsBufferedPositionStandsStill() {
        // A progressive file arriving slowly: its access log grows with every chunk while the
        // buffered position stays put (measured on the simulator); Android counts those bytes too.
        let h = LoadBytesHarness()
        let item = NSObject()
        h.playerItem = item
        XCTAssertNil(h.observe())
        var sent: Int64 = 0
        while h.watch.now < 55 {
            h.watch.now += 5
            sent += 100
            h.logs[ObjectIdentifier(item)] = [sent]
            XCTAssertNil(h.observe(), "bytes arrived at \(h.watch.now) s")
        }
        h.watch.now += 4
        XCTAssertNil(h.observe())
        h.watch.now = 60
        XCTAssertEqual(h.observe(), .capExceeded, "the total limit still applies")
        // The bytes stop: the next load stalls at the stall timeout.
        let next = LoadBytesHarness()
        next.playerItem = item
        next.logs[ObjectIdentifier(item)] = [sent]
        XCTAssertNil(next.observe())
        next.watch.now = 10
        XCTAssertEqual(next.observe(), .stalled)
    }

    func testStandardLoadBytesTheItemAppearingIsProgressAndUnknownBytesCountAsNothing() {
        // SwiftAudioEx creates the item once the asset's playable stage is done (an HLS stream's
        // playlists arrived): its appearance is progress, as Android counts playlist bytes.
        let h = LoadBytesHarness()
        XCTAssertNil(h.observe())
        h.watch.now = 9
        let item = NSObject()
        h.playerItem = item
        XCTAssertNil(h.observe())
        h.watch.now = 18
        XCTAssertNil(h.observe(), "the item appeared at 9 s")
        h.watch.now = 19
        XCTAssertEqual(h.observe(), .stalled)
        // A negative count is unknown: nothing, and not a loss of the other entries' bytes.
        let bytes = StandardLoadBytes()
        bytes.startLoad(url: nil)
        bytes.playerItem(item)
        XCTAssertEqual(bytes.read { _ in loggedBytes([50]) }, 51)
        XCTAssertEqual(bytes.read { _ in loggedBytes([-1, 60]) }, 61)
        XCTAssertEqual(bytes.read { _ in loggedBytes([-1]) }, 61, "a log that reads lower is no progress")
    }

    func testStandardLoadBytesALoadWatchedAgainAfterASeekKeepsCountingItsItem() {
        // A seek owned the loading of an item never ready; once it ended, the same AVPlayerItem
        // loads on (a new watch, Android's startLoad of the same item): its bytes still count.
        let h = LoadBytesHarness()
        let item = NSObject()
        h.playerItem = item
        XCTAssertNil(h.observe())
        h.watch.now = 2
        XCTAssertNil(h.observe(owned: true))
        h.watch.now = 3
        XCTAssertNil(h.observe())
        h.watch.now = 8
        h.logs[ObjectIdentifier(item)] = [100]
        XCTAssertNil(h.observe())
        h.watch.now = 13
        XCTAssertNil(h.observe(), "bytes arrived at 8 s")
        h.watch.now = 18
        XCTAssertEqual(h.observe(), .stalled)
    }

    func testStandardLoadBytesALoadCountsOnlyItsOwnItem() {
        // Progress belongs to one load (Android: LoadedBytes.startLoad): a retry of the same track
        // (same URL, a new item) never counts the previous item's late entries.
        let bytes = StandardLoadBytes()
        let url = URL(string: "https://media.example/a.mp3")
        let old = NSObject()
        let new = NSObject()
        var logs: [ObjectIdentifier: [Int64]] = [ObjectIdentifier(old): [100]]
        let entries: (AnyObject) -> ItemLoadSnapshot? = { loggedBytes(logs[ObjectIdentifier($0)] ?? []) }
        bytes.startLoad(url: url)
        bytes.playerItem(old)
        XCTAssertEqual(bytes.read(entries), 101)
        // A retry: SwiftAudioEx gives its AVPlayer a new item (its load clears the old one).
        bytes.startLoad(url: url)
        // The previous item posting a late entry: not this load's.
        XCTAssertFalse(bytes.loggedItem(old, url: url))
        XCTAssertFalse(bytes.isLoadEvent(old, url: url, player: .unavailable))
        logs[ObjectIdentifier(old)] = [500]
        XCTAssertEqual(bytes.read(entries), 101)
        // The load's own item: one for its appearance, then its bytes.
        bytes.playerItem(new)
        logs[ObjectIdentifier(new)] = [40]
        XCTAssertEqual(bytes.read(entries), 142)
        // SwiftAudioEx reloading within the load (a new item): that one counts from its start.
        let reloaded = NSObject()
        bytes.playerItem(reloaded)
        logs[ObjectIdentifier(reloaded)] = [10]
        logs[ObjectIdentifier(new)] = [400]
        XCTAssertEqual(bytes.read(entries), 153)
    }

    func testStandardLoadBytesWithoutThePlayersItemTheLoadTakesTheFirstLoggedItemOfItsURL() {
        // When SwiftAudioEx's AVPlayer cannot be read, an access-log entry's item is the load's when
        // it is for the load's URL (built as SwiftAudioEx builds it); other players' items (a
        // crossfade engine's) and other tracks' are not.
        let url = standardAssetURL(source: "https://media.example/a.m3u8", isFile: false)
        XCTAssertEqual(url, URL(string: "https://media.example/a.m3u8"))
        XCTAssertEqual(standardAssetURL(source: "/var/a.mp3", isFile: true), URL(fileURLWithPath: "/var/a.mp3"))
        let bytes = StandardLoadBytes()
        bytes.startLoad(url: url)
        let other = NSObject()
        let mine = NSObject()
        let late = NSObject()
        XCTAssertFalse(bytes.loggedItem(other, url: URL(string: "https://media.example/b.m3u8")))
        XCTAssertFalse(bytes.loggedItem(other, url: nil))
        XCTAssertTrue(bytes.loggedItem(mine, url: url))
        XCTAssertFalse(bytes.loggedItem(late, url: url), "the load has its item")
        XCTAssertTrue(bytes.isLoadEvent(mine, url: url, player: .unavailable))
        XCTAssertFalse(bytes.isLoadEvent(late, url: url, player: .unavailable))
        XCTAssertEqual(bytes.read { _ in loggedBytes([7]) }, 8)
        // With the player's item read, only its events check the load.
        let current = AVPlayerItem(url: URL(string: "https://media.example/a.m3u8")!)
        XCTAssertTrue(bytes.isLoadEvent(current, url: url, player: .item(current)))
        XCTAssertFalse(bytes.isLoadEvent(mine, url: url, player: .item(current)))
        XCTAssertFalse(bytes.isLoadEvent(mine, url: url, player: .item(nil)))
        XCTAssertEqual(
            standardItemLoadSnapshot(current),
            ItemLoadSnapshot(loadedRanges: [], transferredBytes: 0, accessLogEvents: 0, errorLogEntries: 0),
            "no access log before it loads"
        )
        XCTAssertNil(standardItemLoadSnapshot(mine), "not an AVPlayerItem: nothing to read")
    }

    // A standard load reads its item as crossfade's waits do (ItemLoadProgress): after a failed
    // request or a rendition switch, the bytes posted and the time buffered again are not
    // progress until new time is buffered.

    private func itemReading(_ ranges: [ClosedRange<Double>], bytes: Double, events: Int, errors: Int) -> ItemLoadSnapshot {
        ItemLoadSnapshot(loadedRanges: ranges, transferredBytes: bytes, accessLogEvents: events, errorLogEntries: errors)
    }

    func testStandardLoadBytesAfterASwitchTheLateBytesAreNotProgress() {
        // A load mid-way (a retry at the kept position 30 s; the measured sequence, scaled): media
        // at 1 s, then every rendition's segment fails part way and each switch posts the left
        // rendition's bytes late, with segments downloaded again (the buffer dips and refills
        // with the same time). The load gives up one stall timeout after its last media, not
        // after the last switch's bytes.
        let h = LoadBytesHarness()
        let item = NSObject()
        let key = ObjectIdentifier(item)
        h.playerItem = item
        h.snapshots[key] = itemReading([], bytes: 0, events: 0, errors: 0)
        XCTAssertNil(h.observe())
        h.watch.now = 1
        h.snapshots[key] = itemReading([30...34], bytes: 3_000, events: 1, errors: 0)
        XCTAssertNil(h.observe(), "media")
        h.watch.now = 6
        h.snapshots[key] = itemReading([30...34], bytes: 9_000, events: 2, errors: 1)
        XCTAssertNil(h.observe(), "a switch: its bytes are not progress")
        h.watch.now = 8
        h.snapshots[key] = itemReading([], bytes: 40_000, events: 3, errors: 2)
        XCTAssertNil(h.observe())
        h.watch.now = 10
        h.snapshots[key] = itemReading([30...34], bytes: 52_000, events: 3, errors: 2)
        XCTAssertNil(h.observe(), "the same time buffered again: not progress")
        h.watch.now = 10.9
        h.snapshots[key] = itemReading([30...34], bytes: 60_000, events: 3, errors: 3)
        XCTAssertNil(h.observe())
        h.watch.now = 11
        XCTAssertEqual(h.observe(), .stalled, "one stall timeout after the last media (1 s)")
    }

    func testStandardLoadBytesNewTimeBufferedAfterASwitchResumesTheBytes() {
        // A slow but healthy fallback: after a switch, the new rendition buffers new time, then
        // its bytes are progress again; the load goes on.
        let h = LoadBytesHarness()
        let item = NSObject()
        let key = ObjectIdentifier(item)
        h.playerItem = item
        h.snapshots[key] = itemReading([0...2], bytes: 3_000, events: 1, errors: 0)
        XCTAssertNil(h.observe())
        h.watch.now = 5
        h.snapshots[key] = itemReading([0...2], bytes: 6_000, events: 2, errors: 1)
        XCTAssertNil(h.observe())
        h.watch.now = 9
        h.snapshots[key] = itemReading([0...2.5], bytes: 6_000, events: 2, errors: 1)
        XCTAssertNil(h.observe(), "new time buffered")
        XCTAssertEqual(h.bytes.buffered, 2.5)
        h.watch.now = 18
        h.snapshots[key] = itemReading([0...2.5], bytes: 9_000, events: 2, errors: 1)
        XCTAssertNil(h.observe(), "bytes count again after the new time")
        h.watch.now = 27
        XCTAssertNil(h.observe(), "progress at 18 s")
        h.watch.now = 28
        XCTAssertEqual(h.observe(), .stalled)
    }

    func testStandardLoadBytesASeekTheBackendIssuedIsNotASwitch() {
        // A seek during the load (it owns the loading meanwhile) opens an access-log event: noted
        // by the backend as it issues the seek, it does not pause the load's byte count.
        let h = LoadBytesHarness()
        let item = NSObject()
        let key = ObjectIdentifier(item)
        h.playerItem = item
        h.snapshots[key] = itemReading([0...1], bytes: 1_000, events: 1, errors: 0)
        XCTAssertNil(h.observe())
        h.watch.now = 1
        h.bytes.noteSeek()
        h.snapshots[key] = itemReading([0...1], bytes: 1_000, events: 2, errors: 0)
        XCTAssertNil(h.observe(owned: true))
        h.watch.now = 2
        h.snapshots[key] = itemReading([0...1], bytes: 4_000, events: 2, errors: 0)
        XCTAssertNil(h.observe())
        XCTAssertEqual(h.bytes.progress, 1 + 4_000, "the item's appearance, then every byte")
        // Without the note, the same event is a switch: the bytes after it wait for new time.
        let unnoted = LoadBytesHarness()
        unnoted.playerItem = item
        unnoted.snapshots[key] = itemReading([0...1], bytes: 1_000, events: 1, errors: 0)
        XCTAssertNil(unnoted.observe())
        unnoted.snapshots[key] = itemReading([0...1], bytes: 1_000, events: 2, errors: 0)
        XCTAssertNil(unnoted.observe(owned: true))
        unnoted.snapshots[key] = itemReading([0...1], bytes: 4_000, events: 2, errors: 0)
        XCTAssertNil(unnoted.observe())
        XCTAssertEqual(unnoted.bytes.progress, 1 + 1_000)
    }

    func testStandardLoadBytesEachItemOfALoadIsReadFromItsOwnStart() {
        // A switch paused the byte count of one item; the next load's item (or a reload within
        // the load) starts its own reading: its first reading is a baseline, its bytes count.
        let bytes = StandardLoadBytes()
        let first = NSObject(), retry = NSObject()
        var readings: [ObjectIdentifier: ItemLoadSnapshot] = [
            ObjectIdentifier(first): itemReading([0...1], bytes: 1_000, events: 1, errors: 0),
        ]
        let read: (AnyObject) -> ItemLoadSnapshot? = { readings[ObjectIdentifier($0)] }
        bytes.startLoad(url: nil)
        bytes.playerItem(first)
        XCTAssertEqual(bytes.read(read), 1 + 1_000)
        readings[ObjectIdentifier(first)] = itemReading([0...1], bytes: 5_000, events: 2, errors: 1)
        XCTAssertEqual(bytes.read(read), 1 + 1_000, "paused by the switch")
        XCTAssertEqual(bytes.buffered, 1)
        // A retry: a new load with a new item, whose log already holds events and errors.
        bytes.startLoad(url: nil)
        XCTAssertNil(bytes.buffered, "no item yet")
        bytes.playerItem(retry)
        readings[ObjectIdentifier(retry)] = itemReading([0...0.5], bytes: 2_000, events: 2, errors: 1)
        XCTAssertEqual(bytes.read(read), 1 + 1_000 + 1 + 2_000, "its first reading is a baseline")
        readings[ObjectIdentifier(retry)] = itemReading([0...0.5], bytes: 3_000, events: 2, errors: 1)
        XCTAssertEqual(bytes.read(read), 1 + 1_000 + 1 + 3_000, "counting")
        XCTAssertEqual(bytes.buffered, 0.5)
    }

    func testStandardPlayerItemIsReadThroughSwiftAudioExsPrivateWrapper() {
        // SwiftAudioEx 1.1.0's layout: QueuedAudioPlayer ← AudioPlayer.wrapper (an
        // AVPlayerWrapperProtocol) → AVPlayerWrapper.avPlayer. Checked on the real SwiftAudioEx
        // 1.1.0 in the simulator as well (the item from its creation, before any notification).
        let player = FakeQueuedAudioPlayer()
        guard case .item(nil) = standardPlayerItem(of: player) else {
            return XCTFail("no item yet")
        }
        let item = AVPlayerItem(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent.mp3"))
        player.avPlayer.replaceCurrentItem(with: item)
        defer { player.avPlayer.replaceCurrentItem(with: nil) }
        guard case let .item(read) = standardPlayerItem(of: player) else {
            return XCTFail("the wrapper's player is read")
        }
        XCTAssertTrue(read === item)
        guard case .unavailable = standardPlayerItem(of: NSObject()) else {
            return XCTFail("another layout: unavailable")
        }
    }

    func testStandardLoadASeekDuringALoadKeepsTheLoadsTotalLimitAndStartsItsProgressOnce() {
        // As Android: the load began at 0; a seek owned it from 5 s to 56 s. Watched again, its
        // total limit still counts from 0 (60 s), with a fresh stall clock from the seek's end.
        let h = LoadWatchHarness()
        func see(_ item: NSObject, owned: Bool = false) -> (starts: Bool, verdict: StallVerdict?) {
            let observed = StandardLoadObservation(item: ObjectIdentifier(item), phase: .loading, readings: [0], ownedElsewhere: owned)
            return (h.watch.startsLoad(observed), h.watch.check(observed))
        }
        XCTAssertTrue(see(h.b).starts)
        h.now = 5
        XCTAssertNil(see(h.b, owned: true).verdict)
        h.now = 56
        let after = see(h.b)
        XCTAssertFalse(after.starts, "the progress starts once per load")
        XCTAssertNil(after.verdict)
        h.now = 59.999
        XCTAssertNil(see(h.b).verdict)
        h.now = 60
        XCTAssertEqual(see(h.b).verdict, .capExceeded)
        // A load first seen while a seek owns it began then (its total counts from 70 s).
        h.now = 70
        XCTAssertNil(see(h.a, owned: true).verdict)
        h.now = 125
        let watched = see(h.a)
        XCTAssertTrue(watched.starts, "its progress starts once watched")
        XCTAssertNil(watched.verdict)
        h.now = 130
        XCTAssertEqual(see(h.a).verdict, .capExceeded)
    }

    func testStandardLoadWatchStartsALoadWhereItsCheckBeginsWatching() {
        let h = LoadWatchHarness()
        func observed(_ item: NSObject?, _ phase: StandardLoadPhase, owned: Bool = false) -> StandardLoadObservation {
            return StandardLoadObservation(item: item.map(ObjectIdentifier.init), phase: phase, readings: [0], ownedElsewhere: owned)
        }
        XCTAssertTrue(h.watch.startsLoad(observed(h.a, .loading)))
        _ = h.watch.check(observed(h.a, .loading))
        XCTAssertFalse(h.watch.startsLoad(observed(h.a, .loading)), "watched already")
        XCTAssertTrue(h.watch.startsLoad(observed(h.b, .loading)), "another item")
        XCTAssertFalse(h.watch.startsLoad(observed(h.b, .loading, owned: true)), "a seek owns it")
        XCTAssertFalse(h.watch.startsLoad(observed(nil, .loading)))
        XCTAssertFalse(h.watch.startsLoad(observed(h.b, .ready)))
        _ = h.watch.check(observed(h.a, .ready))
        XCTAssertFalse(h.watch.startsLoad(observed(h.a, .loading)), "a rebuffer after ready is not a load")
        _ = h.watch.check(observed(h.a, .idle))
        XCTAssertTrue(h.watch.startsLoad(observed(h.a, .loading)), "a retry after a stop")
    }

    func testStandardLoadWatchStateMovesBetweenIdleAndOneLoad() {
        // One explicit state (Android: StandardLoadWatchTest.theStateMovesBetweenIdleAndOneLoad,
        // the same steps).
        let h = LoadWatchHarness()
        let ia = ObjectIdentifier(h.a), ib = ObjectIdentifier(h.b)
        func load(_ state: StandardLoadWatch.State) -> StandardLoadWatch.Load? {
            if case let .loading(_, load) = state { return load }
            return nil
        }
        XCTAssertEqual(h.watch.state, .idle(ready: nil))
        h.now = 1
        _ = h.observe(h.a, .loading)
        XCTAssertEqual(load(h.watch.state)?.item, ia)
        XCTAssertEqual(load(h.watch.state)?.startedAt, 1)
        XCTAssertEqual(load(h.watch.state)?.progressStarted, true)
        XCTAssertNotNil(load(h.watch.state)?.watch)
        // A seek owns it: the same load, disarmed.
        h.now = 2
        _ = h.observe(h.a, .loading, owned: true)
        XCTAssertEqual(load(h.watch.state)?.startedAt, 1)
        XCTAssertEqual(load(h.watch.state)?.progressStarted, true)
        XCTAssertNil(load(h.watch.state)?.watch)
        XCTAssertFalse(h.watch.isWatching)
        _ = h.observe(h.a, .ready)
        XCTAssertEqual(h.watch.state, .idle(ready: ia))
        // B loads while A stays the item ready since its load.
        h.now = 3
        _ = h.observe(h.b, .loading)
        guard case let .loading(ready, loadB) = h.watch.state else { return XCTFail("B loads") }
        XCTAssertEqual(ready, ia)
        XCTAssertEqual(loadB.item, ib)
        XCTAssertEqual(loadB.startedAt, 3)
        // Back on A buffering: a rebuffer, not a load (B's load is over).
        XCTAssertNil(h.observe(h.a, .loading))
        XCTAssertEqual(h.watch.state, .idle(ready: ia))
        // A seek owning A's buffering starts no load either.
        _ = h.observe(h.a, .loading, owned: true)
        XCTAssertEqual(h.watch.state, .idle(ready: ia))
        // A give-up ends the load and keeps the ready item.
        h.now = 4
        _ = h.observe(h.b, .loading)
        h.now = 14
        XCTAssertEqual(h.observe(h.b, .loading), .stalled)
        XCTAssertEqual(h.watch.state, .idle(ready: ia))
        XCTAssertEqual(h.watch.lastStallTimeoutMs, 10_000, "the limits of the last load stay")
        // A failure, no item, the idle phase and reset forget the ready item.
        _ = h.observe(h.a, .failed)
        XCTAssertEqual(h.watch.state, .idle(ready: nil))
        _ = h.observe(h.a, .ready)
        _ = h.observe(nil, .loading)
        XCTAssertEqual(h.watch.state, .idle(ready: nil))
        _ = h.observe(h.a, .ready)
        _ = h.observe(h.a, .idle)
        XCTAssertEqual(h.watch.state, .idle(ready: nil))
        _ = h.observe(h.b, .loading)
        h.watch.reset()
        XCTAssertEqual(h.watch.state, .idle(ready: nil))
    }

    // A standard player error reaches JS as its error state, then the playback error (Android's
    // onPlayerError, failLoad and the crossfade path). SwiftAudioEx reports the failure at once
    // but its failed state later, from other queues.

    func testStandardFailureOrderEmitsAFailureAfterTheFailedStateItWaitsFor() {
        let order = StandardFailureOrder<String>()
        var emitted: [String] = []
        func state(_ name: String) {
            order.stateDelivered(failed: name == "failed", emit: { emitted.append("state:\(name)") }, emitFailure: { emitted.append("error:\($0)") })
        }
        func failure(_ name: String, playerFailed: Bool) {
            order.failureDelivered(name, playerFailed: { playerFailed }, emitFailure: { emitted.append("error:\($0)") })
        }
        XCTAssertEqual(order.state, .notFailed)
        state("loading")
        // The failure first (its state still on SwiftAudioEx's queues): it waits for it, behind
        // an older state still delivered first.
        failure("e1", playerFailed: true)
        XCTAssertEqual(order.state, .waiting(["e1"]))
        state("loading")
        XCTAssertEqual(order.state, .waiting(["e1"]), "an older state does not release it")
        state("failed")
        XCTAssertEqual(emitted, ["state:loading", "state:loading", "state:failed", "error:e1"])
        XCTAssertEqual(order.state, .failed)
        // In the failed state (SwiftAudioEx emits no state for the same state again): at once.
        failure("e2", playerFailed: true)
        XCTAssertEqual(emitted.last, "error:e2")
        // The state first: the failure follows it at once.
        state("loading")
        XCTAssertEqual(order.state, .notFailed)
        state("failed")
        failure("e3", playerFailed: true)
        XCTAssertEqual(Array(emitted.suffix(3)), ["state:loading", "state:failed", "error:e3"])
        // Two failures before the state: both after it, in order.
        state("loading")
        failure("e4", playerFailed: true)
        failure("e5", playerFailed: true)
        XCTAssertEqual(order.state, .waiting(["e4", "e5"]))
        state("failed")
        XCTAssertEqual(Array(emitted.suffix(3)), ["state:failed", "error:e4", "error:e5"])
    }

    func testStandardFailureOrderEmitsAtOnceWhenNoFailedStateIsComing() {
        // SwiftAudioEx's failed-to-play-to-end failure leaves its state as it is: no failed state
        // follows, the failure is emitted at once.
        let order = StandardFailureOrder<String>()
        var emitted: [String] = []
        order.stateDelivered(failed: false, emit: { emitted.append("state:playing") }, emitFailure: { emitted.append("error:\($0)") })
        order.failureDelivered("e", playerFailed: { false }, emitFailure: { emitted.append("error:\($0)") })
        XCTAssertEqual(emitted, ["state:playing", "error:e"])
        XCTAssertEqual(order.state, .notFailed)
        // A failed state the backend holds back (a give-up emitted its own error state) still
        // releases the failure waiting for it.
        order.failureDelivered("held", playerFailed: { true }, emitFailure: { emitted.append("error:\($0)") })
        order.stateDelivered(failed: true, emit: {}, emitFailure: { emitted.append("error:\($0)") })
        XCTAssertEqual(emitted.last, "error:held")
    }

    func testStandardFailureOrderKeepsTheOrderAcrossQueues() {
        // As SwiftAudioEx delivers them: the state and the failure on two queues, racing. The
        // failure reads the player failed (the state is set before it is reported).
        for _ in 0..<500 {
            let order = StandardFailureOrder<String>()
            let emitted = LockedValue<[String]>([])
            let stateQueue = DispatchQueue(label: "state"), failQueue = DispatchQueue(label: "fail")
            let done = DispatchGroup()
            done.enter()
            stateQueue.async {
                order.stateDelivered(failed: false, emit: { emitted.value.append("state:loading") }, emitFailure: { emitted.value.append("error:\($0)") })
                order.stateDelivered(failed: true, emit: { emitted.value.append("state:failed") }, emitFailure: { emitted.value.append("error:\($0)") })
                done.leave()
            }
            done.enter()
            failQueue.async {
                order.failureDelivered("e", playerFailed: { true }, emitFailure: { emitted.value.append("error:\($0)") })
                done.leave()
            }
            done.wait()
            XCTAssertEqual(emitted.value, ["state:loading", "state:failed", "error:e"])
        }
    }

    func testStandardLoadWatchALoadsStageMovesBetweenFreshWatchedAndDisarmed() {
        // One explicit stage per load (Android: StandardLoadWatchTest.aLoadsStageMovesBetweenFreshWatchedAndDisarmed,
        // the same steps; Android's onLoadStart is startsLoad here).
        let h = LoadWatchHarness()
        var starts = 0
        func see(_ owned: Bool) {
            let observed = StandardLoadObservation(item: ObjectIdentifier(h.a), phase: .loading, readings: [0], ownedElsewhere: owned)
            if h.watch.startsLoad(observed) { starts += 1 }
            _ = h.watch.check(observed)
        }
        func load() -> StandardLoadWatch.Load? {
            if case let .loading(_, load) = h.watch.state { return load }
            return nil
        }
        func stall() -> StallWatch? {
            if case let .watched(watch)? = load()?.stage { return watch.stall }
            return nil
        }
        // A seek owns A's loading from its start: a fresh load, not watched, its progress not started.
        h.now = 1
        see(true)
        XCTAssertEqual(load()?.stage, .fresh)
        XCTAssertEqual(load()?.startedAt, 1)
        h.now = 2
        see(true)
        XCTAssertEqual(load()?.stage, .fresh, "fresh while a seek owns it")
        XCTAssertEqual(starts, 0)
        // Watched: its progress starts once, the total limit runs from the load's start.
        h.now = 3
        see(false)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stall()?.capDeadline(), 61)
        XCTAssertEqual(stall()?.deadline(), 13)
        // A seek owns it: disarmed, and stays so.
        h.now = 4
        see(true)
        XCTAssertEqual(load()?.stage, .disarmed)
        h.now = 5
        see(true)
        XCTAssertEqual(load()?.stage, .disarmed)
        XCTAssertFalse(h.watch.isWatching)
        XCTAssertNil(h.watch.nextCheckInMs())
        // Watched again: its progress goes on (no new start), a fresh stall clock, the same total.
        h.now = 6
        see(false)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stall()?.deadline(), 16)
        XCTAssertEqual(stall()?.capDeadline(), 61)
        XCTAssertEqual(load()?.startedAt, 1)
    }

    func testReportedNowPlayingStateIsReleasedOrHeldOnTheReportedTrack() {
        // Android: ReportedTrackTest.theNowPlayingStateIsReleasedOrHeldOnTheReportedTrack.
        let a = NSObject(), b = NSObject()
        let ia = ObjectIdentifier(a), ib = ObjectIdentifier(b)
        let nowPlaying = ReportedNowPlaying()
        XCTAssertEqual(nowPlaying.state, .released)
        XCTAssertEqual(nowPlaying.follow(reported: ia, playerItem: nil), .init(item: ia, held: true), "the player has no item")
        XCTAssertEqual(nowPlaying.state, .held(item: ia, on: nil))
        XCTAssertEqual(nowPlaying.follow(reported: ia, playerItem: ib), .init(item: ia, held: true))
        XCTAssertEqual(nowPlaying.state, .held(item: ia, on: ib))
        XCTAssertEqual(nowPlaying.follow(reported: ib, playerItem: ia), .init(item: ib, held: true), "another reported track")
        XCTAssertEqual(nowPlaying.state, .held(item: ib, on: ia))
        XCTAssertEqual(nowPlaying.follow(reported: ib, playerItem: ib), .init(item: ib, held: false))
        XCTAssertEqual(nowPlaying.state, .released)
        XCTAssertNil(nowPlaying.follow(reported: nil, playerItem: nil))
        XCTAssertEqual(nowPlaying.state, .released)
    }

    // A standard command's wait for its track's load (the crossfade rule), with FailedLoadRule as
    // StandardPlaybackBackend feeds them; the same cases as Android's StandardCommandLoadTest.

    func testStandardCommandLoadSmartMusicPlayersSequenceEndsOnceTheTargetLoadedAndIsReported() {
        let h = CommandLoadHarness()
        // setQueue: the first track is selected (reported at once), then skip(2).
        h.rule.reset()
        _ = h.rule.moved(h.first)
        h.command(h.third)
        _ = h.rule.moved(h.third)
        XCTAssertEqual(h.outcomes, [], "the skip waits while its track loads")
        XCTAssertEqual(h.rule.reported, h.first, "the previous track is still the one the app has")
        h.ready()
        XCTAssertEqual(h.outcomes, [.loaded])
        XCTAssertEqual(h.rule.reported, h.third, "the target is the active track when the skip ends")
        // Previous: skip back to the second track.
        h.outcomes.removeAll()
        h.command(h.second)
        _ = h.rule.moved(h.second)
        XCTAssertEqual(h.outcomes, [])
        h.ready()
        XCTAssertEqual(h.outcomes, [.loaded])
        XCTAssertEqual(h.rule.reported, h.second)
    }

    func testStandardCommandLoadASkipToTheSelectedFirstTrackEndsAtItsLoadNotAtItsSelection() {
        let h = CommandLoadHarness()
        h.rule.reset()
        _ = h.rule.moved(h.first)
        XCTAssertEqual(h.rule.reported, h.first, "selected and reported at once")
        h.command(h.first)
        XCTAssertEqual(h.outcomes, [], "reported but not loaded: the skip waits")
        h.ready()
        XCTAssertEqual(h.outcomes, [.loaded])
    }

    func testStandardCommandLoadASkipToTheTrackAlreadyLoadedAndReportedEndsAtOnce() {
        let h = CommandLoadHarness()
        h.rule.reset()
        _ = h.rule.moved(h.first)
        _ = h.rule.ready()
        XCTAssertNil(h.loads.begin(target: h.first, active: h.rule.active, reported: h.rule.reported) { h.outcomes.append($0) })
        XCTAssertEqual(h.outcomes, [.loaded])
        XCTAssertFalse(h.loads.isWaiting)
    }

    func testStandardCommandLoadAnotherTrackReadyDoesNotEndTheWait() {
        let h = CommandLoadHarness()
        h.rule.reset()
        _ = h.rule.moved(h.first)
        _ = h.rule.ready()
        h.command(h.second)
        // The player still showed the first track ready (its move not yet seen).
        h.ready()
        XCTAssertEqual(h.outcomes, [])
        XCTAssertTrue(h.loads.isWaiting)
    }

    func testStandardCommandLoadAFailedLoadRejectsWithItsCodeAndTheCommandReportsIt() {
        let h = CommandLoadHarness()
        h.rule.reset()
        _ = h.rule.moved(h.first)
        _ = h.rule.ready()
        h.command(h.second)
        _ = h.rule.moved(h.second)
        XCTAssertTrue(h.loads.waits(for: h.second))
        XCTAssertTrue(h.loads.reportsFailure(of: h.second))
        XCTAssertFalse(h.loads.failed(h.first, code: standardLoadErrorCode, message: "x", reportedByPlayer: true), "another track's failure is not this command's")
        _ = h.rule.failed()
        XCTAssertTrue(h.loads.failed(h.second, code: standardLoadErrorCode, message: "Source error", reportedByPlayer: true))
        XCTAssertEqual(h.outcomes, [.failed(code: standardLoadErrorCode, message: "Source error")])
        XCTAssertEqual(h.rule.reported, h.first, "the previous track stays active")
        // Its player error is the rejection's, not a playback error, until the player leaves it.
        XCTAssertTrue(h.loads.reportsFailure(of: h.second))
        XCTAssertFalse(h.loads.reportsFailure(of: h.first))
        h.loads.failureCleared()
        XCTAssertFalse(h.loads.reportsFailure(of: h.second))
    }

    func testStandardCommandLoadAGiveUpTheCommandRejectedWithLeavesTheTracksLaterFailuresReported() {
        let h = CommandLoadHarness()
        h.rule.reset()
        _ = h.rule.moved(h.first)
        h.command(h.first)
        XCTAssertTrue(h.loads.failed(h.first, code: standardPrepareTimeoutCode, message: "The track did not become ready.", reportedByPlayer: false))
        XCTAssertEqual(h.outcomes, [.failed(code: standardPrepareTimeoutCode, message: "The track did not become ready.")])
        // A play retries it and it gives up again, with no command waiting: a playback error.
        XCTAssertFalse(h.loads.reportsFailure(of: h.first))
    }

    func testStandardCommandLoadAWaitStartsItsTracksLoadOnlyWhenThePlayerStandsStill() {
        for state in ["stopped", "failed", "idle"] {
            XCTAssertTrue(standardCommandLoadMustStart(targetLoaded: false, stateRawValue: state), state)
        }
        for state in ["loading", "buffering", "ready", "playing", "paused"] {
            XCTAssertFalse(standardCommandLoadMustStart(targetLoaded: false, stateRawValue: state), state)
        }
        XCTAssertFalse(standardCommandLoadMustStart(targetLoaded: true, stateRawValue: "stopped"))
    }

    func testStandardCommandLoadANewerCommandCancelsTheOlderWait() {
        let h = CommandLoadHarness()
        h.rule.reset()
        _ = h.rule.moved(h.first)
        _ = h.rule.ready()
        var older: [StandardCommandLoadOutcome] = []
        h.rule.skipped()
        h.loads.begin(target: h.second, active: h.rule.active, reported: h.rule.reported) { older.append($0) }
        h.command(h.third)
        XCTAssertEqual(older, [.cancelled])
        _ = h.rule.moved(h.third)
        h.loads.cancel()
        XCTAssertEqual(h.outcomes, [.cancelled])
        XCTAssertEqual(older.count, 1, "settled once")
    }

    func testStandardCommandLoadASeekPauseOrStopThatCancelsAWaitGoesBackToTheReportedTrack() {
        // A plays; a skip to B waits for its load (the player is on B); a seek, pause or stop
        // cancels it: the skip does not take effect, the player goes back to A (crossfade's
        // operation cancelled while it loads). Android: the same steps.
        let h = CommandLoadHarness()
        h.rule.reset()
        _ = h.rule.moved(h.first)
        _ = h.rule.ready()
        h.command(h.second)
        _ = h.rule.moved(h.second)
        XCTAssertTrue(h.loads.cancel(), "one was waiting")
        XCTAssertEqual(h.outcomes, [.cancelled])
        XCTAssertEqual(standardCancelledLoad(cancelledWait: true, playerItem: h.second, reported: h.rule.reported), .returnsTo(h.first))
        _ = h.rule.moved(h.first)
        XCTAssertEqual(h.rule.phase, .loaded(h.first))
        XCTAssertNil(h.rule.play(), "nothing reported, nothing to reload")
        // No wait cancelled: a pause stays; a seek or stop on a track other than the reported one
        // (a failed skip, a natural advance loading) goes back to it (changed deliberately: owner
        // decision, 2026-11-17, LOAD-06), and with none reported acts on the player's own track
        // (the failed first track, retried).
        XCTAssertFalse(h.loads.cancel(), "none waits any more")
        XCTAssertEqual(standardCancelledLoad(cancelledWait: false, playerItem: h.second, reported: h.first), .stays)
        XCTAssertEqual(standardCancelledLoad(cancelledWait: false, playerItem: h.second, reported: nil), .stays)
        XCTAssertEqual(standardCancelledLoad(cancelledWait: false, playerItem: h.second, reported: h.first, actsOnReportedTrack: true), .returnsTo(h.first))
        XCTAssertEqual(standardCancelledLoad(cancelledWait: false, playerItem: h.second, reported: nil, actsOnReportedTrack: true), .stays)
        XCTAssertEqual(standardCancelledLoad(cancelledWait: false, playerItem: h.first, reported: h.first, actsOnReportedTrack: true), .stays)
        // Already on the reported track: it stays.
        XCTAssertEqual(standardCancelledLoad(cancelledWait: true, playerItem: h.first, reported: h.first), .stays)
        // None reported (the first load failed): the cancelled load stops, no active track (as
        // crossfade's active index -1), so the cancelled track is never reported.
        XCTAssertEqual(standardCancelledLoad(cancelledWait: true, playerItem: h.second, reported: nil), .stopsInIdle)
    }

    func testStandardCommandLoadCodesAreTheCrossfadePaths() {
        XCTAssertEqual(standardPrepareTimeoutCode, "crossfade_prepare_timeout")
        XCTAssertEqual(standardLoadErrorCode, "crossfade_engine_error")
    }

    // A standard give-up as StandardPlaybackBackend applies it and RNTrackPlayer emits it
    // (StandardGiveUps, StandardGiveUpReport.events): the same events as Android.

    // StandardLoadCoordinator: the standard backend's load sequences, run against a fake player
    // (StandardPlaybackBackend is that player over SwiftAudioEx, one-line adapters).

    private final class FakeLoadPlayer: StandardLoadPlayer {
        var currentLoadItem: ObjectIdentifier?
        var loadStateRawValue = "loading"
        var loadErrorMessage: String?
        var calls: [String] = []
        var names: [ObjectIdentifier: String] = [:]
        weak var coordinator: StandardLoadCoordinator?
        /// Whether SwiftAudioEx's `stopped` would be emitted at the give-up's stop (its state
        /// event comes after the stop, asynchronously, so later still).
        var stoppedEmittedAtStop: Bool?

        func name(_ item: ObjectIdentifier?) -> String { return item.flatMap { names[$0] } ?? "none" }
        func reloadForCommand() { calls.append("reload") }
        func checkLoad() { calls.append("check") }
        func stopLoading(log: String) {
            calls.append("stop")
            // As the backend: the give-up's stop ends the module's request.
            requested = false
            stoppedEmittedAtStop = coordinator?.emitsPlayerState("stopped")
        }
        func emitGiveUp(_ report: StandardGiveUpReport) {
            calls.append("gaveUp \(report.failure?.code ?? "none") playbackError=\(report.reportsPlaybackError)")
        }
        func reportActiveTrack(_ change: FailedLoadRule.Report) { calls.append("active \(name(change.to)) from \(name(change.from))") }
        func showAfterFailedLoad(_ reported: ObjectIdentifier?) { calls.append("show \(name(reported))") }
        func followNowPlaying() { calls.append("nowPlaying") }
        func logFailedLoad(active: ObjectIdentifier?) {}
        var reportedPosition: Double = 0
        var isIdle = false
        var isPlayerStopped = false
        /// The module's last playback request (nil: none yet).
        var requested: Bool?
        /// Items that left the queue (a jump to them fails).
        var removed: Set<ObjectIdentifier> = []
        func requestPlayback(_ playing: Bool) {
            calls.append("request \(playing ? "play" : "pause")")
            requested = playing
        }
        var playbackRequested: Bool { return requested ?? false }
        func resumePlayback() {
            calls.append("resume")
            requested = true
        }
        func cancelSeeks() { calls.append("cancelSeeks") }
        func jumpPaused(to item: ObjectIdentifier) -> Bool {
            guard !removed.contains(item) else { return false }
            calls.append("jump \(name(item)) paused")
            currentLoadItem = item
            return true
        }
        func seekPlayer(to position: Double) { calls.append("seek \(position)") }
        func pausePlayer() { calls.append("pause") }
        func stopPlayer() { calls.append("stopPlayer") }
        func enterIdle() {
            calls.append("idle")
            isIdle = true
        }
    }

    private final class CoordinatorHarness {
        let a = NSObject(), b = NSObject()
        lazy var ia = ObjectIdentifier(a)
        lazy var ib = ObjectIdentifier(b)
        let player = FakeLoadPlayer()
        lazy var loads: StandardLoadCoordinator = {
            let loads = StandardLoadCoordinator(player: player, watched: true)
            player.coordinator = loads
            player.names = [ia: "A", ib: "B"]
            return loads
        }()

        /// A plays (loaded and reported); the player moves to B (a skip), not loaded yet.
        func skipFromAToB() {
            loads.failedLoads.adopted(ia)
            player.currentLoadItem = ib
            _ = loads.failedLoads.moved(ib)
        }

        func see(_ phase: StandardLoadPhase, owned: Bool = false) {
            loads.followLoad(StandardLoadObservation(item: player.currentLoadItem, phase: phase, readings: [0], ownedElsewhere: owned))
        }
    }

    func testStandardLoadCoordinatorASkipWaitsForItsTrackToLoadThenReportsItAndEnds() {
        let h = CoordinatorHarness()
        h.skipFromAToB()
        var outcomes: [StandardCommandLoadOutcome] = []
        h.loads.waitForCommandLoad { outcomes.append($0) }
        XCTAssertEqual(outcomes, [], "the skip waits for B's load")
        XCTAssertEqual(h.player.calls, ["check"], "the load is looked at now")
        h.see(.loading)
        h.see(.ready, owned: true)
        XCTAssertEqual(outcomes, [], "a seek owns the loading: not settled by it")
        h.see(.ready)
        XCTAssertEqual(h.player.calls, ["check", "active B from A"], "B loaded: reported")
        XCTAssertEqual(outcomes, [.loaded], "then the skip ends")
        XCTAssertTrue(h.loads.commandLoads.isWaiting == false)
    }

    func testStandardLoadCoordinatorAWaitReloadsATrackStandingStillAndEndsAtOnceWhenNothingIsToWaitFor() {
        let h = CoordinatorHarness()
        h.skipFromAToB()
        h.player.loadStateRawValue = "failed"
        var outcomes: [StandardCommandLoadOutcome] = []
        h.loads.waitForCommandLoad { outcomes.append($0) }
        XCTAssertEqual(h.player.calls, ["reload", "check"], "after a failure on it the player stands still: its load starts again")
        XCTAssertEqual(outcomes, [])
        // A skip to the track loaded and reported ends at once.
        h.player.currentLoadItem = h.ia
        h.loads.waitForCommandLoad { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.cancelled, .loaded], "the newer command cancelled the older wait")
        // Disposed: a waiting command ends cancelled, a new one does not wait.
        h.player.currentLoadItem = h.ib
        h.loads.waitForCommandLoad { outcomes.append($0) }
        h.loads.dispose()
        h.loads.waitForCommandLoad { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.cancelled, .loaded, .cancelled, .loaded])
        // Loads not watched (no load watch): a command does not wait.
        let unwatchedPlayer = FakeLoadPlayer()
        unwatchedPlayer.currentLoadItem = h.ib
        let unwatched = StandardLoadCoordinator(player: unwatchedPlayer, watched: false)
        unwatched.waitForCommandLoad { outcomes.append($0) }
        XCTAssertEqual(outcomes.last, .loaded)
        XCTAssertEqual(unwatchedPlayer.calls, [])
    }

    func testStandardLoadCoordinatorALoadGiveUpStopsThePlayerErrorsAndKeepsTheActiveTrack() {
        let h = CoordinatorHarness()
        h.skipFromAToB()
        h.loads.giveUpLoad(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)
        XCTAssertEqual(h.player.calls, ["stop", "gaveUp crossfade_prepare_timeout playbackError=true", "show A", "nowPlaying"])
        XCTAssertEqual(h.player.stoppedEmittedAtStop, false, "SwiftAudioEx's own stopped after a give-up is not emitted: the player is in error")
        XCTAssertEqual(h.loads.hostFailure?.code, standardPrepareTimeoutCode)
        XCTAssertFalse(h.loads.emitsPlayerState("stopped"))
        XCTAssertTrue(h.loads.emitsPlayerState("playing"))
        XCTAssertEqual(h.loads.failedLoads.phase, .failed(h.ib))
        // A stop ends the error: SwiftAudioEx's next stopped is emitted.
        _ = h.loads.giveUps.stopped(playerStopped: true)
        XCTAssertTrue(h.loads.emitsPlayerState("stopped"))
        // A command waiting for the load: rejected with the give-up, no playback error.
        let w = CoordinatorHarness()
        w.skipFromAToB()
        var outcomes: [StandardCommandLoadOutcome] = []
        w.loads.waitForCommandLoad { outcomes.append($0) }
        w.loads.giveUpLoad(.capExceeded, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)
        XCTAssertEqual(w.player.calls, ["check", "stop", "gaveUp crossfade_prepare_timeout playbackError=false", "show A", "nowPlaying"])
        XCTAssertEqual(outcomes, [.failed(code: standardPrepareTimeoutCode, message: standardLoadGiveUpMessage(.capExceeded, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000))])
    }

    func testStandardLoadCoordinatorASeekThatGivesUpStopsThePlayerOnItsTrackIssuedOrNot() {
        // Changed deliberately (fourth review, B3): a seek still waiting to be issued (its item
        // never loaded) gives up on its track too, as Android; only a seek for a track the player
        // left only rejects.
        let h = CoordinatorHarness()
        h.loads.failedLoads.adopted(h.ia)
        h.player.currentLoadItem = h.ia
        h.loads.seekTimedOut(issued: true, track: h.ib, message: "m", keptPosition: 30)
        h.loads.seekTimedOut(issued: false, track: h.ib, message: "m", keptPosition: 30)
        XCTAssertEqual(h.player.calls, [], "for a track the player left: only its rejection")
        XCTAssertNil(h.loads.hostFailure)
        h.loads.seekTimedOut(issued: true, track: h.ia, message: "The native seek made no progress for 10000 ms.", keptPosition: 30)
        XCTAssertEqual(h.player.calls, ["stop", "gaveUp standard_seek_timeout playbackError=false", "nowPlaying"])
        XCTAssertEqual(h.player.stoppedEmittedAtStop, false)
        XCTAssertEqual(h.loads.hostFailure?.code, "standard_seek_timeout")
        XCTAssertEqual(h.loads.giveUps.position(live: 0), 30, "its target stays the position")
        XCTAssertEqual(h.loads.failedLoads.phase, .loaded(h.ia), "a seek give-up on the loaded track leaves it loaded")
        // A native seek that ended unfinished: only the latest, on its track, while not disposed.
        let n = CoordinatorHarness()
        n.loads.failedLoads.adopted(n.ia)
        n.player.currentLoadItem = n.ia
        n.loads.nativeSeekEnded(didFinish: true, track: n.ia, isLatest: true, seekable: true, keptPosition: 5)
        n.loads.nativeSeekEnded(didFinish: false, track: n.ia, isLatest: false, seekable: true, keptPosition: 5)
        n.loads.nativeSeekEnded(didFinish: false, track: n.ib, isLatest: true, seekable: true, keptPosition: 5)
        // On an item AVPlayer cannot seek in: it completed where the player is.
        n.loads.nativeSeekEnded(didFinish: false, track: n.ia, isLatest: true, seekable: false, keptPosition: 5)
        XCTAssertEqual(n.player.calls, [])
        n.loads.nativeSeekEnded(didFinish: false, track: n.ia, isLatest: true, seekable: true, keptPosition: 5)
        XCTAssertEqual(n.player.calls, ["stop", "gaveUp standard_seek_cancelled playbackError=false", "nowPlaying"])
        let d = CoordinatorHarness()
        d.player.currentLoadItem = d.ia
        d.loads.dispose()
        d.loads.nativeSeekEnded(didFinish: false, track: d.ia, isLatest: true, seekable: true, keptPosition: 5)
        XCTAssertEqual(d.player.calls, [], "disposed: no give-up")
    }

    func testStandardLoadCoordinatorAPlayerFailureFailsTheLoadOnceAndRejectsTheWaitWithItsError() {
        let h = CoordinatorHarness()
        h.skipFromAToB()
        h.player.loadErrorMessage = "The track could not be played"
        var outcomes: [StandardCommandLoadOutcome] = []
        h.loads.waitForCommandLoad { outcomes.append($0) }
        h.see(.failed)
        h.see(.failed)
        XCTAssertEqual(h.player.calls, ["check", "show A", "nowPlaying"], "one failure per player error")
        XCTAssertEqual(outcomes, [.failed(code: standardLoadErrorCode, message: "The track could not be played")])
        XCTAssertTrue(h.loads.commandLoads.reportsFailure(of: h.ib), "the rejection is its report: no playback error")
        XCTAssertEqual(h.loads.failedLoads.phase, .failed(h.ib))
        XCTAssertNil(h.loads.hostFailure, "a player error is the player's own, not a give-up")
    }

    /// A, the selected first track (reported at once), failed to load: none is active; a skip to
    /// B waits for its load (the skip cleared the give-up's error).
    private func coordinatorWithASkipAfterAFailedFirstLoad(_ outcomes: @escaping (StandardCommandLoadOutcome) -> Void) -> CoordinatorHarness {
        let h = CoordinatorHarness()
        h.player.currentLoadItem = h.ia
        XCTAssertTrue(h.loads.failedLoads.moved(h.ia))
        h.loads.giveUpLoad(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)
        XCTAssertNil(h.loads.failedLoads.reported)
        _ = h.loads.giveUps.clear()
        h.loads.failedLoads.skipped()
        h.player.currentLoadItem = h.ib
        _ = h.loads.failedLoads.moved(h.ib)
        h.loads.waitForCommandLoad(outcomes)
        XCTAssertTrue(h.loads.watchesLoads)
        h.player.calls.removeAll()
        h.player.requested = true
        return h
    }

    func testStandardLoadCoordinatorACancelWithNoReportedTrackStopsTheLoadInIdleAndNeverReportsIt() {
        // Fourth review, B1 (Android: a*CancellingASkipWithNoActiveTrack*): a pause, stop or seek
        // that cancels the skip stops B's load and leaves no active track, as crossfade's
        // operation cancelled with no current track (active index -1): B is never reported.
        let expected: [String: [String]] = [
            "pause": ["cancelSeeks", "request pause", "stopPlayer", "idle", "request pause", "pause"],
            "stop": ["cancelSeeks", "request pause", "stopPlayer", "idle", "request pause", "stopPlayer"],
            "seek": ["request pause", "stopPlayer", "idle"],
        ]
        for command in ["pause", "stop", "seek"] {
            var outcomes: [StandardCommandLoadOutcome] = []
            let h = coordinatorWithASkipAfterAFailedFirstLoad { outcomes.append($0) }
            switch command {
            case "pause": h.loads.pause()
            case "stop": h.loads.stop()
            default:
                // Changed deliberately (crossfade's seek with no active track,
                // AndroidPlaybackOrchestrator.seekTo; Android:
                // aSeekCancellingASkipWithNoActiveTrackResolvesAndLoadsNothing): it rejected
                // standard_seek_unavailable; it now resolves and does nothing.
                var result: Result<Void, Error>?
                XCTAssertFalse(h.loads.beginSeek(to: 5) { result = $0 }, "no active track to seek in")
                XCTAssertNotNil(try? result?.get(), "the seek resolves")
            }
            XCTAssertEqual(h.player.calls, expected[command], command)
            XCTAssertEqual(outcomes, [.cancelled], command)
            XCTAssertTrue(h.player.isIdle, command)
            XCTAssertEqual(h.player.requested, false, "\(command): an ended interruption does not resume")
            // AVPlayer's late end of B's load is not looked at: B is never reported.
            XCTAssertFalse(h.loads.watchesLoads, "\(command): no load is watched with no active track")
            XCTAssertNil(h.loads.failedLoads.reported, command)
        }
        // A play (load, retry) from the idle starts the queue's first track, as crossfade's play
        // with no active track and Android's.
        XCTAssertEqual(standardFirstTrackToSelect(currentIndex: 1, count: 2), 0)
        XCTAssertNil(standardFirstTrackToSelect(currentIndex: 0, count: 2), "already on it")
        XCTAssertNil(standardFirstTrackToSelect(currentIndex: -1, count: 0), "an empty queue")
    }

    func testStandardLoadCoordinatorAQueueChangeWithNoActiveTrackLoadsNothing() {
        // Fifth review, F1 (Android: anAdd*, aMove*, removingThePlayersTrack*, aNewQueue
        // WithNoActiveTrack*): the idle a cancel entered lasts across queue changes, as crossfade's
        // queue change with no active track. SwiftAudioEx loads a new queue's first item (or the
        // next one when the current item left): the player stops at once, its state the player's
        // (stopped); its loading is not emitted and its item change reports nothing.
        var outcomes: [StandardCommandLoadOutcome] = []
        let h = coordinatorWithASkipAfterAFailedFirstLoad { outcomes.append($0) }
        h.loads.pause()
        XCTAssertTrue(h.player.isIdle)
        let c = NSObject()
        let phase = h.loads.failedLoads.phase
        // An add or a move (SwiftAudioEx stays stopped): nothing to do.
        h.player.loadStateRawValue = "stopped"
        h.player.calls.removeAll()
        h.loads.queueChanged()
        XCTAssertEqual(h.player.calls, [], "the player stays stopped")
        // A new queue (or the player's item removed): SwiftAudioEx loads its item.
        h.player.loadStateRawValue = "loading"
        XCTAssertFalse(h.loads.emitsPlayerState("loading"), "no loading with no active track")
        XCTAssertFalse(h.loads.itemMoved(ObjectIdentifier(c)), "not reported")
        XCTAssertEqual(h.loads.failedLoads.phase, phase, "the rule does not move")
        h.loads.queueChanged()
        XCTAssertEqual(h.player.calls, ["stopPlayer", "idle"], "stopped at once, the state the player's")
        XCTAssertTrue(h.loads.emitsPlayerState("stopped"))
        XCTAssertNil(h.loads.failedLoads.reported)
        XCTAssertFalse(h.loads.watchesLoads)
        // With an active track, a queue change is the player's own.
        h.player.isIdle = false
        h.player.calls.removeAll()
        h.loads.queueChanged()
        XCTAssertEqual(h.player.calls, [])
        XCTAssertTrue(h.loads.emitsPlayerState("loading"))
    }

    func testStandardLoadCoordinatorAnIdleActivationIsReportedOnceItsTrackLoaded() {
        // Fifth review, F5 (Android: aPlayWithNoActiveTrackReportsTheFirstTrackOnceItLoaded,
        // aNextWithNoActiveTrackWhoseTrackFailsReportsNothing): a play, retry, skip, next or load
        // with no active track reports its track once it loaded, as crossfade's play with no active
        // track (before: at once, then none again when it failed).
        for loads in [true, false] {
            var outcomes: [StandardCommandLoadOutcome] = []
            let h = coordinatorWithASkipAfterAFailedFirstLoad { outcomes.append($0) }
            h.loads.pause()
            // The play: the idle ends, the player starts the first track (A).
            h.player.isIdle = false
            h.player.currentLoadItem = h.ia
            h.player.calls.removeAll()
            XCTAssertFalse(h.loads.idleActivation(h.ia), "not told now")
            XCTAssertNil(h.loads.failedLoads.reported, "not reported before it loaded")
            XCTAssertEqual(h.loads.failedLoads.phase, .loading(h.ia))
            XCTAssertFalse(h.loads.itemMoved(h.ia), "its item change reports nothing")
            if loads {
                h.see(.ready)
                XCTAssertEqual(h.player.calls, ["active A from none"], "reported once it loaded")
                XCTAssertEqual(h.loads.failedLoads.reported, h.ia)
            } else {
                h.loads.giveUpLoad(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)
                XCTAssertFalse(h.player.calls.contains { $0.hasPrefix("active") }, "a track that fails is never reported (nor none again): \(h.player.calls)")
                XCTAssertNil(h.loads.failedLoads.reported)
            }
        }
        // With no load watch nothing tells when it loaded: told at once.
        let unwatched = StandardLoadCoordinator(player: FakeLoadPlayer(), watched: false)
        let a = NSObject()
        XCTAssertTrue(unwatched.idleActivation(ObjectIdentifier(a)))
        XCTAssertEqual(unwatched.failedLoads.reported, ObjectIdentifier(a))
    }

    func testStandardLoadCoordinatorACancelReturnsToTheReportedTrackPausedAtItsPosition() {
        // Fourth review, B2 (the sequence StandardPlaybackBackend ran untested): a pause (and
        // setPlayWhenReady(false)), stop or seek that cancels a skip goes back to A, paused, at the
        // position the player left it (a seek: at its own target, issued by the seek), and the
        // module's request is paused (an ended interruption does not resume). Android:
        // a*DuringASkipsLoad*.
        let expected: [String: [String]] = [
            "pause": ["cancelSeeks", "request pause", "jump A paused", "seek 42.0", "request pause", "pause"],
            "stop": ["cancelSeeks", "request pause", "jump A paused", "seek 42.0", "request pause", "stopPlayer"],
            "seek": ["request pause", "jump A paused"],
        ]
        for command in ["pause", "stop", "seek"] {
            let h = CoordinatorHarness()
            h.skipFromAToB()
            var outcomes: [StandardCommandLoadOutcome] = []
            h.loads.waitForCommandLoad { outcomes.append($0) }
            h.player.reportedPosition = 42
            h.player.requested = true
            h.player.calls.removeAll()
            switch command {
            case "pause": h.loads.pause()
            case "stop": h.loads.stop()
            default: XCTAssertTrue(h.loads.beginSeek(to: 30) { _ in XCTFail("the seek goes on") }, "A is active: the seek acts on it")
            }
            XCTAssertEqual(h.player.calls, expected[command], command)
            XCTAssertEqual(outcomes, [.cancelled], command)
            XCTAssertEqual(h.player.currentLoadItem, h.ia, command)
            XCTAssertEqual(h.player.requested, false, "\(command): an ended interruption does not resume")
            XCTAssertFalse(interruptionCountsAsPlaying(playWhenReady: h.player.requested ?? true, stateRawValue: "paused"), command)
            XCTAssertFalse(h.player.isIdle, command)
            // SwiftAudioEx's item change (itemMoved), then A loads (back on it): reported already,
            // nothing to tell.
            XCTAssertFalse(h.loads.failedLoads.moved(h.ia))
            h.player.calls.removeAll()
            h.see(.ready)
            XCTAssertEqual(h.player.calls, [], "\(command): B is never reported")
            XCTAssertEqual(h.loads.failedLoads.reported, h.ia, command)
        }
        // No wait to cancel: a pause only pauses, requested paused (the setPlayWhenReady(false)
        // path too).
        let p = CoordinatorHarness()
        p.loads.failedLoads.adopted(p.ia)
        p.player.currentLoadItem = p.ia
        p.player.requested = true
        p.loads.pause()
        XCTAssertEqual(p.player.calls, ["cancelSeeks", "request pause", "pause"])
        XCTAssertEqual(p.player.requested, false, "an ended interruption does not resume a pause")
        // The reported track left the queue meanwhile: the player stays.
        let r = CoordinatorHarness()
        r.skipFromAToB()
        r.loads.waitForCommandLoad { _ in }
        r.player.removed = [r.ia]
        r.player.calls.removeAll()
        XCTAssertEqual(r.loads.leaveCancelledLoad(cancelledWait: r.loads.commandLoads.cancel(), position: nil), .stays)
        XCTAssertEqual(r.player.currentLoadItem, r.ib)
    }

    func testStandardLoadCoordinatorAnUnissuedSeekThatGivesUpOnAFailedTrackLeavesThePlayToRetryIt() {
        // Fourth review, B3 (Android: aSeekOnATrackWhosePlaylistsNeverAnswer...). Changed
        // deliberately (owner decision, 2026-11-17, LOAD-06): after a failed skip a seek acts on
        // the active track (testStandardLoadCoordinatorASeekOrStopAfterAFailedSkipActsOnTheActiveTrack),
        // so the seek that acts on a failed track is the one with no active track: A, the selected
        // first track, fails (its playlists never answer); seekTo acts on A, whose item never
        // exists: the seek is never issued and gives up by its limit. It stops A's load, fails A
        // again and leaves the player in error (its rejection is the report), no load give-up
        // follows, and the play retries A.
        let h = CoordinatorHarness()
        h.player.currentLoadItem = h.ia
        XCTAssertTrue(h.loads.failedLoads.moved(h.ia))
        h.loads.giveUpLoad(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)
        XCTAssertEqual(h.loads.failedLoads.phase, .failed(h.ia))
        XCTAssertNil(h.loads.failedLoads.reported)
        h.player.calls.removeAll()
        XCTAssertTrue(h.loads.beginSeek(to: 30) { _ in XCTFail("the seek goes on") })
        XCTAssertEqual(h.player.calls, [], "none reported: the seek acts on the failed track")
        XCTAssertEqual(h.loads.failedLoads.phase, .loading(h.ia), "A retried")
        XCTAssertNil(h.loads.hostFailure, "the seek is a command: the give-up's error ended")
        XCTAssertTrue(h.loads.watchesLoads)
        h.loads.seekTimedOut(issued: false, track: h.ia, message: "The native seek did not complete within 30000 ms.", keptPosition: 30)
        XCTAssertEqual(h.player.calls, ["stop", "gaveUp standard_seek_timeout playbackError=false", "show none", "nowPlaying"])
        XCTAssertEqual(h.loads.hostFailure?.code, "standard_seek_timeout")
        XCTAssertEqual(h.loads.failedLoads.phase, .failed(h.ia), "A failed again")
        XCTAssertFalse(h.loads.watchesLoads, "no load give-up (prepareTimeoutMs, a playback error) after it")
        XCTAssertEqual(h.loads.failedLoads.play(), h.ia, "the play retries A")
    }

    func testStandardLoadCoordinatorASeekOrStopAfterAFailedSkipActsOnTheActiveTrack() {
        // Owner decision, 2026-11-17 (LOAD-06 flipped; Android:
        // aSeekThatGivesUpAfterAFailedSkip..., aSeekAfterASkipThatFailedWithAPlayerError...,
        // aStopAfterAFailedSkip...): A plays, a skip to B fails. A seek acts on A, the track the
        // app reads, as crossfade's: the player goes back to A, paused, where the seek issues its
        // target; B is never reported. A seek that then gives up on A re-fails nothing (A stays
        // loaded and active) and the play plays A. A stop goes back to A too, at its last
        // position, and stops there.
        for command in ["seek", "stop"] {
            let h = CoordinatorHarness()
            h.skipFromAToB()
            var outcomes: [StandardCommandLoadOutcome] = []
            h.loads.waitForCommandLoad { outcomes.append($0) }
            h.loads.giveUpLoad(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)
            XCTAssertEqual(h.loads.failedLoads.phase, .failed(h.ib), command)
            h.player.reportedPosition = 42
            h.player.requested = true
            // The give-up stopped SwiftAudioEx.
            h.player.isPlayerStopped = true
            h.player.calls.removeAll()
            if command == "seek" {
                XCTAssertTrue(h.loads.beginSeek(to: 30) { _ in XCTFail("the seek goes on") })
                XCTAssertEqual(h.player.calls, ["request pause", "jump A paused"], "the seek goes back to A")
            } else {
                h.loads.stop()
                XCTAssertEqual(h.player.calls, ["cancelSeeks", "request pause", "jump A paused", "seek 42.0", "request pause", "stopPlayer", "gaveUp none playbackError=false"], "the stop goes back to A, at its last position")
            }
            XCTAssertEqual(h.player.currentLoadItem, h.ia, command)
            XCTAssertEqual(h.loads.failedLoads.phase, .loaded(h.ia), "\(command): A is the player's track again")
            XCTAssertNil(h.loads.hostFailure, command)
            XCTAssertFalse(h.loads.failedLoads.moved(h.ia), "\(command): back on A, nothing to report")
            XCTAssertNil(h.loads.failedLoads.play(), "\(command): the play plays A, nothing to reload")
            h.player.calls.removeAll()
            h.see(.ready)
            XCTAssertEqual(h.player.calls, [], "\(command): B is never reported")
            XCTAssertEqual(h.loads.failedLoads.reported, h.ia, command)
            if command == "seek" {
                // The seek gives up on A: A stays loaded and active (the re-fail is a no-op there).
                h.loads.seekTimedOut(issued: true, track: h.ia, message: "The native seek made no progress for 10000 ms.", keptPosition: 30)
                XCTAssertEqual(h.player.calls, ["stop", "gaveUp standard_seek_timeout playbackError=false", "nowPlaying"])
                XCTAssertEqual(h.loads.failedLoads.phase, .loaded(h.ia))
                XCTAssertEqual(h.loads.failedLoads.active, h.ia)
                XCTAssertNil(h.loads.failedLoads.play(), "the play plays A")
            }
        }
        // While a natural advance loads (no wait, B not failed): a seek goes back to A too; a
        // pause does not move the player.
        let n = CoordinatorHarness()
        n.skipFromAToB()
        n.loads.pause()
        XCTAssertEqual(n.player.currentLoadItem, n.ib, "a pause with nothing cancelled stays")
        n.player.calls.removeAll()
        XCTAssertTrue(n.loads.beginSeek(to: 30) { _ in XCTFail("the seek goes on") })
        XCTAssertEqual(n.player.calls, ["request pause", "jump A paused"])
        XCTAssertEqual(n.player.currentLoadItem, n.ia)
    }

    func testStandardLoadCoordinatorASeekAfterAFailedSkipPlaysOnlyAsRequestedBeforeTheFailure() {
        // Fifth review, F2 (Android: aSeekAfterASkipThatGaveUp..., aSeekAfterASkipThatFailedWith
        // APlayerError..., aSeekAfterAGiveUpThenAPause..., aSeekAfterASkipThatFailedWhilePaused...):
        // as crossfade's seek after a failed skip (its failure keeps playWhenReady), the seek goes
        // back to A and, once done (SwiftAudioEx issues it once the item loaded), plays when
        // playback was requested before the failure; a pause after the failure ends that request;
        // a cancelled skip's seek stays paused (crossfade's cancelled operation).
        for (name, requestedBefore, failure, pauseAfter, succeeded, resumes) in [
            ("give-up, playing", true, "giveUp", false, true, true),
            ("give-up, the seek fails", true, "giveUp", false, false, false),
            ("give-up, paused before", false, "giveUp", false, true, false),
            ("give-up, then a pause", true, "giveUp", true, true, false),
            ("player error, playing", true, "error", false, true, true),
            ("player error, paused before", false, "error", false, true, false),
        ] {
            let h = CoordinatorHarness()
            h.skipFromAToB()
            h.player.requested = requestedBefore
            var outcomes: [StandardCommandLoadOutcome] = []
            h.loads.waitForCommandLoad { outcomes.append($0) }
            if failure == "giveUp" {
                h.loads.giveUpLoad(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)
            } else {
                h.see(.failed)
            }
            XCTAssertEqual(h.loads.failedLoads.phase, .failed(h.ib), name)
            if pauseAfter { h.loads.pause() }
            h.player.calls.removeAll()
            XCTAssertTrue(h.loads.beginSeek(to: 30) { _ in XCTFail("the seek goes on") }, name)
            XCTAssertEqual(h.player.calls, ["request pause", "jump A paused"], "\(name): back to A, paused until the seek is done")
            h.loads.seekFinished(succeeded: succeeded)
            XCTAssertEqual(h.player.calls.last == "resume", resumes, "\(name): \(h.player.calls)")
        }
        // A seek that cancels a waiting skip (crossfade's cancelled operation) stays paused.
        let c = CoordinatorHarness()
        c.skipFromAToB()
        c.player.requested = true
        c.loads.waitForCommandLoad { _ in }
        XCTAssertTrue(c.loads.beginSeek(to: 30) { _ in XCTFail("the seek goes on") })
        c.loads.seekFinished(succeeded: true)
        XCTAssertFalse(c.player.calls.contains("resume"), "a cancelled skip's seek stays paused")
    }

    func testStandardSeekAndLoadLimitsAreIndependent() {
        // Fourth review, B3: standardSeekTimeoutMs and prepareTimeoutMs set apart (Android:
        // aSeekWithALimit*). A seek's wait has its own limits (StallWaitDriver with the seek's
        // total; a seek not issued yet has no reading, only that total); the load it owns is not
        // watched meanwhile, whatever prepareTimeoutMs (shorter or longer).
        for (seekTotalMs, loadTotalMs) in [(3_000, 60_000), (120_000, 5_000)] {
            var seek = StallWatch(stallTimeoutMs: 10_000, totalTimeoutMs: seekTotalMs, startedAt: 0)
            let limit = Double(seekTotalMs) / 1000
            XCTAssertEqual(seek.capVerdict(at: limit - 0.001), .wait)
            XCTAssertEqual(seek.capVerdict(at: limit), .capExceeded, "the seek's own total: \(seekTotalMs) ms")
            // Issued, its buffered position not growing: stallTimeoutMs, unless its total ends first.
            XCTAssertEqual(seek.check(at: 0, readings: [0]), .wait)
            XCTAssertEqual(seek.check(at: 10, readings: [0]), seekTotalMs <= 10_000 ? .capExceeded : .stalled)
            var now: TimeInterval = 0
            let watch = StandardLoadWatch(stallTimeoutMs: { 10_000 }, totalTimeoutMs: { loadTotalMs }, now: { now })
            let b = NSObject()
            for t in stride(from: 0.0, through: limit + 1, by: 0.5) {
                now = t
                XCTAssertNil(watch.check(StandardLoadObservation(item: ObjectIdentifier(b), phase: .loading, readings: [0], ownedElsewhere: true)),
                             "the seek owns the load: prepareTimeoutMs (\(loadTotalMs) ms) does not end it at \(t) s")
            }
        }
    }

    func testStandardLoadCoordinatorASeekByIsRelativeToThePositionTheAppReads() {
        // Fourth review, B4 (Android: aSeekByDuringASkipsLoadIsRelativeToTheActiveTracksPosition):
        // while B loads, the app reads A's position (3.134 s, ReportedTrackProgress), and seekBy
        // is relative to it (the seek then acts on A, the skip cancelled), as crossfade's.
        let h = CoordinatorHarness()
        h.skipFromAToB()
        h.player.reportedPosition = 3.134
        XCTAssertEqual(h.loads.seekTarget(by: 2), 5.134, accuracy: 1e-9)
        XCTAssertEqual(h.loads.seekTarget(by: -10), 0, "not before the start")
    }

    func testStandardCommandLoadResultIsTheCommandsResolution() {
        XCTAssertNoThrow(try standardCommandLoadResult(.loaded).get())
        for (outcome, code) in [(StandardCommandLoadOutcome.failed(code: "crossfade_prepare_timeout", message: "m"), "crossfade_prepare_timeout"),
                                (.cancelled, "cancelled")] {
            guard case let .failure(error) = standardCommandLoadResult(outcome) else { return XCTFail("\(outcome) fails") }
            XCTAssertEqual((error as NSError).userInfo["code"] as? String, code)
        }
    }

    func testStandardGiveUpOfALoadNoCommandWaitsForIsAnErrorStateAndAPlaybackError() {
        let giveUps = StandardGiveUps()
        let loads = StandardCommandLoad()
        let track = NSObject()
        var reports: [StandardGiveUpReport] = []
        giveUps.loadGaveUp(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000, item: ObjectIdentifier(track), commandLoads: loads) {
            reports.append($0)
        }
        let failure: [String: Any] = ["code": "crossfade_prepare_timeout", "message": "The track did not become ready (no progress for 10000 ms)."]
        XCTAssertEqual(reports.count, 1, "stopped once")
        let events = reports.first?.events ?? []
        XCTAssertEqual(events.map { $0.name }, ["playback-state", "playback-error"])
        XCTAssertEqual(events.first.map { $0.body as NSDictionary }, ["state": "error", "error": failure] as NSDictionary)
        XCTAssertEqual(events.last.map { $0.body as NSDictionary }, failure as NSDictionary)
        XCTAssertEqual(giveUps.failure, IOSPlaybackErrorSnapshot(message: "The track did not become ready (no progress for 10000 ms).", code: "crossfade_prepare_timeout"))
        XCTAssertEqual(giveUps.position(live: 4), 4)
    }

    func testStandardGiveUpOfALoadACommandWaitsForRejectsItAndIsNoPlaybackError() {
        let giveUps = StandardGiveUps()
        let loads = StandardCommandLoad()
        let track = NSObject()
        var order: [String] = []
        var outcomes: [StandardCommandLoadOutcome] = []
        var reports: [StandardGiveUpReport] = []
        loads.begin(target: ObjectIdentifier(track), active: nil, reported: nil) {
            outcomes.append($0)
            order.append("command")
        }
        giveUps.loadGaveUp(.capExceeded, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000, item: ObjectIdentifier(track), commandLoads: loads) {
            reports.append($0)
            order.append("stop")
        }
        XCTAssertEqual(reports.first?.events.map { $0.name }, ["playback-state"], "the rejection is the report")
        XCTAssertEqual(outcomes, [.failed(code: "crossfade_prepare_timeout", message: "The track did not become ready (over the 60000 ms limit).")])
        XCTAssertEqual(order, ["stop", "command"], "the player stops before the command ends")
        XCTAssertNotNil(giveUps.failure, "in error until the next command")
        XCTAssertFalse(loads.reportsFailure(of: ObjectIdentifier(track)), "a later failure of it is reported again")
    }

    func testStandardGiveUpOfASeekKeepsItsTargetAndIsNoPlaybackError() {
        let giveUps = StandardGiveUps()
        var reports: [StandardGiveUpReport] = []
        let failure = IOSPlaybackErrorSnapshot(message: "The native seek made no progress for 10000 ms.", code: "standard_seek_timeout")
        giveUps.seekGaveUp(failure, keptPosition: 42) { reports.append($0) }
        XCTAssertEqual(reports.count, 1)
        let events = reports.first?.events ?? []
        XCTAssertEqual(events.map { $0.name }, ["playback-state"])
        XCTAssertEqual(events.first.map { $0.body as NSDictionary }, ["state": "error", "error": failure.dictionary] as NSDictionary)
        XCTAssertEqual(giveUps.failure, failure)
        XCTAssertEqual(giveUps.position(live: 0), 42, "SwiftAudioEx's stop reset its own position")
    }

    func testStandardGiveUpTheNextCommandClearsTheError() {
        let giveUps = StandardGiveUps()
        let loads = StandardCommandLoad()
        let track = NSObject()
        giveUps.loadGaveUp(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000, item: ObjectIdentifier(track), commandLoads: loads) { _ in }
        XCTAssertNil(giveUps.clear(), "a load keeps no position")
        XCTAssertNil(giveUps.failure)
        XCTAssertEqual(giveUps.position(live: 3), 3)
        // A play or retry after a failed seek reloads at its target, then the live position.
        giveUps.seekGaveUp(IOSPlaybackErrorSnapshot(message: "m", code: "standard_seek_timeout"), keptPosition: 42) { _ in }
        XCTAssertEqual(giveUps.clear(), 42)
        XCTAssertNil(giveUps.failure)
        XCTAssertEqual(giveUps.position(live: 0), 0)
        // A stop or pause: out of the error, the target stays the position until the track loads.
        giveUps.seekGaveUp(IOSPlaybackErrorSnapshot(message: "m", code: "standard_seek_timeout"), keptPosition: 42) { _ in }
        giveUps.keep(giveUps.clear())
        XCTAssertNil(giveUps.failure)
        XCTAssertEqual(giveUps.position(live: 0), 42)
    }

    func testStandardGiveUpAStopEndsTheErrorStoppedAndAPauseKeepsIt() {
        // As Android's standard player (StandardBackendHlsTest.afterAGiveUpAPauseKeepsTheErrorAndAStopEndsItStopped).
        let giveUps = StandardGiveUps()
        let loads = StandardCommandLoad()
        let track = NSObject()
        giveUps.loadGaveUp(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000, item: ObjectIdentifier(track), commandLoads: loads) { _ in }
        // A pause (setPlayWhenReady(false)) is no command on the error: nothing changes.
        XCTAssertNotNil(giveUps.failure, "a pause keeps the error")
        // A stop ends it, and the app is told the player stopped (SwiftAudioEx, already stopped
        // by the give-up, emits nothing).
        let stop = giveUps.stopped(playerStopped: true)
        XCTAssertNil(giveUps.failure)
        let events = stop?.events ?? []
        XCTAssertEqual(events.map { $0.name }, ["playback-state"])
        XCTAssertEqual(events.first.map { $0.body as NSDictionary }, ["state": "stopped"] as NSDictionary)
        // Out of the error: a stop emits nothing more here (the player's own stop does).
        XCTAssertNil(giveUps.stopped(playerStopped: true))
        // A player not stopped emits its own stopped state.
        giveUps.loadGaveUp(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000, item: ObjectIdentifier(track), commandLoads: loads) { _ in }
        XCTAssertNil(giveUps.stopped(playerStopped: false))
        XCTAssertNil(giveUps.failure)
        // A failed seek's target stays the position after the stop.
        giveUps.seekGaveUp(IOSPlaybackErrorSnapshot(message: "m", code: "standard_seek_timeout"), keptPosition: 42) { _ in }
        XCTAssertNotNil(giveUps.stopped(playerStopped: true))
        XCTAssertNil(giveUps.failure)
        XCTAssertEqual(giveUps.position(live: 0), 42)
    }

    func testStandardLoadWithNoItemOrAnotherOwnerNothingIsWatched() {
        let h = LoadWatchHarness()
        XCTAssertNil(h.observe(h.a, .loading))
        XCTAssertNil(h.observe(nil, .loading))
        h.now = 30
        XCTAssertNil(h.observe(nil, .loading))
        XCTAssertNil(h.observe(h.a, .loading))
    }

    func testStandardLoadPhaseCountsAnItemReadyOnlyOnceItPlaysOrHasMedia() {
        XCTAssertEqual(standardLoadPhase(stateRawValue: "loading", bufferedPosition: 0), .loading)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "buffering", bufferedPosition: 4), .loading)
        // An HLS item "ready to play" before any segment arrived is still loading.
        XCTAssertEqual(standardLoadPhase(stateRawValue: "ready", bufferedPosition: 0), .loading)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "paused", bufferedPosition: 0), .loading)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "ready", bufferedPosition: 4), .ready)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "playing", bufferedPosition: 0), .ready)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "ended", bufferedPosition: 0), .ready)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "stopped", bufferedPosition: 4), .idle)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "idle", bufferedPosition: 0), .idle)
        XCTAssertEqual(standardLoadPhase(stateRawValue: "failed", bufferedPosition: 0), .failed)
        XCTAssertEqual(standardLoadGiveUpMessage(.stalled, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000), "The track did not become ready (no progress for 10000 ms).")
        XCTAssertEqual(standardLoadGiveUpMessage(.capExceeded, stallTimeoutMs: 10_000, totalTimeoutMs: 60_000), "The track did not become ready (over the 60000 ms limit).")
        XCTAssertEqual(standardPrepareTimeoutCode, "crossfade_prepare_timeout")
    }

    func testAGiveUpIsWordedAsOnAndroidWithoutEngineNames() {
        // Same text as Android (StallWatchTest.aGiveUpIsWordedAsOnIosWithoutEngineNames).
        XCTAssertEqual(
            crossfadeLoadTimeoutMessage(StallVerdict.stalled.reason(stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)),
            "Crossfade engine did not become ready (no progress for 10000 ms)."
        )
        XCTAssertEqual(
            crossfadeLoadTimeoutMessage(StallVerdict.capExceeded.reason(stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)),
            "Crossfade engine did not become ready (over the 60000 ms limit)."
        )
        XCTAssertEqual(
            crossfadeSeekTimeoutMessage(StallVerdict.stalled.reason(stallTimeoutMs: 10_000, totalTimeoutMs: 60_000)),
            "Crossfade engine seek did not finish (no progress for 10000 ms)."
        )
    }

    func testAFailedLoadStopsLoadingBeforeItCompletesAndASuccessDoesNot() {
        var events: [String] = []
        settleCrossfadeLoad(.failure(NSError(domain: "AVFoundationErrorDomain", code: -11800)),
                            stopLoading: { events.append("stop") }, complete: { _ in events.append("complete") })
        XCTAssertEqual(events, ["stop", "complete"])
        events.removeAll()
        settleCrossfadeLoad(.success(()), stopLoading: { events.append("stop") }, complete: { _ in events.append("complete") })
        XCTAssertEqual(events, ["complete"])
    }

    func testAFailedLatestSeekStopsLoadingAndAReplacedOneDoesNot() {
        let seeks = SeekSequence()
        let replaced = seeks.begin()
        let latest = seeks.begin()
        var events: [String] = []
        let unfinished = NSError(domain: "RNTP-Crossfade", code: 3, userInfo: ["code": "crossfade_engine_error"])
        settleCrossfadeSeek(.failure(unfinished), isLatest: seeks.isLatest(replaced),
                            stopLoading: { events.append("stop") }, complete: { _ in events.append("complete") })
        XCTAssertEqual(events, ["complete"], "a seek a newer one replaced does not stop the track")
        events.removeAll()
        settleCrossfadeSeek(.failure(unfinished), isLatest: seeks.isLatest(latest),
                            stopLoading: { events.append("stop") }, complete: { _ in events.append("complete") })
        XCTAssertEqual(events, ["stop", "complete"])
        events.removeAll()
        settleCrossfadeSeek(.success(()), isLatest: seeks.isLatest(latest),
                            stopLoading: { events.append("stop") }, complete: { _ in events.append("complete") })
        XCTAssertEqual(events, ["complete"])
    }

    // The stall watch: every wait gives up after `stallTimeoutMs` with no progress, or at its cap.

    func testStallWatchKeepsASlowButProgressingLoadPastTheStallTimeout() {
        // A load that adds a little media every second, with a 3 s stall timeout: it survives
        // far beyond 3 s, until its 60 s cap.
        var watch = StallWatch(stallTimeoutMs: 3_000, totalTimeoutMs: 60_000, startedAt: 100)
        XCTAssertEqual(watch.check(at: 100, readings: [0]), .wait)
        for second in 1..<60 {
            XCTAssertEqual(watch.check(at: 100 + Double(second), readings: [Double(second) * 0.2]), .wait, "\(second)")
        }
        XCTAssertEqual(watch.check(at: 160, readings: [12]), .capExceeded)
    }

    func testStallWatchFailsAStalledLoadAtTheStallTimeout() {
        var watch = StallWatch(stallTimeoutMs: 3_000, totalTimeoutMs: 60_000, startedAt: 0)
        XCTAssertEqual(watch.check(at: 0, readings: [4]), .wait)
        XCTAssertEqual(watch.check(at: 1, readings: [5]), .wait)
        // Nothing more loads from t = 1 s: it fails 3 s later, not at the cap.
        XCTAssertEqual(watch.check(at: 2, readings: [5]), .wait)
        XCTAssertEqual(watch.check(at: 3.999, readings: [5]), .wait)
        XCTAssertEqual(watch.check(at: 4, readings: [5]), .stalled)
    }

    func testStallWatchCountsAnyGrowingReadingAndGrowthAfterADrop() {
        var watch = StallWatch(stallTimeoutMs: 1_000, totalTimeoutMs: 60_000, startedAt: 0)
        XCTAssertEqual(watch.check(at: 0, readings: [10, 0]), .wait)
        // The second reading (time played) grows while the first does not.
        XCTAssertEqual(watch.check(at: 0.9, readings: [10, 1]), .wait)
        XCTAssertEqual(watch.check(at: 1.8, readings: [10, 2]), .wait)
        // A seek back drops the buffer: not progress, but growth from the lower value is.
        XCTAssertEqual(watch.check(at: 2.7, readings: [3, 2]), .wait)
        XCTAssertEqual(watch.check(at: 3.5, readings: [4, 2]), .wait)
        XCTAssertEqual(watch.check(at: 4.5, readings: [4, 2]), .stalled)
    }

    func testStallWatchCapWinsAndAStageReachedCountsAsProgress() {
        var watch = StallWatch(stallTimeoutMs: 1_000, totalTimeoutMs: 5_000, startedAt: 0)
        // The playable stage has no signal: only the cap bounds it.
        XCTAssertEqual(watch.capVerdict(at: 4.9), .wait)
        XCTAssertEqual(watch.capVerdict(at: 5), .capExceeded)
        // A playable asset at 4 s restarts the stall clock; the cap still counts from the start.
        watch.noteProgress(at: 4)
        XCTAssertEqual(watch.check(at: 4, readings: [0]), .wait)
        XCTAssertEqual(watch.check(at: 4.9, readings: [0]), .wait)
        XCTAssertEqual(watch.check(at: 5, readings: [1]), .capExceeded)
    }

    // The wait driver: the engines' and the standard seek's waits run on it.

    /// A manual clock and scheduler: `run()` fires the pending checks one at a time.
    private final class ManualWaitClock {
        var now: TimeInterval = 0
        var pending: [(Int, () -> Void)] = []
        func schedule(_ delayMs: Int, _ work: @escaping () -> Void) { pending.append((delayMs, work)) }
        /// Fires the checks until none is pending, at most `limit` of them (a broken driver could
        /// otherwise check forever); returns how many fired.
        @discardableResult
        func runUntilIdle(limit: Int = 1_000) -> Int {
            var fired = 0
            while fired < limit, step() { fired += 1 }
            return fired
        }
        /// Fires the next check after its delay; false when none is pending.
        @discardableResult
        func step() -> Bool {
            guard !pending.isEmpty else { return false }
            let (delayMs, work) = pending.removeFirst()
            now += Double(delayMs) / 1000
            work()
            return true
        }
    }

    private func makeDriver(
        _ clock: ManualWaitClock,
        stallMs: Int = 1_000,
        totalMs: Int = 10_000,
        readings: @escaping () -> [Double]?,
        gaveUp: @escaping (StallVerdict) -> Void
    ) -> StallWaitDriver {
        StallWaitDriver(
            stallTimeoutMs: stallMs,
            totalTimeoutMs: totalMs,
            intervalMs: 250,
            now: { clock.now },
            schedule: { clock.schedule($0, $1) },
            readings: readings,
            onGiveUp: { verdict, _ in gaveUp(verdict) }
        )
    }

    func testWaitDriverKeepsASlowButProgressingWaitUntilItsCap() {
        let clock = ManualWaitClock()
        var loaded = 0.0
        var verdicts: [StallVerdict] = []
        let driver = makeDriver(clock, readings: { loaded += 0.01; return [loaded] }, gaveUp: { verdicts.append($0) })
        driver.start()
        // A little more every 250 ms: far past the 1 s stall timeout, it fails only at 10 s.
        let checks = clock.runUntilIdle()
        XCTAssertEqual(verdicts, [.capExceeded])
        XCTAssertEqual(checks, 40)
        XCTAssertEqual(clock.now, 10, accuracy: 0.0001)
        XCTAssertFalse(driver.isActive)
    }

    func testWaitDriverFailsAStalledWaitAtTheStallTimeout() {
        let clock = ManualWaitClock()
        var verdicts: [StallVerdict] = []
        let driver = makeDriver(clock, readings: { [3] }, gaveUp: { verdicts.append($0) })
        driver.start()
        clock.runUntilIdle()
        XCTAssertEqual(verdicts, [.stalled])
        XCTAssertEqual(clock.now, 1, accuracy: 0.0001)
    }

    func testWaitDriverWithoutASignalIsBoundOnlyByItsCapAndAStageRestartsTheStallClock() {
        let clock = ManualWaitClock()
        var signal: [Double]? = nil
        var verdicts: [StallVerdict] = []
        let driver = makeDriver(clock, totalMs: 4_000, readings: { signal }, gaveUp: { verdicts.append($0) })
        driver.start()
        // No signal (an asset not yet playable, a seek not yet issued): 2 s pass, no stall.
        for _ in 0..<8 { clock.step() }
        XCTAssertTrue(verdicts.isEmpty)
        XCTAssertEqual(clock.now, 2, accuracy: 0.0001)
        // The stage is reached: the stall clock restarts, the cap still counts from the start.
        signal = [0]
        driver.noteProgress()
        clock.runUntilIdle()
        XCTAssertEqual(verdicts, [.stalled])
        XCTAssertEqual(clock.now, 3, accuracy: 0.0001)

        let capped = ManualWaitClock()
        var capVerdicts: [StallVerdict] = []
        makeDriver(capped, totalMs: 3_000, readings: { nil }, gaveUp: { capVerdicts.append($0) }).start()
        capped.runUntilIdle()
        XCTAssertEqual(capVerdicts, [.capExceeded])
        XCTAssertEqual(capped.now, 3, accuracy: 0.0001)
    }

    func testWaitDriverReschedulesUntilCancelledAndThenNeverGivesUp() {
        let clock = ManualWaitClock()
        var verdicts: [StallVerdict] = []
        var reads = 0
        let driver = makeDriver(clock, readings: { reads += 1; return [Double(reads)] }, gaveUp: { verdicts.append($0) })
        driver.start()
        for _ in 0..<5 { XCTAssertTrue(clock.step()) }
        XCTAssertEqual(reads, 5)
        XCTAssertEqual(clock.pending.count, 1)
        driver.cancel()
        // The pending check fires once and schedules nothing more.
        XCTAssertEqual(clock.runUntilIdle(), 1)
        XCTAssertEqual(reads, 5)
        XCTAssertTrue(verdicts.isEmpty)
        XCTAssertTrue(clock.pending.isEmpty)
    }

    func testWaitDriverReleasesItsClosuresWhenCancelledAndWhenItGivesUp() {
        // Like an engine wait: the closures reach back to the driver (through the caller's state),
        // so the driver and the completion it holds are freed only if the closures are released.
        final class Caller { var driver: StallWaitDriver? }
        for giveUp in [false, true] {
            let clock = ManualWaitClock()
            weak var weakCaller: Caller?
            weak var weakDriver: StallWaitDriver?
            var gaveUp = 0
            autoreleasepool {
                let caller = Caller()
                weakCaller = caller
                let driver = makeDriver(
                    clock,
                    readings: { _ = caller.driver; return [1] },
                    gaveUp: { _ in _ = caller.driver; gaveUp += 1 }
                )
                caller.driver = driver
                weakDriver = driver
                driver.start()
                clock.step()
                if !giveUp { driver.cancel() }
            }
            clock.runUntilIdle()
            XCTAssertEqual(gaveUp, giveUp ? 1 : 0)
            XCTAssertNil(weakCaller, "closures kept, giveUp=\(giveUp)")
            XCTAssertNil(weakDriver, "driver kept, giveUp=\(giveUp)")
        }
    }

    func testWaitDriverChecksEveryPollIntervalAndStartsOnce() {
        // The documented poll interval: a wait fails at most this much after its limit.
        XCTAssertEqual(stallCheckIntervalMs, 250)
        var delays: [Int] = []
        let driver = StallWaitDriver(
            stallTimeoutMs: 1_000,
            totalTimeoutMs: 10_000,
            now: { 0 },
            schedule: { delay, _ in delays.append(delay) },
            readings: { [0] },
            onGiveUp: { _, _ in }
        )
        driver.start()
        driver.start()
        XCTAssertEqual(delays, [stallCheckIntervalMs])
    }

    func testStallWatchDoesNotCountADropAsProgress() {
        var watch = StallWatch(stallTimeoutMs: 1_000, totalTimeoutMs: 60_000, startedAt: 0)
        XCTAssertEqual(watch.check(at: 0, readings: [8]), .wait)
        // A seek back drops the reading; nothing loads after it: stalled 1 s after the start.
        XCTAssertEqual(watch.check(at: 0.5, readings: [2]), .wait)
        XCTAssertEqual(watch.check(at: 1, readings: [2]), .stalled)
    }

    func testStallWatchStartsANewBaselineAfterAStage() {
        var watch = StallWatch(stallTimeoutMs: 1_000, totalTimeoutMs: 60_000, startedAt: 0)
        XCTAssertEqual(watch.check(at: 0, readings: [5]), .wait)
        watch.noteProgress(at: 1)
        // The first reading after the stage is a baseline, not growth from the old reading.
        XCTAssertEqual(watch.check(at: 1.5, readings: [6]), .wait)
        XCTAssertEqual(watch.check(at: 2, readings: [6]), .stalled)
    }

    // A wait's progress from its AVPlayerItem: after a failed request or a variant switch, the
    // bytes the access log posts late are not progress until new media is buffered.

    /// A snapshot whose buffer is `loaded` seconds from the start of the track.
    private func snapshot(
        loaded: Double, bytes: Double, events: Int, errors: Int
    ) -> ItemLoadSnapshot {
        snapshot(ranges: loaded > 0 ? [0...loaded] : [], bytes: bytes, events: events, errors: errors)
    }

    private func snapshot(
        ranges: [ClosedRange<Double>], bytes: Double, events: Int, errors: Int
    ) -> ItemLoadSnapshot {
        ItemLoadSnapshot(loadedRanges: ranges, transferredBytes: bytes, accessLogEvents: events, errorLogEntries: errors)
    }

    func testItemLoadProgressPausesTheByteCountAfterAnErrorOrASwitchUntilNewMediaIsBuffered() {
        // The simulator's sequence when every segment fails part way (3000 bytes, then the
        // connection drops): r0's partial bytes are buffered, its retries fail, then the player
        // switches to r1 and only then posts r0's bytes, while the buffer drops to r1's part.
        var progress = ItemLoadProgress()
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 0, bytes: 0, events: 0, errors: 0)), [0, 0])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 3.67, bytes: 0, events: 0, errors: 0)), [3.67, 0])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 3.67, bytes: 0, events: 0, errors: 1)), [3.67, 0])
        XCTAssertEqual(progress.byteCounting, .pausedUntilMedia)
        // The switch posts the left variant's 3000 bytes: not counted.
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 1.06, bytes: 3_000, events: 1, errors: 2)), [3.67, 0])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 1.06, bytes: 3_000, events: 1, errors: 2)), [3.67, 0])
        // Buffering again time that was buffered before is not new media either.
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 3.5, bytes: 3_000, events: 1, errors: 2)), [3.67, 0])
        XCTAssertEqual(progress.byteCounting, .pausedUntilMedia)
        // Mid-track (the simulator, every rendition failing its third segment): each switch
        // downloads the new rendition's first two segments again, media already buffered. Those
        // bytes do not move the buffer and are not progress.
        var midTrack = ItemLoadProgress()
        XCTAssertEqual(midTrack.readings(for: snapshot(loaded: 8.02, bytes: 6_390, events: 1, errors: 0)), [8.02, 6_390])
        XCTAssertEqual(midTrack.readings(for: snapshot(loaded: 8.02, bytes: 34_325, events: 2, errors: 1)), [8.02, 6_390])
        XCTAssertEqual(midTrack.readings(for: snapshot(loaded: 8.02, bytes: 97_947, events: 3, errors: 2)), [8.02, 6_390])
        XCTAssertEqual(midTrack.readings(for: snapshot(loaded: 8.02, bytes: 97_947, events: 3, errors: 7)), [8.02, 6_390])
        // An error entry alone (bytes posted on the variant's open event, no new event) pauses too.
        var afterError = ItemLoadProgress()
        _ = afterError.readings(for: snapshot(loaded: 29.35, bytes: 50_752, events: 1, errors: 0))
        XCTAssertEqual(afterError.readings(for: snapshot(loaded: 29.35, bytes: 50_752, events: 1, errors: 1)), [29.35, 50_752])
        XCTAssertEqual(afterError.readings(for: snapshot(loaded: 29.35, bytes: 53_752, events: 1, errors: 1)), [29.35, 50_752])
        // A new event alone (a switch the error log did not record) pauses too.
        var afterSwitch = ItemLoadProgress()
        _ = afterSwitch.readings(for: snapshot(loaded: 8, bytes: 20_000, events: 1, errors: 0))
        XCTAssertEqual(afterSwitch.readings(for: snapshot(loaded: 8, bytes: 23_000, events: 2, errors: 0)), [8, 20_000])
        // Media of a time not buffered before is new: it counts and resumes the byte count.
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 4, bytes: 3_000, events: 1, errors: 2)), [4, 0])
        XCTAssertEqual(progress.byteCounting, .counting)
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 4, bytes: 14_000, events: 1, errors: 2)), [4, 11_000])
    }

    func testABufferDipAndRefillAtASwitchIsNotProgress() {
        // Encrypted CMAF mid-track (the simulator, every rendition failing its third segment):
        // at the second switch the buffer reads 0 for one poll, then 12 s again: the media
        // already buffered, not new media. The refill must neither count nor resume the bytes.
        var progress = ItemLoadProgress()
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 12, bytes: 147_440, events: 1, errors: 0)), [12, 147_440])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 12, bytes: 438_560, events: 2, errors: 1)), [12, 147_440])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 0, bytes: 536_448, events: 3, errors: 2)), [12, 147_440])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 12, bytes: 536_448, events: 3, errors: 2)), [12, 147_440])
        XCTAssertEqual(progress.byteCounting, .pausedUntilMedia)
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 12, bytes: 600_000, events: 3, errors: 2)), [12, 147_440])
    }

    /// The measured CMAF mid-track sequence (`fmp4~fail.all.503.3000~from.2`), each reading held
    /// until the next measured change: buffered 12 s from 0.5 s, a switch with segments
    /// downloaded again at 9.5 s, a second at 12.54 s with the buffer at 0 for one poll, refilled
    /// at 12.75 s, then failures only.
    private func cmafMidTrackFailure(at time: TimeInterval) -> ItemLoadSnapshot {
        let measured: [(at: Double, loaded: Double, bytes: Double, events: Int, errors: Int)] = [
            (0, 0, 0, 0, 0), (0.5, 12, 147_440, 1, 0), (9.5, 12, 438_560, 2, 1),
            (12.54, 0, 536_448, 3, 2), (12.75, 12, 536_448, 3, 2), (15.75, 12, 536_448, 3, 3),
            (18.76, 12, 536_448, 3, 6),
        ]
        let reading = measured.last { $0.at <= time + 1e-9 } ?? measured[0]
        return snapshot(loaded: reading.loaded, bytes: reading.bytes, events: reading.events, errors: reading.errors)
    }

    func testAWaitThroughABufferDipGivesUpOneStallTimeoutAfterItStarted() {
        // A seek or play-start wait started at several moments of that sequence, some of whose
        // polls fall inside the dip (12.55 s): nothing after its first reading is new media, so
        // each gives up one stall timeout after it started.
        for (startsAt, stallMs) in [(1.05, 10_000), (3.1, 10_000), (6.05, 10_000), (9.05, 10_000), (1.05, 15_000)] {
            let clock = ManualWaitClock()
            clock.now = startsAt
            var verdicts: [StallVerdict] = []
            let reader = ItemLoadReader { [unowned self] (time: TimeInterval) in self.cmafMidTrackFailure(at: time) }
            let driver = makeDriver(clock, stallMs: stallMs, totalMs: 60_000, readings: { reader.readings(clock.now) }, gaveUp: { verdicts.append($0) })
            driver.start()
            clock.runUntilIdle()
            XCTAssertEqual(verdicts, [.stalled], "start \(startsAt)")
            XCTAssertEqual(clock.now, startsAt + Double(stallMs) / 1000, accuracy: 0.001, "start \(startsAt), stall \(stallMs)")
        }
    }

    func testMediaInTheSameReadingAsASwitchCountsButDoesNotResumeTheBytes() {
        // A healthy fallback (the simulator: r0's segment answers 503, r1 and r2 serve theirs):
        // the error lands one poll before the switch, whose reading brings three access-log
        // events at once (a switch, though the log had none), new media and the bytes posted with
        // the switch. The media is progress; the bytes wait for a later reading.
        var progress = ItemLoadProgress()
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 0, bytes: 0, events: 0, errors: 0)), [0, 0])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 0, bytes: 0, events: 0, errors: 1)), [0, 0])
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 7.99, bytes: 79_220, events: 3, errors: 1)), [7.99, 0])
        XCTAssertEqual(progress.byteCounting, .pausedUntilMedia)
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 11.93, bytes: 166_921, events: 3, errors: 1)), [11.93, 87_701])
        XCTAssertEqual(progress.byteCounting, .counting)
    }

    func testAFirstAccessLogEventThatComesWithASwitchDoesNotCount() {
        // Packed AAC whose segments fail part way: the first access-log event appears only at
        // the switch, with the left rendition's late bytes. The pause then rests on the error
        // log: as measured, its entry lands before the event (each retry adds one) or in the same
        // poll (partial bytes, then a hung connection).
        var retried = ItemLoadProgress()
        _ = retried.readings(for: snapshot(loaded: 3.67, bytes: 0, events: 0, errors: 0))
        XCTAssertEqual(retried.readings(for: snapshot(loaded: 3.67, bytes: 0, events: 0, errors: 4)), [3.67, 0])
        XCTAssertEqual(retried.readings(for: snapshot(loaded: 1.06, bytes: 3_000, events: 1, errors: 5)), [3.67, 0])
        var hung = ItemLoadProgress()
        _ = hung.readings(for: snapshot(loaded: 3.67, bytes: 0, events: 0, errors: 0))
        XCTAssertEqual(hung.readings(for: snapshot(loaded: 1.06, bytes: 3_000, events: 1, errors: 1)), [3.67, 0])
        XCTAssertEqual(hung.byteCounting, .pausedUntilMedia)
    }

    func testASeekTheWaitIssuedIsNotASwitch() {
        // A seek past the buffer (the simulator, CMAF): the buffer moves to the target's
        // segments and a new access-log event opens. If the next segment's bytes then grow in
        // flight while the buffer does not (as measured on a CMAF load; not seen after a seek),
        // they must count: the wait noted its seek, so that event is the seek's, not a switch.
        var seek = ItemLoadProgress()
        XCTAssertEqual(seek.readings(for: snapshot(ranges: [0...12], bytes: 147_440, events: 1, errors: 0)), [12, 147_440])
        seek.noteSeek()
        XCTAssertEqual(seek.readings(for: snapshot(ranges: [24...36], bytes: 294_336, events: 2, errors: 0)), [24, 294_336])
        XCTAssertEqual(seek.readings(for: snapshot(ranges: [24...36], bytes: 310_000, events: 2, errors: 0)), [24, 310_000])
        XCTAssertEqual(seek.byteCounting, .counting)
        // The seek's event is matched: a later event is a switch again.
        XCTAssertEqual(seek.readings(for: snapshot(ranges: [24...36], bytes: 320_000, events: 3, errors: 0)), [24, 310_000])
        XCTAssertEqual(seek.byteCounting, .pausedUntilMedia)
        // Its first reading may come after the event: then the event is part of the baseline,
        // and the seek noted stays unmatched (a later lone event is taken for the seek's).
        var late = ItemLoadProgress()
        late.noteSeek()
        XCTAssertEqual(late.readings(for: snapshot(ranges: [24...36], bytes: 294_336, events: 2, errors: 0)), [12, 294_336])
        XCTAssertEqual(late.readings(for: snapshot(ranges: [24...36], bytes: 310_000, events: 2, errors: 0)), [12, 310_000])
        // A seek back to a time not buffered in this wait adds its seconds to the time seen.
        late.noteSeek()
        XCTAssertEqual(late.readings(for: snapshot(ranges: [0...12], bytes: 320_000, events: 3, errors: 0)), [24, 320_000])
        // A seek the wait did not issue (an event with no error) is a switch: bytes wait for new
        // buffered time, which the moved buffer brings at once.
        var unnoted = ItemLoadProgress()
        _ = unnoted.readings(for: snapshot(ranges: [0...12], bytes: 147_440, events: 1, errors: 0))
        XCTAssertEqual(unnoted.readings(for: snapshot(ranges: [24...36], bytes: 294_336, events: 2, errors: 0)), [24, 147_440])
        XCTAssertEqual(unnoted.byteCounting, .pausedUntilMedia)
        // Two events with one seek noted: one is a switch.
        var both = ItemLoadProgress()
        _ = both.readings(for: snapshot(ranges: [0...12], bytes: 147_440, events: 1, errors: 0))
        both.noteSeek()
        XCTAssertEqual(both.readings(for: snapshot(ranges: [0...12], bytes: 200_000, events: 3, errors: 0)), [12, 147_440])
        XCTAssertEqual(both.byteCounting, .pausedUntilMedia)
    }

    func testItemLoadProgressCountsPostedBytesWithoutAnErrorOrASwitch() {
        // An encrypted CMAF track (AES-128 fMP4, as the app's) behind slow playlists: the first
        // access-log event opens with the first segment request and its bytes grow in flight,
        // ahead of the buffer. That first event is the first variant's, not a switch.
        var first = ItemLoadProgress()
        XCTAssertEqual(first.readings(for: snapshot(loaded: 0, bytes: 0, events: 0, errors: 0)), [0, 0])
        XCTAssertEqual(first.readings(for: snapshot(loaded: 0, bytes: 8_768, events: 1, errors: 0)), [0, 8_768])
        XCTAssertEqual(first.byteCounting, .counting)
        XCTAssertEqual(first.readings(for: snapshot(loaded: 0, bytes: 16_768, events: 1, errors: 0)), [0, 16_768])
        // A healthy load: the buffer grows while a segment arrives, its bytes are posted when it
        // completes; both are progress. The first reading of a wait is its baseline, so a seek
        // wait on an item whose logs already hold entries starts counting.
        var progress = ItemLoadProgress()
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 14.68, bytes: 11_410, events: 1, errors: 3)), [14.68, 11_410])
        XCTAssertEqual(progress.byteCounting, .counting)
        XCTAssertEqual(progress.readings(for: snapshot(loaded: 14.68, bytes: 50_752, events: 1, errors: 3)), [14.68, 50_752])
    }

    func testEachWaitReadsItsOwnItemProgress() {
        // Two waits (one per engine, or a load then the next load): a switch during one pauses
        // only that one's byte count.
        let first = ItemLoadReader { (item: ItemLoadSnapshot) in item }
        let second = ItemLoadReader { (item: ItemLoadSnapshot) in item }
        let failing = [
            snapshot(loaded: 0, bytes: 0, events: 0, errors: 0),
            snapshot(loaded: 0, bytes: 3_000, events: 1, errors: 1),
        ]
        let healthy = [
            snapshot(loaded: 4, bytes: 10_000, events: 1, errors: 0),
            snapshot(loaded: 4, bytes: 20_000, events: 1, errors: 0),
        ]
        XCTAssertEqual(first.readings(failing[0]), [0, 0])
        XCTAssertEqual(second.readings(healthy[0]), [4, 10_000])
        XCTAssertEqual(first.readings(failing[1]), [0, 0])
        XCTAssertEqual(second.readings(healthy[1]), [4, 20_000])
        // A new wait on the same item starts counting, whatever an earlier wait saw.
        let next = ItemLoadReader { (item: ItemLoadSnapshot) in item }
        XCTAssertEqual(next.readings(failing[1]), [0, 3_000])
        XCTAssertEqual(next.readings(snapshot(loaded: 0, bytes: 6_000, events: 1, errors: 1)), [0, 6_000])
    }

    /// An item whose segments fail part way on every rendition (the measured sequence, scaled):
    /// a little media is buffered at 0.5 s; every `switchEverySeconds` a request fails and the
    /// player switches to the next rendition, which posts the left one's 3000 bytes late while
    /// the buffer drops to the new one's part. With `partial: false` the segments fail with no
    /// data (a 503): nothing is buffered or posted. With `mediaEverySeconds`, the last rendition
    /// then buffers a little more media at that interval (a slow but healthy fallback).
    private func failingRenditions(
        at time: TimeInterval,
        renditions: Int,
        switchEverySeconds: Double,
        mediaEverySeconds: Double? = nil,
        partial: Bool = true
    ) -> ItemLoadSnapshot {
        guard time >= 0.5 else { return snapshot(loaded: 0, bytes: 0, events: 0, errors: 0) }
        let switches = min(renditions - 1, Int((time - 0.5) / switchEverySeconds))
        var loaded = partial ? [3.67, 1.06, 0.6, 0.4, 0.3, 0.2][switches] : 0
        if let every = mediaEverySeconds, switches == renditions - 1 {
            let since = time - 0.5 - Double(switches) * switchEverySeconds
            loaded += 0.1 * Double(Int(since / every))
        }
        return snapshot(loaded: loaded, bytes: partial ? Double(switches) * 3_000 : 0, events: switches, errors: switches)
    }

    func testFailingSegmentsGiveUpAtTheStallTimeoutThoughThePlayerFallsBackToOtherRenditions() {
        // As Android's failingSegmentsGiveUpAtTheStallTimeoutThoughThePlayerFallsBackToOtherRenditions:
        // the player switches rendition within each stall timeout (at 0.8 of it), and each
        // switch posts late bytes. The load gives up one stall timeout after its last media
        // (0.5 s), not at the next switch's bytes and not at its total limit.
        let stallMs = 2_000
        let clock = ManualWaitClock()
        var verdicts: [StallVerdict] = []
        let reader = ItemLoadReader { [unowned self] (time: TimeInterval) in
            self.failingRenditions(at: time, renditions: 6, switchEverySeconds: Double(stallMs) * 0.8 / 1000)
        }
        let driver = makeDriver(clock, stallMs: stallMs, totalMs: 60_000, readings: { reader.readings(clock.now) }, gaveUp: { verdicts.append($0) })
        driver.start()
        clock.runUntilIdle()
        XCTAssertEqual(verdicts, [.stalled])
        XCTAssertEqual(clock.now, 0.5 + Double(stallMs) / 1000, accuracy: 0.26)
    }

    func testASlowButHealthyFallbackAfterFailedSegmentsKeepsLoading() {
        // Two renditions fail with a 503 (as measured, a healthy fallback buffers at once), then
        // the third buffers a little media every 0.5 s: the load goes on until its total limit,
        // as a slow but steady load.
        let clock = ManualWaitClock()
        var verdicts: [StallVerdict] = []
        let reader = ItemLoadReader { [unowned self] (time: TimeInterval) in
            self.failingRenditions(at: time, renditions: 3, switchEverySeconds: 0.4, mediaEverySeconds: 0.5, partial: false)
        }
        let driver = makeDriver(clock, stallMs: 2_000, totalMs: 20_000, readings: { reader.readings(clock.now) }, gaveUp: { verdicts.append($0) })
        driver.start()
        clock.runUntilIdle()
        XCTAssertEqual(verdicts, [.capExceeded])
        XCTAssertEqual(clock.now, 20, accuracy: 0.26)
    }

    func testARealPlayerWhoseSegmentsFailPartWayGivesUpAtTheStallTimeoutDespiteTheLateBytesOfItsSwitch() throws {
        // A real AVPlayer against a local HLS server whose segments all fail part way: 3000 bytes,
        // then the connection drops. The player retries, then switches rendition (about 16 s in
        // on the iOS 26.5 simulator) and only then posts the failed bytes in its access log. Those
        // bytes are not progress: the wait gives up one stall timeout after the first media (the
        // 3000 bytes, buffered in the first seconds), not one after the switch.
        let server = try PartialSegmentHLSServer()
        defer { server.stop() }
        let stallMs = 20_000
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 0
        let item = AVPlayerItem(url: server.masterURL)
        item.preferredForwardBufferDuration = 6
        let reader = ItemLoadReader(ItemLoadSnapshot.init(of:))
        var trace: [String] = []
        var previous: [Double]?
        var lastProgressAt: TimeInterval = 0
        var verdict: StallVerdict?
        var gaveUpAt: TimeInterval = 0
        let startedAt = ProcessInfo.processInfo.systemUptime
        // The times below are the wait's own clock readings: the one each check takes before it
        // reads the item, and the one of the check that gives up.
        var checkedAt = startedAt
        var lastProgressClock = startedAt
        var gaveUpClock = startedAt
        let gaveUp = expectation(description: "the wait gives up")
        let driver = StallWaitDriver(
            stallTimeoutMs: stallMs,
            totalTimeoutMs: 60_000,
            now: {
                checkedAt = ProcessInfo.processInfo.systemUptime
                return checkedAt
            },
            readings: {
                let readings = reader.readings(item)
                let at = checkedAt - startedAt
                if let previous = previous, zip(readings, previous).contains(where: { $0 > $1 }) {
                    lastProgressAt = at
                    lastProgressClock = checkedAt
                }
                previous = readings
                trace.append(String(format: "%.2f %@", at, readings.description))
                return readings
            },
            onGiveUp: { result, _ in
                verdict = result
                gaveUpAt = checkedAt - startedAt
                gaveUpClock = checkedAt
                gaveUp.fulfill()
            }
        )
        player.replaceCurrentItem(with: item)
        driver.start()
        wait(for: [gaveUp], timeout: 65)
        let posted = ItemLoadSnapshot(of: item).transferredBytes
        player.replaceCurrentItem(with: nil)
        let history = trace.suffix(12).joined(separator: " | ")
        XCTAssertEqual(verdict, .stalled, history)
        // The case under test happened: the player switched before the give-up and posted bytes.
        let switchedAt = server.firstRequestAt { $0.hasPrefix("/r1/") }.map { $0 - startedAt }
        XCTAssertNotNil(switchedAt, "requests: \(server.paths)")
        XCTAssertLessThan(switchedAt ?? .infinity, gaveUpAt, "requests: \(server.paths)")
        XCTAssertGreaterThan(posted, 0, history)
        // Nothing after the switch was progress; the give-up came one stall timeout after the
        // last progress, the first media: never sooner (both times are the wait's clock), and at
        // most one poll later, plus the main queue's delay, which one more poll covers.
        XCTAssertLessThan(lastProgressAt, switchedAt ?? 0, history)
        let checkSlackMs = 2 * stallCheckIntervalMs
        print(String(format: "real-player timing: lastProgressAt=%.3f switchedAt=%.3f gaveUpAt=%.3f afterLastProgress=%.3f",
                     lastProgressAt, switchedAt ?? -1, gaveUpAt, gaveUpAt - lastProgressAt))
        // The same arithmetic as StallWatch's verdict, on the same clock readings.
        XCTAssertGreaterThanOrEqual((gaveUpClock - lastProgressClock) * 1000, Double(stallMs), history)
        XCTAssertLessThanOrEqual((gaveUpClock - lastProgressClock) * 1000, Double(stallMs + checkSlackMs), history)
    }

    func testCrossfadeIncomingStallReadsTheGraceItIsGiven() {
        XCTAssertFalse(crossfadeIncomingStalled(elapsedMs: 1_999, graceMs: 2_000, incomingTime: 10, incomingStartTime: 10))
        XCTAssertTrue(crossfadeIncomingStalled(elapsedMs: 2_000, graceMs: 2_000, incomingTime: 10.2, incomingStartTime: 10))
        XCTAssertTrue(crossfadeIncomingStalled(elapsedMs: 500, graceMs: 500, incomingTime: 10, incomingStartTime: 10))
        XCTAssertFalse(crossfadeIncomingStalled(elapsedMs: 5_000, graceMs: 6_000, incomingTime: 10, incomingStartTime: 10))
        // The incoming track moved: no fallback, whatever the grace.
        XCTAssertFalse(crossfadeIncomingStalled(elapsedMs: 5_000, graceMs: 500, incomingTime: 10.3, incomingStartTime: 10))
    }

    // The interruption policy, run on the scenarios the Android tests run too.

    func testInterruptionPolicyFollowsTheSharedScenarios() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/interruption-scenarios.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        XCTAssertEqual(scenarios.count, 22)
        for scenario in scenarios {
            let id = scenario["id"] as? String ?? "?"
            let autoResume = scenario["autoResume"] as? Bool ?? false
            var playing = scenario["playing"] as? Bool ?? false
            // The backend's state: an ended queue does not count as playing (same rule as Android).
            let state = scenario["state"] as? String ?? "playing"
            func isPlaying() -> Bool { interruptionCountsAsPlaying(playWhenReady: playing, stateRawValue: state) }
            let policy = InterruptionPolicy(autoResume: { autoResume })
            for step in try XCTUnwrap(scenario["steps"] as? [[String: Any]]) {
                let event = step["event"] as? String ?? ""
                let result: (InterruptionAction, RemoteDuckPayload?)
                switch event {
                case "began": result = policy.began(isPlaying: isPlaying())
                case "ended": result = policy.ended(shouldResume: step["shouldResume"] as? Bool ?? false)
                case "lostPermanently": result = policy.lostPermanently(isPlaying: isPlaying())
                case "noisy": result = policy.noisy(isPlaying: isPlaying())
                case "userPause": policy.userPause(); playing = false; result = (.none, nil)
                case "userStop": policy.userStop(); playing = false; result = (.none, nil)
                case "userPlay":
                    // The system's answer (iOS: the activation; Android: the focus request).
                    let granted = step["granted"] as? Bool ?? true
                    let decision = policy.userPlay(activate: { granted })
                    XCTAssertEqual(decision == .refused, step["action"] as? String == "refused", "\(id) userPlay")
                    if decision == .play { playing = true }
                    continue
                default: XCTFail("unknown event \(event) in \(id)"); continue
                }
                let expectedAction: InterruptionAction
                switch step["action"] as? String {
                case "pause": expectedAction = .pause
                case "resume": expectedAction = .resume
                default: expectedAction = .none
                }
                XCTAssertEqual(result.0, expectedAction, "\(id) \(event)")
                let duck = step["duck"] as? [String: Bool]
                XCTAssertEqual(result.1, duck.map { RemoteDuckPayload(paused: $0["paused"] ?? false, permanent: $0["permanent"] ?? false) }, "\(id) \(event)")
                if result.0 == .pause { playing = false }
                if result.0 == .resume { playing = true }
            }
        }
    }

    func testAnInterruptionResumesWhenTheSDKPausedThePlayerBeforeItWasRead() {
        // The module asked to play; the system pauses the player for a call and SwiftAudioEx
        // turns its own playWhenReady off before the module reads it.
        var requested = RequestedPlayback()
        requested.request(true)
        let sdkPlayWhenReady = false
        let policy = InterruptionPolicy(autoResume: { true })
        XCTAssertEqual(policy.began(isPlaying: interruptionCountsAsPlaying(playWhenReady: requested.playWhenReady, stateRawValue: "paused")).0, .pause)
        XCTAssertEqual(policy.ended(shouldResume: true).0, .resume)
        // The SDK's value would have lost the resume.
        let fromSDK = InterruptionPolicy(autoResume: { true })
        _ = fromSDK.began(isPlaying: sdkPlayWhenReady)
        XCTAssertEqual(fromSDK.ended(shouldResume: true).0, .none)
        requested.request(false)
        XCTAssertFalse(requested.playWhenReady)
    }

    func testOnlyAnActiveTrackThatWasAskedToPlayCountsAsPlaying() {
        XCTAssertEqual(interruptionFinishedStates, ["none", "ended", "error", "stopped"])
        for state in ["none", "ready", "playing", "paused", "stopped", "buffering", "loading", "error", "ended"] {
            XCTAssertEqual(interruptionCountsAsPlaying(playWhenReady: true, stateRawValue: state),
                           !["none", "ended", "error", "stopped"].contains(state), state)
            XCTAssertFalse(interruptionCountsAsPlaying(playWhenReady: false, stateRawValue: state), state)
        }
    }

    func testANativeSeekCallbackResolvesOnlyTheSeekItCompletes() {
        final class Seek {}
        var ledger = NativeSeekLedger<Seek>()
        // A, then B replaces it, then A again replaces B: AVPlayer calls all three back in order.
        let first = Seek(), second = Seek(), third = Seek()
        ledger.issued(first, at: 10)
        ledger.release(first)
        ledger.issued(second, at: 20)
        ledger.release(second)
        ledger.issued(third, at: 10)
        XCTAssertNil(ledger.completed(at: 10), "the first A's callback must not resolve the last A")
        XCTAssertNil(ledger.completed(at: 20))
        XCTAssertTrue(ledger.completed(at: 10) === third)
        // A callback for a seek the backend did not issue (the SDK's own) matches nothing.
        XCTAssertNil(ledger.completed(at: 30))
        // The same target issued again after a replaced one: only the new one resolves.
        let again = Seek(), latest = Seek()
        ledger.issued(again, at: 5)
        ledger.release(again)
        ledger.issued(latest, at: 5)
        XCTAssertNil(ledger.completed(at: 5))
        XCTAssertTrue(ledger.completed(at: 5) === latest)
    }

    func testAPlayIsDecidedFromTheActivationAlone() {
        // The module's rule (decision B): the play starts when the session activates, also after
        // an interruption that began and never ended.
        let policy = InterruptionPolicy(autoResume: { true })
        _ = policy.began(isPlaying: true)
        var activations = 0
        XCTAssertEqual(policy.userPlay(activate: { activations += 1; return false }), .refused)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(policy.userPlay(activate: { activations += 1; return true }), .play)
        XCTAssertEqual(activations, 2)
        // The allowed play ended that interruption: a later refused play arms no resume.
        XCTAssertEqual(policy.userPlay(activate: { false }), .refused)
        XCTAssertEqual(policy.ended(shouldResume: true).0, .none)
        XCTAssertEqual(audioFocusRefusedCode, "audio_focus_refused")
        XCTAssertEqual((audioFocusRefusedError() as NSError).userInfo["code"] as? String, "audio_focus_refused")
    }

    func testAResumeNeedsTheSessionAndNothingElseActivatesIt() {
        let policy = InterruptionPolicy(autoResume: { true })
        var activations = 0
        XCTAssertEqual(policy.step(for: .none, activate: { activations += 1; return true }), .none)
        XCTAssertEqual(policy.step(for: .pause, activate: { activations += 1; return true }), .pause)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(policy.step(for: .resume, activate: { activations += 1; return true }), .resume)
        XCTAssertEqual(policy.step(for: .resume, activate: { activations += 1; return false }), .resumeRefused)
        XCTAssertEqual(activations, 2)
    }

    func testOnlyACommandIssuedWhileAskedToPlayWithNothingPlayingStartsTheAudio() {
        for state in ["none", "ready", "playing", "paused", "stopped", "buffering", "loading", "error", "ended"] {
            XCTAssertEqual(commandStartsPlayback(playWhenReady: true, stateRawValue: state),
                           ["none", "ended", "error", "stopped"].contains(state), state)
            XCTAssertFalse(commandStartsPlayback(playWhenReady: false, stateRawValue: state), state)
        }
        // Refused, the command ran paused: it fails with audio_focus_refused, unless it failed
        // by itself.
        let ok: Result<Int, Error> = .success(3)
        XCTAssertEqual(try applyingPlayRefusal(refused: false, to: ok).get(), 3)
        guard case .failure(let refusal) = applyingPlayRefusal(refused: true, to: ok) else { return XCTFail("not refused") }
        XCTAssertEqual((refusal as NSError).userInfo["code"] as? String, audioFocusRefusedCode)
        let own = NSError(domain: "test", code: 1)
        guard case .failure(let kept) = applyingPlayRefusal(refused: true, to: Result<Int, Error>.failure(own)) else { return XCTFail("succeeded") }
        XCTAssertTrue((kept as NSError) === own)
    }

    func testInterruptionPolicyReadsTheOptionAtTheEnd() {
        var autoResume = false
        let policy = InterruptionPolicy(autoResume: { autoResume })
        _ = policy.began(isPlaying: true)
        autoResume = true
        XCTAssertEqual(policy.ended(shouldResume: true).0, .resume)
    }

    private let snapshot = PlaybackBackendSnapshot(
        queueIDs: ["first", "second"],
        activeIndex: 1,
        activeTrackID: "second",
        position: 12.345,
        playWhenReady: true,
        volume: 0.7,
        rate: 1.25,
        repeatMode: 2,
        transitionGeneration: 9
    )

    func test_pausedSwapPreservesSnapshot() {
        let paused = snapshot.with(playWhenReady: false)
        let old = FakeBackend(kind: .standard, snapshot: paused)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let queuedCommandFinished = expectation(description: "main command queued during restore")
        var queuedCommandBackend: PlaybackBackendKind?
        let hookLock = NSLock()
        var didQueueCommand = false
        factory.prepareHook = {
            hookLock.lock()
            let shouldQueueCommand = !didQueueCommand
            didQueueCommand = true
            hookLock.unlock()
            guard shouldQueueCommand else { return }
            XCTAssertTrue(facade.currentBackend === old)
            XCTAssertTrue(authority.isAuthoritative(.standard, identity: old))
            let commandEntered = DispatchSemaphore(value: 0)
            facade.withCurrentBackendAsync({ backend, completion in
                queuedCommandBackend = backend.kind
                backend.pause()
                commandEntered.signal()
                completion(.success(backend.kind))
            }) { _ in
                queuedCommandFinished.fulfill()
            }
            XCTAssertEqual(
                commandEntered.wait(timeout: .now() + 0.05),
                .success,
                "pause must route to the old owner while candidate restore is running"
            )
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }
        wait(for: [queuedCommandFinished], timeout: 1)
        guard let replacement = factory.created.last else {
            XCTFail("replacement backend was not created")
            return
        }

        XCTAssertEqual(replacement.restoredSnapshot, paused)
        XCTAssertEqual(replacement.committedQueue, paused.queueIDs)
        XCTAssertFalse(replacement.audible)
        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(try? result.get().operationID, 1)
        XCTAssertEqual(queuedCommandBackend, .standard)

        let generationSidecar = PlaybackTransitionGenerationSidecar()
        generationSidecar.restore(paused.transitionGeneration)
        let standardGeneration = generationSidecar.current
        generationSidecar.restore(standardGeneration)
        XCTAssertEqual(generationSidecar.observe(0), paused.transitionGeneration)
    }

    func test_playingSwapKeepsOneAudibleOwner() {
        let registry = AudibleRegistry()
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true, registry: registry)
        registry.backends.append(old)
        let factory = FakeFactory(registry: registry)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        _ = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertTrue(factory.created.first?.audible == true)
        XCTAssertFalse(old.audible)
        XCTAssertTrue(registry.counts.allSatisfy { $0 <= 1 })
    }

    func test_activeCrossfadeIsSettledBeforeSnapshot() {
        let old = FakeBackend(kind: .pingPong, snapshot: snapshot)
        let facade = PlaybackBackendFacade(initial: old, factory: FakeFactory())

        _ = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        let settleIndex = old.calls.firstIndex(of: "settle")
        let snapshotIndex = old.calls.firstIndex(of: "snapshot")
        XCTAssertNotNil(settleIndex)
        XCTAssertNotNil(snapshotIndex)
        if let settleIndex = settleIndex, let snapshotIndex = snapshotIndex {
            XCTAssertLessThan(settleIndex, snapshotIndex)
        }
        XCTAssertEqual(old.calls.filter { $0 == "settle" }.count, 1)
    }

    func test_prepareFailureRejectsAndKeepsOldBackend() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory(failPrepare: true)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(old.audible)
        XCTAssertTrue(factory.created.first?.disposed == true)
    }

    func test_restoreFailureRejectsAndKeepsOldBackend() {
        let first = NSObject()
        let second = NSObject()
        let shared = SharedPlaybackResource(queue: [first, second])
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: snapshot,
            audible: true,
            sharedResource: shared,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory(
            failRestore: true,
            sharedResource: shared
        )
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(old.audible)
        XCTAssertTrue(factory.created.first?.disposed == true)
        XCTAssertEqual(shared.queue.count, 2)
        XCTAssertTrue(shared.queue[0] === first)
        XCTAssertTrue(shared.queue[1] === second)
    }

    func test_postCommitDisposeFailureResolvesAndEmitsCleanupDiagnostic() {
        var diagnostics: [PlaybackBackendCleanupDiagnostic] = []
        let diagnosticReceived = expectation(description: "cleanup diagnostic received")
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true, failDispose: true)
        let facade = PlaybackBackendFacade(
            initial: old,
            factory: FakeFactory(),
            onCleanupDiagnostic: {
                diagnostics.append($0)
                diagnosticReceived.fulfill()
            }
        )

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        wait(for: [diagnosticReceived], timeout: 1)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.code, "playback_backend_cleanup_failed")
        XCTAssertFalse(diagnostics.first?.message.contains("secret") == true)
    }

    func test_postCommitDiagnosticObserverCannotBlockCommittedResult() {
        let observerEntered = DispatchSemaphore(value: 0)
        let releaseObserver = DispatchSemaphore(value: 0)
        let observerFinished = expectation(description: "cleanup observer finished")
        let transactionFinished = expectation(description: "transaction finished")
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true, failDispose: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(
            initial: old,
            factory: factory,
            onCleanupDiagnostic: { _ in
                observerEntered.signal()
                releaseObserver.wait()
                observerFinished.fulfill()
            }
        )
        var result: Result<PlaybackBackendTransactionResult, Error>?

        facade.setPlaybackBackend(.pingPong) {
            result = $0
            transactionFinished.fulfill()
        }

        let observerStatus = observerEntered.wait(timeout: .now() + 1)
        let transactionStatus = XCTWaiter.wait(for: [transactionFinished], timeout: 0.2)
        releaseObserver.signal()
        wait(for: [observerFinished], timeout: 1)

        XCTAssertEqual(observerStatus, .success)
        XCTAssertEqual(transactionStatus, .completed)
        XCTAssertEqual(try? result?.get().backend, .pingPong)
        XCTAssertTrue(facade.currentBackend === factory.created.first)
    }

    func test_commitQueueRunsBeforeFacadePointerAndAuthorityPublication() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        var facadeBackendAtCommit: PlaybackBackend?
        var authorityWasOldAtCommit = false
        factory.commitHook = {
            facadeBackendAtCommit = facade.currentBackend
            authorityWasOldAtCommit = authority.isAuthoritative(.standard, identity: old)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertTrue(facadeBackendAtCommit === old)
        XCTAssertTrue(authorityWasOldAtCommit)
        XCTAssertTrue(facade.currentBackend === factory.created.first)
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: factory.created.first!))
    }

    func test_concurrentCallsCommitInSerializedOrder() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot)
        let barrier = TransactionBarrier()
        let factory = FakeFactory(barrier: barrier)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var operationIDs: [Int] = []

        facade.setPlaybackBackend(.pingPong) { result in
            operationIDs.append((try? result.get().operationID) ?? -1)
            first.fulfill()
        }
        XCTAssertEqual(barrier.firstPrepareEntered.wait(timeout: .now() + 1), .success)
        facade.setPlaybackBackend(.standard) { result in
            operationIDs.append((try? result.get().operationID) ?? -1)
            second.fulfill()
        }
        barrier.releaseFirstPrepare.signal()

        wait(for: [first, second], timeout: 2)
        XCTAssertEqual(operationIDs, [1, 2])
        XCTAssertEqual(facade.currentBackend.kind, .standard)
        XCTAssertEqual(factory.requested, [.pingPong, .standard])
        XCTAssertEqual(barrier.maxInFlight, 1)
        XCTAssertEqual(barrier.trace, [
            "enter:pingPong", "exit:pingPong",
            "enter:pingPong", "exit:pingPong",
            "enter:standard", "exit:standard",
            "enter:standard", "exit:standard"
        ])

        let transitionFinished = expectation(description: "long transition finished")
        let pauseFinished = expectation(description: "interruptive pause finished")
        let transitionStarted = DispatchSemaphore(value: 0)
        var deferredCompletion: ((Result<Void, Error>) -> Void)?
        var transitionResult: Result<Void, Error>?
        facade.withCurrentBackendAsync(timeout: 0.5, { _, completion in
            deferredCompletion = completion
            transitionStarted.signal()
        }) { (result: Result<Void, Error>) in
            transitionResult = result
            transitionFinished.fulfill()
        }
        XCTAssertEqual(transitionStarted.wait(timeout: .now() + 1), .success)

        facade.withCurrentBackendAsync({ backend, completion in
            backend.pause()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in
            pauseFinished.fulfill()
        }

        XCTAssertEqual(
            XCTWaiter.wait(for: [pauseFinished], timeout: 0.05),
            .completed,
            "pause must not wait for a long asynchronous transition"
        )
        deferredCompletion?(.success(()))
        wait(for: [transitionFinished], timeout: 1)
        XCTAssertNoThrow(try transitionResult?.get())
    }

    func test_swapSettlesLeaseAndWaitsForItsActualCompletionBeforeSnapshot() {
        let old = FakeBackend(kind: .pingPong, snapshot: snapshot, audible: true)
        let facade = PlaybackBackendFacade(initial: old, factory: FakeFactory())
        let transitionStarted = DispatchSemaphore(value: 0)
        let transitionFinished = expectation(description: "transition lease released")
        var deferredCompletion: ((Result<Void, Error>) -> Void)?
        var transitionCompletionCount = 0

        facade.withCurrentBackendAsync({ _, completion in
            deferredCompletion = completion
            transitionStarted.signal()
        }) { (_: Result<Void, Error>) in
            transitionCompletionCount += 1
            transitionFinished.fulfill()
        }
        XCTAssertEqual(transitionStarted.wait(timeout: .now() + 1), .success)
        old.settleHook = {
            deferredCompletion?(.failure(FakeError.cancelled))
        }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }
        wait(for: [transitionFinished], timeout: 1)

        XCTAssertEqual(try? result.get().backend, .standard)
        XCTAssertEqual(transitionCompletionCount, 1)
        XCTAssertLessThan(old.calls.firstIndex(of: "settle")!, old.calls.firstIndex(of: "snapshot")!)
        let disposalDeadline = Date().addingTimeInterval(1)
        while !old.disposed, Date() < disposalDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(old.disposed)
    }

    func test_nativeCommandCompletionIsResolvedExactlyOnce() {
        var results: [Result<Void, Error>] = []
        let completion = PlaybackBackendCommandCompletion<Void> { results.append($0) }

        completion.resolve(.failure(FakeError.cancelled))
        completion.resolve(.success(()))

        XCTAssertEqual(results.count, 1)
        XCTAssertThrowsError(try results[0].get())
    }

    func test_commandDuringCandidateRestoreRepreparesFromFreshSnapshot() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let pauseEntered = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var didPause = false

        factory.restoreHook = {
            hookLock.lock()
            let shouldPause = !didPause
            didPause = true
            hookLock.unlock()
            guard shouldPause else { return }

            facade.withCurrentBackendAsync({ backend, completion in
                backend.pause()
                pauseEntered.signal()
                completion(.success(()))
            }) { (_: Result<Void, Error>) in }
            XCTAssertEqual(pauseEntered.wait(timeout: .now() + 0.05), .success)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(factory.created.count, 2, "a stale candidate must be discarded and prepared again")
        XCTAssertEqual(factory.created.first?.restoredSnapshot?.playWhenReady, true)
        XCTAssertTrue(factory.created.first?.disposed == true)
        XCTAssertEqual(factory.created.last?.restoredSnapshot?.playWhenReady, false)
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: factory.created.last!))
    }

    func test_naturalPositionDriftDuringPreparationCommitsQuiescedSnapshot() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let advanced = snapshot.with(position: 27)
        var didAdvance = false
        factory.prepareHook = {
            guard !didAdvance else { return }
            didAdvance = true
            old.simulateNaturalSnapshot(advanced)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, advanced)
        XCTAssertEqual(factory.created.first?.restoredSnapshots, [snapshot, advanced])
        XCTAssertTrue(old.calls.contains("beginHandoffQuiescence"))
        XCTAssertFalse(old.calls.contains("stopAndMute"))
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: factory.created.first!))
    }

    func test_naturalTrackAdvanceDuringPreparationDoesNotResurrectOldTrack() {
        let initial = PlaybackBackendSnapshot(
            queueIDs: ["first", "second"],
            activeIndex: 0,
            activeTrackID: "first",
            position: 28,
            playWhenReady: true,
            volume: 0.7,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 4
        )
        let advanced = PlaybackBackendSnapshot(
            queueIDs: initial.queueIDs,
            activeIndex: 1,
            activeTrackID: "second",
            position: 0.321,
            playWhenReady: true,
            volume: initial.volume,
            rate: initial.rate,
            repeatMode: initial.repeatMode,
            transitionGeneration: initial.transitionGeneration
        )
        let old = FakeBackend(kind: .standard, snapshot: initial, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        var didAdvance = false
        factory.prepareHook = {
            guard !didAdvance else { return }
            didAdvance = true
            old.simulateNaturalSnapshot(advanced)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, advanced)
        XCTAssertEqual(factory.created.first?.restoredSnapshots.last, advanced)
        XCTAssertEqual(factory.created.first?.restoredSnapshot?.activeTrackID, "second")
        XCTAssertTrue(old.calls.contains("beginHandoffQuiescence"))
    }

    func test_queueObjectsAndIDsMutatedDuringWarmupAreRebasedBeforeCommit() {
        let oldObject = NSObject()
        let freshFirst = NSObject()
        let freshSecond = NSObject()
        let shared = SharedPlaybackResource(queue: [oldObject])
        let initial = PlaybackBackendSnapshot(
            queueIDs: ["old"],
            activeIndex: 0,
            activeTrackID: "old",
            position: 12,
            playWhenReady: true,
            volume: 0.6,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 2
        )
        let fresh = PlaybackBackendSnapshot(
            queueIDs: ["fresh-first", "fresh-second"],
            activeIndex: 1,
            activeTrackID: "fresh-second",
            position: 0.4,
            playWhenReady: true,
            volume: 0.6,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 3
        )
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: initial,
            audible: true,
            sharedResource: shared,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory(sharedResource: shared)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        var didMutate = false
        factory.prepareHook = {
            guard !didMutate else { return }
            didMutate = true
            shared.queue = [freshFirst, freshSecond]
            old.simulateNaturalSnapshot(fresh)
        }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, fresh)
        let candidate = factory.created.first!
        XCTAssertEqual(candidate.preparedSnapshots, [initial, fresh])
        XCTAssertEqual(candidate.committedQueue, fresh.queueIDs)
        XCTAssertEqual(candidate.preparedSharedQueues.first?.count, 1)
        XCTAssertTrue(candidate.preparedSharedQueues.first?.first === oldObject)
        XCTAssertEqual(candidate.preparedSharedQueues.last?.count, 2)
        XCTAssertTrue(candidate.preparedSharedQueues.last?[0] === freshFirst)
        XCTAssertTrue(candidate.preparedSharedQueues.last?[1] === freshSecond)
    }

    func test_standardCandidateAcceptsIdleNonemptyQueueWithoutActiveIndex() {
        let idle = PlaybackBackendSnapshot(
            queueIDs: ["queued"],
            activeIndex: nil,
            activeTrackID: nil,
            position: 0,
            playWhenReady: false,
            volume: 0.8,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 9
        )
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: idle,
            audible: false,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        factory.activationHook = { _ in
            try validateStandardPlaybackActivationSnapshot(idle, queueCount: 1)
        }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertEqual(try? result.get().snapshot, idle)
        XCTAssertEqual(factory.created.first?.restoredSnapshot, idle)
        XCTAssertEqual(factory.created.first?.committedQueue, ["queued"])
        XCTAssertFalse(factory.created.first?.audible == true)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: factory.created.first!))
    }

    func test_standardActivationValidatorRejectsMissingOrMismatchedActiveTrackIdentity() {
        let missingIdentity = PlaybackBackendSnapshot(
            queueIDs: ["expected"],
            activeIndex: 0,
            activeTrackID: nil,
            position: 0,
            playWhenReady: false,
            volume: 1,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 0
        )
        let mismatchedIdentity = PlaybackBackendSnapshot(
            queueIDs: ["expected"],
            activeIndex: 0,
            activeTrackID: "different",
            position: 0,
            playWhenReady: false,
            volume: 1,
            rate: 1,
            repeatMode: 0,
            transitionGeneration: 0
        )

        XCTAssertThrowsError(
            try validateStandardPlaybackActivationSnapshot(missingIdentity, queueCount: 1)
        )
        XCTAssertThrowsError(
            try validateStandardPlaybackActivationSnapshot(mismatchedIdentity, queueCount: 1)
        )
    }

    func test_finalRebaseFailureResumesOldBeforeQueuedCommandRuns() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap rejected")
        let commandFinished = DispatchSemaphore(value: 0)
        var swapResult: Result<PlaybackBackendTransactionResult, Error>?
        var commandBackend: PlaybackBackend?
        var oldWasAudibleWhenCommandStarted = false
        var oldControlWasActiveDuringFinalRebase = false
        var oldControlWasActiveWhenCommandStarted = false
        factory.activationHook = { call in
            guard call == 2 else { return }
            oldControlWasActiveDuringFinalRebase = old.controlSurfaceActive
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
            throw FakeError.restore
        }

        facade.setPlaybackBackend(.pingPong) {
            swapResult = $0
            swapFinished.fulfill()
        }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendAsync({ backend, completion in
            commandBackend = backend
            oldWasAudibleWhenCommandStarted = old.audible
            oldControlWasActiveWhenCommandStarted = old.controlSurfaceActive
            backend.pause()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in
            commandFinished.signal()
        }
        XCTAssertEqual(
            commandFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "admission must remain closed during the final rebase"
        )
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(commandFinished.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(try swapResult?.get())
        XCTAssertTrue(commandBackend === old)
        XCTAssertTrue(oldWasAudibleWhenCommandStarted)
        XCTAssertTrue(oldControlWasActiveDuringFinalRebase)
        XCTAssertTrue(oldControlWasActiveWhenCommandStarted)
        XCTAssertTrue(old.calls.contains("cancelHandoffQuiescence"))
        XCTAssertEqual(old.calls.filter { $0 == "resumeEventDeliveryAfterHandoff" }.count, 1)
        XCTAssertEqual(old.canonicalResumeCount, 1)
        XCTAssertLessThan(
            old.calls.firstIndex(of: "cancelHandoffQuiescence")!,
            old.calls.firstIndex(of: "pause")!
        )
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: old))
        XCTAssertFalse(factory.created.first?.calls.contains("commitQueue") == true)
    }

    func test_commandsStayBlockedDuringFinalRebaseAndRunOnCommittedReplacement() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap committed")
        let commandFinished = DispatchSemaphore(value: 0)
        var commandBackend: PlaybackBackend?
        var oldControlWasActiveDuringFinalRebase = false
        factory.activationHook = { call in
            guard call == 2 else { return }
            oldControlWasActiveDuringFinalRebase = old.controlSurfaceActive
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
        }

        facade.setPlaybackBackend(.pingPong) { _ in swapFinished.fulfill() }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendAsync({ backend, completion in
            commandBackend = backend
            backend.pause()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in
            commandFinished.signal()
        }
        XCTAssertEqual(commandFinished.wait(timeout: .now() + 0.05), .timedOut)
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(commandFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(commandBackend === factory.created.first)
        XCTAssertTrue(facade.currentBackend === factory.created.first)
        XCTAssertTrue(old.calls.contains("beginHandoffQuiescence"))
        XCTAssertTrue(oldControlWasActiveDuringFinalRebase)
    }

    func test_readDuringFinalHandoffWaitsAndRunsOnCommittedReplacement() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap committed")
        let readFinished = DispatchSemaphore(value: 0)
        var readBackend: PlaybackBackendKind?
        factory.activationHook = { call in
            guard call == 2 else { return }
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
        }

        facade.setPlaybackBackend(.pingPong) { _ in swapFinished.fulfill() }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendRead({ $0.kind }) { result in
            readBackend = try? result.get()
            readFinished.signal()
        }
        XCTAssertEqual(readFinished.wait(timeout: .now() + 0.05), .timedOut)
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(readBackend, .pingPong)
    }

    func test_readDoesNotInvalidateCandidatePreparationVersion() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let readFinished = DispatchSemaphore(value: 0)
        var didRead = false
        factory.prepareHook = {
            guard !didRead else { return }
            didRead = true
            facade.withCurrentBackendRead({ $0.kind }) { result in
                XCTAssertEqual(try? result.get(), .standard)
                readFinished.signal()
            }
            XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(factory.created.count, 1)
    }

    func test_readDuringFailedFinalHandoffWaitsAndRunsOnRolledBackBackend() {
        let old = FakeBackend(kind: .pingPong, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let finalRebaseEntered = DispatchSemaphore(value: 0)
        let releaseFinalRebase = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap rejected")
        let readFinished = DispatchSemaphore(value: 0)
        var readBackend: PlaybackBackendKind?
        factory.activationHook = { call in
            guard call == 2 else { return }
            finalRebaseEntered.signal()
            releaseFinalRebase.wait()
            throw FakeError.restore
        }

        facade.setPlaybackBackend(.standard) { _ in swapFinished.fulfill() }
        XCTAssertEqual(finalRebaseEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendRead({ $0.kind }) { result in
            readBackend = try? result.get()
            readFinished.signal()
        }
        XCTAssertEqual(readFinished.wait(timeout: .now() + 0.05), .timedOut)
        releaseFinalRebase.signal()

        wait(for: [swapFinished], timeout: 2)
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(readBackend, .pingPong)
        XCTAssertTrue(facade.currentBackend === old)
    }

    func test_rollbackFailureIsSanitizedAfterCanonicalSurfaceIsRestored() {
        let old = FakeBackend(
            kind: .pingPong,
            snapshot: snapshot,
            audible: true,
            initiallyAuthoritative: true
        )
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        factory.activationHook = { call in
            if call == 2 { throw FakeError.restore }
        }
        old.cancelHook = { throw FakeError.secretDisposalDetail }

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertThrowsError(try result.get()) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.userInfo["code"] as? String, "playback_backend_rollback_failed")
            XCTAssertFalse(nsError.localizedDescription.contains("secret"))
        }
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: old))
        XCTAssertTrue(old.controlSurfaceActive)
        XCTAssertEqual(old.canonicalResumeCount, 1)
        XCTAssertEqual(old.calls.filter { $0 == "resumeEventDeliveryAfterHandoff" }.count, 1)
        XCTAssertFalse(factory.created.first?.calls.contains("commitQueue") == true)
    }

    func test_handoffPhaseOrderQuarantinesTransientEventsAndDisposesAfterRelease() {
        let trace = TransactionTrace()
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let disposed = expectation(description: "old backend disposed")
        old.phaseHook = { _, phase in
            trace.append(phase == "eventQuarantine" ? "barrier/eventQuarantine" : "old.\(phase)")
        }
        old.disposeHook = { disposed.fulfill() }
        factory.phaseHook = { _, phase in trace.append("new.\(phase)") }
        factory.postCommitActivationHook = { replacement in
            XCTAssertTrue(facade.currentBackend === replacement)
            XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: replacement))
            trace.append("pointer/authority")
        }

        let result = awaitResult { completion in
            facade.setPlaybackBackend(.pingPong) { transactionResult in
                trace.append("release")
                completion(transactionResult)
            }
        }
        wait(for: [disposed], timeout: 1)

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(trace.values, [
            "old.settle",
            "old.snapshot",
            "new.prepare",
            "new.restore",
            "new.ready",
            "barrier/eventQuarantine",
            "old.quiesce",
            "new.prepare",
            "new.restore",
            "new.ready",
            "old.suspendControl",
            "old.relinquish",
            "new.commitQueue",
            "pointer/authority",
            "new.activate",
            "release",
            "old.dispose"
        ])
        XCTAssertEqual(old.transientEventCount, 0)
        XCTAssertEqual(factory.created.first?.canonicalStateCount, 1)
    }

    func test_continuouslyStalePreparationIsBoundedAndKeepsOldOwner() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        let lock = NSLock()
        var position = snapshot.position

        factory.restoreHook = {
            let commandEntered = DispatchSemaphore(value: 0)
            facade.withCurrentBackendAsync({ backend, completion in
                lock.lock()
                position += 1
                let nextPosition = position
                lock.unlock()
                try backend.seek(to: nextPosition)
                commandEntered.signal()
                completion(.success(()))
            }) { (_: Result<Void, Error>) in }
            XCTAssertEqual(commandEntered.wait(timeout: .now() + 0.05), .success)
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual((error as NSError).userInfo["code"] as? String, "playback_backend_busy")
        }
        XCTAssertEqual(factory.created.count, 8)
        XCTAssertTrue(factory.created.allSatisfy(\.disposed))
        XCTAssertTrue(facade.currentBackend === old)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: old))
        XCTAssertTrue(old.audible)
    }

    func test_initialBackendActivatesAndPublishesExactIdentity() {
        let initial = FakeBackend(kind: .standard, snapshot: snapshot)
        let authority = PlaybackBackendAuthority()
        var authorityWasPublishedAtActivation = false
        initial.initialActivationHook = {
            authorityWasPublishedAtActivation = authority.isAuthoritative(.standard, identity: initial)
        }

        _ = PlaybackBackendFacade(
            initial: initial,
            factory: FakeFactory(),
            authority: authority
        )

        XCTAssertEqual(initial.calls, ["activateInitialControlSurface"])
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: initial))
        XCTAssertTrue(authorityWasPublishedAtActivation)
    }

    func test_authorityRejectsSameKindStaleIdentity() {
        let first = FakeBackend(kind: .standard, snapshot: snapshot)
        let current = FakeBackend(kind: .standard, snapshot: snapshot)
        let authority = PlaybackBackendAuthority()

        authority.publish(first)
        authority.publish(current)

        XCTAssertFalse(authority.isAuthoritative(.standard, identity: first))
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: current))
        XCTAssertEqual(authority.currentIdentity, ObjectIdentifier(current))
    }

    func test_standardPingPongStandardRejectsStaleGenerations() {
        let first = FakeBackend(kind: .standard, snapshot: snapshot)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: first, factory: factory, authority: authority)

        _ = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }
        let pingPong = factory.created[0]
        _ = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }
        let current = factory.created[1]

        XCTAssertFalse(authority.isAuthoritative(.standard, identity: first))
        XCTAssertFalse(authority.isAuthoritative(.pingPong, identity: pingPong))
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: current))
        XCTAssertFalse(first === current)
    }

    func test_restoreFailureKeepsExactPreviousGenerationWithoutRestoringOld() {
        let previous = FakeBackend(kind: .pingPong, snapshot: snapshot, initiallyAuthoritative: true)
        let factory = FakeFactory(failRestore: true)
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: previous, factory: factory, authority: authority)

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(authority.isAuthoritative(.pingPong, identity: previous))
        XCTAssertFalse(authority.isAuthoritative(.standard, identity: factory.created[0]))
        XCTAssertFalse(previous.calls.contains("restore"))
        XCTAssertFalse(previous.calls.contains("resumeControlSurface"))
    }

    func test_sameTargetIsNoOpAndPreservesGeneration() {
        let initial = FakeBackend(kind: .standard, snapshot: snapshot)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: initial, factory: factory, authority: authority)

        let result = awaitResult { facade.setPlaybackBackend(.standard, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .standard)
        XCTAssertTrue(facade.currentBackend === initial)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: initial))
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertFalse(initial.calls.contains("settle"))
    }

    func test_sameTargetWaitsForActiveLeaseWithoutSettlingIt() {
        let initial = FakeBackend(kind: .pingPong, snapshot: snapshot)
        let facade = PlaybackBackendFacade(initial: initial, factory: FakeFactory())
        let leaseStarted = DispatchSemaphore(value: 0)
        let leaseFinished = expectation(description: "lease finished")
        let sameTargetFinished = DispatchSemaphore(value: 0)
        var deferredCompletion: ((Result<Void, Error>) -> Void)?
        var sameTargetResult: Result<PlaybackBackendTransactionResult, Error>?

        facade.withCurrentBackendAsync({ _, completion in
            deferredCompletion = completion
            leaseStarted.signal()
        }) { (_: Result<Void, Error>) in leaseFinished.fulfill() }
        XCTAssertEqual(leaseStarted.wait(timeout: .now() + 1), .success)
        facade.setPlaybackBackend(.pingPong) {
            sameTargetResult = $0
            sameTargetFinished.signal()
        }

        XCTAssertEqual(sameTargetFinished.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertFalse(initial.calls.contains("settle"))
        deferredCompletion?(.success(()))
        wait(for: [leaseFinished], timeout: 1)
        XCTAssertEqual(sameTargetFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try? sameTargetResult?.get().snapshot, snapshot)
        XCTAssertFalse(initial.calls.contains("settle"))
    }

    func test_commandsDoNotWaitForPostCommitDisposalAndRouteReplacement() {
        let old = FakeBackend(kind: .standard, snapshot: snapshot, audible: true)
        let factory = FakeFactory()
        let facade = PlaybackBackendFacade(initial: old, factory: factory)
        let disposeEntered = DispatchSemaphore(value: 0)
        let releaseDispose = DispatchSemaphore(value: 0)
        let swapFinished = expectation(description: "swap finished")
        let commandFinished = expectation(description: "command finished")
        let commandEntered = DispatchSemaphore(value: 0)
        var routedBackend: PlaybackBackend?
        old.disposeHook = {
            disposeEntered.signal()
            releaseDispose.wait()
        }

        facade.setPlaybackBackend(.pingPong) { _ in swapFinished.fulfill() }
        XCTAssertEqual(disposeEntered.wait(timeout: .now() + 1), .success)
        facade.withCurrentBackendAsync({ backend, completion in
            routedBackend = backend
            backend.pause()
            commandEntered.signal()
            completion(.success(()))
        }) { (_: Result<Void, Error>) in commandFinished.fulfill() }

        XCTAssertEqual(commandEntered.wait(timeout: .now() + 1), .success)
        wait(for: [swapFinished, commandFinished], timeout: 1)
        XCTAssertTrue(routedBackend === factory.created.first)
        releaseDispose.signal()
    }

    func test_repeatedSwapsPublishOnlyLatestGeneration() {
        let initial = FakeBackend(kind: .standard, snapshot: snapshot)
        let factory = FakeFactory()
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: initial, factory: factory, authority: authority)

        for index in 0..<12 {
            let kind: PlaybackBackendKind = index.isMultiple(of: 2) ? .pingPong : .standard
            _ = awaitResult { facade.setPlaybackBackend(kind, completion: $0) }
        }

        let current = facade.currentBackend
        let disposalDeadline = Date().addingTimeInterval(1)
        while !factory.created.dropLast().allSatisfy(\.disposed), Date() < disposalDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(current.kind, .standard)
        XCTAssertTrue(authority.isAuthoritative(.standard, identity: current.identity))
        XCTAssertEqual(factory.created.count, 12)
        XCTAssertTrue(factory.created.dropLast().allSatisfy { $0.disposed })
    }

    func test_incomingQueueRestorePreservesTrackObjectIdentity() {
        let first = NSObject()
        let second = NSObject()
        let candidateOwnedObject = NSObject()

        let restored = playbackBackendQueueForRestore(
            incoming: [first, second],
            current: { [candidateOwnedObject] }
        )

        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored[0] === first)
        XCTAssertTrue(restored[1] === second)
        XCTAssertFalse(restored.contains { $0 === candidateOwnedObject })
    }

    func test_incomingQueueProviderReadsLatestTrackObjectsForFinalRebase() {
        let initial = NSObject()
        let freshFirst = NSObject()
        let freshSecond = NSObject()
        let candidateOwnedObject = NSObject()
        var incoming = [initial]
        let provider = { incoming }

        let warmup = playbackBackendQueueForRestore(
            incomingProvider: provider,
            current: { [candidateOwnedObject] }
        )
        incoming = [freshFirst, freshSecond]
        let final = playbackBackendQueueForRestore(
            incomingProvider: provider,
            current: { [candidateOwnedObject] }
        )

        XCTAssertEqual(warmup.count, 1)
        XCTAssertTrue(warmup[0] === initial)
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final[0] === freshFirst)
        XCTAssertTrue(final[1] === freshSecond)
        XCTAssertFalse(final.contains { $0 === candidateOwnedObject })
    }

    func test_activationRunsOnlyAfterFacadeAndAuthorityPublication() {
        let old = PhasedBackend(kind: .standard, snapshot: snapshot)
        let factory = PhasedFactory(snapshot: snapshot)
        let authority = PlaybackBackendAuthority()
        let facade = PlaybackBackendFacade(initial: old, factory: factory, authority: authority)
        var facadeWasReplacementAtActivation = false
        var authorityWasReplacementAtActivation = false
        factory.activationHook = { replacement in
            facadeWasReplacementAtActivation = facade.currentBackend === replacement
            authorityWasReplacementAtActivation = authority.isAuthoritative(
                .pingPong,
                identity: replacement
            )
        }

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertEqual(try? result.get().backend, .pingPong)
        XCTAssertEqual(factory.created.first?.activationCalls, 1)
        XCTAssertTrue(facadeWasReplacementAtActivation)
        XCTAssertTrue(authorityWasReplacementAtActivation)
        XCTAssertEqual(factory.created.first?.calls, [
            "prepare", "restore", "prepare", "restore", "commitQueue", "activateAfterCommit"
        ])
    }

    func test_rollbackPreservesPreviousAuthoritativeQueueWithoutCandidateCommit() {
        let old = StatefulIOSBackend(
            kind: .standard,
            snapshot: snapshot,
            authoritativeQueue: snapshot.queueIDs,
            failRelinquish: true
        )
        let facade = PlaybackBackendFacade(
            initial: old,
            factory: StatefulIOSFactory(snapshot: snapshot)
        )

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(old.authoritativeQueue, snapshot.queueIDs)
        XCTAssertEqual(old.commitCalls, 0)
        XCTAssertEqual(old.rollbackCalls, 1)
    }

    func test_uncommittedSharedPlayerCandidateCleanupDoesNotClearOldRemoteCommands() {
        let shared = SharedControlSurface()
        let old = SharedPlayerBackend(
            kind: .standard,
            snapshot: snapshot,
            shared: shared,
            initiallyAuthoritative: true
        )
        let factory = SharedPlayerFactory(snapshot: snapshot, shared: shared, failRestore: true)
        let facade = PlaybackBackendFacade(initial: old, factory: factory)

        let result = awaitResult { facade.setPlaybackBackend(.pingPong, completion: $0) }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(shared.remoteCommandsInstalled)
        XCTAssertTrue(facade.currentBackend === old)
    }

    func test_staleAsyncEventDeliveryCannotCrossListenerTokenGeneration() {
        let stale = PlaybackBackendEventToken()
        stale.activate()
        let queuedDelivery = { stale.acceptsDelivery }
        stale.invalidate()

        let current = PlaybackBackendEventToken()
        current.activate()

        XCTAssertFalse(queuedDelivery())
        XCTAssertTrue(current.acceptsDelivery)
    }

    func test_operationInvalidationResolvesBlockedCallbackExactlyOnce() {
        let registry = PlaybackBackendOperationRegistry()
        var cancellations: [String] = []
        let ticket = registry.begin { reason in cancellations.append(reason) }

        registry.invalidateAll(reason: "pause")
        registry.invalidateAll(reason: "stop")

        XCTAssertFalse(registry.isCurrent(ticket))
        XCTAssertEqual(cancellations, ["pause"])
    }

    func test_operationRegistryAllowsSynchronousTerminalCallbackWithoutDeadlock() {
        let registry = PlaybackBackendOperationRegistry()
        let ticket = registry.begin { _ in XCTFail("ticket should not be cancelled") }

        let entered = registry.performIfCurrent(ticket) {
            XCTAssertTrue(registry.complete(ticket))
        }

        XCTAssertTrue(entered)
        XCTAssertFalse(registry.isCurrent(ticket))
    }

    func test_operationRegistryCompletionCannotEraseReentrantReplacementTicket() {
        let registry = PlaybackBackendOperationRegistry()
        let first = registry.begin { _ in XCTFail("completed ticket should not be cancelled") }
        var second: PlaybackBackendOperationTicket?

        XCTAssertTrue(registry.complete(first) {
            second = registry.begin { _ in }
        })

        XCTAssertNotNil(second)
        XCTAssertTrue(registry.isCurrent(second!))
    }

    func test_operationRegistryRunsDeferredTerminalCallbackOutsideOutermostLock() {
        let registry = PlaybackBackendOperationRegistry()
        let ticket = registry.begin { _ in XCTFail("ticket should not be cancelled") }
        let callbackFinished = expectation(description: "terminal callback")
        var callbackRanDuringMutation = false

        XCTAssertTrue(registry.performIfCurrent(ticket) {
            registry.performAfterCurrentMutation {
                let otherThreadFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = registry.isCurrent(ticket)
                    otherThreadFinished.signal()
                }
                XCTAssertEqual(otherThreadFinished.wait(timeout: .now() + 1), .success)
                callbackFinished.fulfill()
            }
            callbackRanDuringMutation = true
        })

        XCTAssertTrue(callbackRanDuringMutation)
        wait(for: [callbackFinished], timeout: 2)
    }

    func test_operationRegistryCompleteDefersExternalCallbackOutsideLock() {
        let registry = PlaybackBackendOperationRegistry()
        let ticket = registry.begin { _ in XCTFail("ticket should not be cancelled") }
        let callbackFinished = expectation(description: "complete callback")

        XCTAssertTrue(registry.complete(ticket) {
            registry.performAfterCurrentMutation {
                let workerFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = registry.isCurrent(ticket)
                    workerFinished.signal()
                }
                XCTAssertEqual(workerFinished.wait(timeout: .now() + 1), .success)
                callbackFinished.fulfill()
            }
        })

        wait(for: [callbackFinished], timeout: 2)
    }

    func test_exclusiveCommandSlotRejectsSecondWithoutReplacingFirstCompletion() {
        let slot = PlaybackBackendExclusiveCommandSlot<Void>()
        var firstResults = 0
        var secondResults = 0
        let first = slot.begin { _ in firstResults += 1 }

        let rejectedSecond = slot.begin { _ in secondResults += 1 }

        XCTAssertNotNil(first)
        XCTAssertNil(rejectedSecond)
        slot.complete(first!, result: .success(()))
        slot.complete(first!, result: .success(()))
        XCTAssertEqual(firstResults, 1)
        XCTAssertEqual(secondResults, 0)
        XCTAssertFalse(slot.isOccupied)
    }

    func test_exclusiveCommandSlotCompletionCanReenterSlotAfterUnlock() {
        let slot = PlaybackBackendExclusiveCommandSlot<Void>()
        var replacement: PlaybackBackendCommandCompletion<Void>?
        let first = slot.begin { _ in
            replacement = slot.begin { _ in }
        }

        slot.complete(first!, result: .success(()))

        XCTAssertNotNil(replacement)
        XCTAssertTrue(slot.isOccupied)
        slot.complete(replacement!, result: .success(()))
        XCTAssertFalse(slot.isOccupied)
    }

    func test_productionAdapterQueueStateKeepsAuthoritativeQueueOnRollback() {
        let state = PlaybackBackendQueueState(["old-a", "old-b"])
        state.stage(["candidate-a"])

        XCTAssertEqual(state.rollback(), ["old-a", "old-b"])
        XCTAssertEqual(state.authoritative, ["old-a", "old-b"])
    }

    private func awaitResult(
        _ operation: (@escaping (Result<PlaybackBackendTransactionResult, Error>) -> Void) -> Void
    ) -> Result<PlaybackBackendTransactionResult, Error> {
        let finished = expectation(description: "transaction")
        var captured: Result<PlaybackBackendTransactionResult, Error>!
        operation {
            captured = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        return captured
    }
}

private final class PhasedFactory: PlaybackBackendFactory {
    private let snapshot: PlaybackBackendSnapshot
    var activationHook: ((PhasedBackend) -> Void)?
    private(set) var created: [PhasedBackend] = []

    init(snapshot: PlaybackBackendSnapshot) { self.snapshot = snapshot }

    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        let backend = PhasedBackend(kind: kind, snapshot: snapshot)
        backend.activationHook = { [weak self, weak backend] in
            guard let self, let backend else { return }
            self.activationHook?(backend)
        }
        created.append(backend)
        return backend
    }
}

private final class PhasedBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private let snapshotValue: PlaybackBackendSnapshot
    var activationHook: (() -> Void)?
    private(set) var calls: [String] = []
    private(set) var activationCalls = 0

    init(kind: PlaybackBackendKind, snapshot: PlaybackBackendSnapshot) {
        self.kind = kind
        self.snapshotValue = snapshot
    }

    func settleActiveTransition() throws {}
    func snapshot() throws -> PlaybackBackendSnapshot { snapshotValue }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws { calls.append("prepare") }
    func restore(_ snapshot: PlaybackBackendSnapshot) throws { calls.append("restore") }
    func stopAndMute() throws {}
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) { calls.append("commitQueue") }
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("activateAfterCommit")
        activationCalls += 1
        activationHook?()
    }
    func play() throws {}
    func pause() {}
    func seek(to position: Double) throws {}
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {}
}

private final class StatefulIOSFactory: PlaybackBackendFactory {
    private let snapshot: PlaybackBackendSnapshot
    init(snapshot: PlaybackBackendSnapshot) { self.snapshot = snapshot }
    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        StatefulIOSBackend(kind: kind, snapshot: snapshot, authoritativeQueue: [])
    }
}

private final class StatefulIOSBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private let snapshotValue: PlaybackBackendSnapshot
    private let failRelinquish: Bool
    private var pendingQueue: [String] = []
    private(set) var authoritativeQueue: [String]
    private(set) var commitCalls = 0
    private(set) var rollbackCalls = 0

    init(
        kind: PlaybackBackendKind,
        snapshot: PlaybackBackendSnapshot,
        authoritativeQueue: [String],
        failRelinquish: Bool = false
    ) {
        self.kind = kind
        self.snapshotValue = snapshot
        self.authoritativeQueue = authoritativeQueue
        self.failRelinquish = failRelinquish
    }

    func settleActiveTransition() throws {}
    func snapshot() throws -> PlaybackBackendSnapshot { snapshotValue }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws { pendingQueue = snapshot.queueIDs }
    func restore(_ snapshot: PlaybackBackendSnapshot) throws {}
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) { rollbackCalls += 1 }
    func stopAndMute() throws {}
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {
        if failRelinquish { throw FakeError.restore }
    }
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {
        commitCalls += 1
        authoritativeQueue = pendingQueue
    }
    func play() throws {}
    func pause() {}
    func seek(to position: Double) throws {}
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {}
}

private final class SharedControlSurface {
    var remoteCommandsInstalled = true
}

private final class SharedPlayerFactory: PlaybackBackendFactory {
    private let snapshot: PlaybackBackendSnapshot
    private let shared: SharedControlSurface
    private let failRestore: Bool

    init(snapshot: PlaybackBackendSnapshot, shared: SharedControlSurface, failRestore: Bool) {
        self.snapshot = snapshot
        self.shared = shared
        self.failRestore = failRestore
    }

    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        SharedPlayerBackend(
            kind: kind,
            snapshot: snapshot,
            shared: shared,
            failRestore: failRestore
        )
    }
}

private final class SharedPlayerBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private let snapshotValue: PlaybackBackendSnapshot
    private let shared: SharedControlSurface
    private let failRestore: Bool
    private let initiallyAuthoritative: Bool

    init(
        kind: PlaybackBackendKind,
        snapshot: PlaybackBackendSnapshot,
        shared: SharedControlSurface,
        failRestore: Bool = false,
        initiallyAuthoritative: Bool = false
    ) {
        self.kind = kind
        self.snapshotValue = snapshot
        self.shared = shared
        self.failRestore = failRestore
        self.initiallyAuthoritative = initiallyAuthoritative
    }

    func settleActiveTransition() throws {}
    func snapshot() throws -> PlaybackBackendSnapshot { snapshotValue }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws {}
    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        if failRestore { throw FakeError.restore }
    }
    func stopAndMute() throws {}
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {}
    func play() throws {}
    func pause() {}
    func seek(to position: Double) throws {}
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {
        if initiallyAuthoritative { shared.remoteCommandsInstalled = false }
    }
}

private final class AudibleRegistry {
    var backends: [FakeBackend] = []
    var counts: [Int] = []
}

private final class FakeFactory: PlaybackBackendFactory {
    private let registry: AudibleRegistry?
    private let failPrepare: Bool
    private let failRestore: Bool
    private let barrier: TransactionBarrier?
    private let sharedResource: SharedPlaybackResource?
    private let mutateSharedOnRestore: Bool
    private(set) var created: [FakeBackend] = []
    private(set) var requested: [PlaybackBackendKind] = []
    var prepareHook: (() -> Void)?
    var restoreHook: (() -> Void)?
    var commitHook: (() -> Void)?
    var activationHook: ((Int) throws -> Void)?
    var phaseHook: ((PlaybackBackendKind, String) -> Void)?
    var postCommitActivationHook: ((FakeBackend) -> Void)?

    init(
        registry: AudibleRegistry? = nil,
        failPrepare: Bool = false,
        failRestore: Bool = false,
        barrier: TransactionBarrier? = nil,
        sharedResource: SharedPlaybackResource? = nil,
        mutateSharedOnRestore: Bool = false
    ) {
        self.registry = registry
        self.failPrepare = failPrepare
        self.failRestore = failRestore
        self.barrier = barrier
        self.sharedResource = sharedResource
        self.mutateSharedOnRestore = mutateSharedOnRestore
    }

    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend {
        requested.append(kind)
        let backend = FakeBackend(
            kind: kind,
            snapshot: .empty,
            registry: registry,
            failPrepare: failPrepare,
            failRestore: failRestore,
            barrier: barrier,
            sharedResource: sharedResource,
            mutateSharedOnRestore: mutateSharedOnRestore,
            prepareHook: prepareHook,
            restoreHook: restoreHook,
            commitHook: commitHook,
            activationHook: activationHook,
            phaseHook: phaseHook,
            postCommitActivationHook: postCommitActivationHook
        )
        created.append(backend)
        registry?.backends.append(backend)
        return backend
    }
}

private final class FakeBackend: PlaybackBackend {
    let kind: PlaybackBackendKind
    private var snapshotValue: PlaybackBackendSnapshot
    private let registry: AudibleRegistry?
    private let failPrepare: Bool
    private let failRestore: Bool
    private let failDispose: Bool
    private let barrier: TransactionBarrier?
    private let sharedResource: SharedPlaybackResource?
    private let mutateSharedOnRestore: Bool
    private let prepareHook: (() -> Void)?
    private let restoreHook: (() -> Void)?
    private let commitHook: (() -> Void)?
    private let activationHook: ((Int) throws -> Void)?
    private let postCommitActivationHook: ((FakeBackend) -> Void)?
    private var capturedSharedQueue: [AnyObject] = []
    private var isAuthoritative: Bool
    private(set) var calls: [String] = []
    private(set) var restoredSnapshot: PlaybackBackendSnapshot?
    private(set) var restoredSnapshots: [PlaybackBackendSnapshot] = []
    private(set) var preparedSnapshots: [PlaybackBackendSnapshot] = []
    private(set) var preparedSharedQueues: [[AnyObject]] = []
    private(set) var committedQueue: [String]?
    private(set) var disposed = false
    private(set) var audible: Bool
    private(set) var controlSurfaceActive: Bool
    private(set) var canonicalResumeCount = 0
    private(set) var canonicalStateCount = 0
    private(set) var transientEventCount = 0
    private var activationCallCount = 0
    private var eventDeliverySuspended = false
    var settleHook: (() -> Void)?
    var disposeHook: (() -> Void)?
    var initialActivationHook: (() -> Void)?
    var cancelHook: (() throws -> Void)?
    var phaseHook: ((PlaybackBackendKind, String) -> Void)?

    init(
        kind: PlaybackBackendKind,
        snapshot: PlaybackBackendSnapshot,
        audible: Bool = false,
        registry: AudibleRegistry? = nil,
        failPrepare: Bool = false,
        failRestore: Bool = false,
        failDispose: Bool = false,
        barrier: TransactionBarrier? = nil,
        sharedResource: SharedPlaybackResource? = nil,
        mutateSharedOnRestore: Bool = false,
        initiallyAuthoritative: Bool = false,
        prepareHook: (() -> Void)? = nil,
        restoreHook: (() -> Void)? = nil,
        commitHook: (() -> Void)? = nil,
        activationHook: ((Int) throws -> Void)? = nil,
        phaseHook: ((PlaybackBackendKind, String) -> Void)? = nil,
        postCommitActivationHook: ((FakeBackend) -> Void)? = nil
    ) {
        self.kind = kind
        self.snapshotValue = snapshot
        self.audible = audible
        self.controlSurfaceActive = initiallyAuthoritative
        self.registry = registry
        self.failPrepare = failPrepare
        self.failRestore = failRestore
        self.failDispose = failDispose
        self.barrier = barrier
        self.sharedResource = sharedResource
        self.mutateSharedOnRestore = mutateSharedOnRestore
        self.isAuthoritative = initiallyAuthoritative
        self.prepareHook = prepareHook
        self.restoreHook = restoreHook
        self.commitHook = commitHook
        self.activationHook = activationHook
        self.phaseHook = phaseHook
        self.postCommitActivationHook = postCommitActivationHook
    }

    func settleActiveTransition() throws {
        calls.append("settle")
        phaseHook?(kind, "settle")
        settleHook?()
    }
    func activateInitialControlSurface() {
        calls.append("activateInitialControlSurface")
        controlSurfaceActive = true
        initialActivationHook?()
    }
    func suspendEventDeliveryForHandoff() throws {
        calls.append("suspendEventDeliveryForHandoff")
        eventDeliverySuspended = true
        phaseHook?(kind, "eventQuarantine")
    }
    func resumeEventDeliveryAfterHandoff(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("resumeEventDeliveryAfterHandoff")
        eventDeliverySuspended = false
        phaseHook?(kind, "resumeEventDelivery")
        resumeControlSurface(snapshot)
    }
    func suspendControlSurface() throws {
        calls.append("suspendControlSurface")
        controlSurfaceActive = false
        phaseHook?(kind, "suspendControl")
    }
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("resumeControlSurface")
        controlSurfaceActive = true
        canonicalResumeCount += 1
    }
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {
        calls.append("relinquishExclusiveControlSurfaceBeforeCommit")
        phaseHook?(kind, "relinquish")
    }
    func snapshot() throws -> PlaybackBackendSnapshot {
        calls.append("snapshot")
        phaseHook?(kind, "snapshot")
        capturedSharedQueue = sharedResource?.queue ?? []
        return snapshotValue
    }
    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot {
        calls.append("beginHandoffQuiescence")
        if !eventDeliverySuspended { transientEventCount += 2 }
        phaseHook?(kind, "quiesce")
        setAudible(false)
        return snapshotValue
    }
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("cancelHandoffQuiescence")
        phaseHook?(kind, "cancelQuiescence")
        try cancelHook?()
        snapshotValue = snapshot
        setAudible(snapshot.playWhenReady)
    }
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("prepare")
        phaseHook?(kind, "prepare")
        preparedSnapshots.append(snapshot)
        preparedSharedQueues.append(sharedResource?.queue ?? [])
        setAudible(false)
        prepareHook?()
        barrier?.enter(kind)
        if failPrepare { throw FakeError.prepare }
    }
    func restore(_ snapshot: PlaybackBackendSnapshot) throws {
        calls.append("restore")
        phaseHook?(kind, "restore")
        restoreHook?()
        if mutateSharedOnRestore && !isAuthoritative {
            sharedResource?.queue = []
        }
        if failRestore { throw FakeError.restore }
        if isAuthoritative {
            sharedResource?.queue = capturedSharedQueue
        }
        snapshotValue = snapshot
        restoredSnapshot = snapshot
        restoredSnapshots.append(snapshot)
        barrier?.exit(kind)
    }
    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws {
        activationCallCount += 1
        calls.append("prepareActivation")
        phaseHook?(kind, "ready")
        try activationHook?(activationCallCount)
    }
    func stopAndMute() throws { calls.append("stopAndMute"); setAudible(false) }
    func commitQueue(_ snapshot: PlaybackBackendSnapshot) {
        calls.append("commitQueue")
        phaseHook?(kind, "commitQueue")
        commitHook?()
        committedQueue = snapshot.queueIDs
        isAuthoritative = true
    }
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {
        postCommitActivationHook?(self)
        calls.append("activateAfterCommit")
        canonicalStateCount += 1
        phaseHook?(kind, "activate")
        setAudible(snapshot.playWhenReady)
    }
    func play() throws { setAudible(true) }
    func pause() {
        calls.append("pause")
        snapshotValue = snapshotValue.with(playWhenReady: false)
        setAudible(false)
    }
    func seek(to position: Double) throws { snapshotValue = snapshotValue.with(position: position) }
    func startTransition(_ request: PlaybackTransitionRequest) throws {}
    func dispose() throws {
        phaseHook?(kind, "dispose")
        disposeHook?()
        disposed = true
        isAuthoritative = false
        calls.append("dispose")
        if failDispose { throw FakeError.secretDisposalDetail }
    }

    func simulateNaturalSnapshot(_ snapshot: PlaybackBackendSnapshot) {
        snapshotValue = snapshot
    }

    private func setAudible(_ value: Bool) {
        audible = value
        if let registry = registry {
            registry.counts.append(registry.backends.filter { $0.audible }.count)
        }
    }
}

private final class SharedPlaybackResource {
    var queue: [AnyObject]

    init(queue: [AnyObject]) {
        self.queue = queue
    }
}

private final class TransactionTrace {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        let result = recorded
        lock.unlock()
        return result
    }
}

private enum FakeError: Error {
    case prepare
    case restore
    case cancelled
    case secretDisposalDetail
}

/// FailedLoadRule and StandardCommandLoad as StandardPlaybackBackend feeds them.
private final class CommandLoadHarness {
    private let items = [NSObject(), NSObject(), NSObject()]
    var first: ObjectIdentifier { return ObjectIdentifier(items[0]) }
    var second: ObjectIdentifier { return ObjectIdentifier(items[1]) }
    var third: ObjectIdentifier { return ObjectIdentifier(items[2]) }
    let rule = FailedLoadRule()
    let loads = StandardCommandLoad()
    var outcomes: [StandardCommandLoadOutcome] = []

    /// A command moved the player to `item` and waits for its load, as the backend does.
    func command(_ item: ObjectIdentifier) {
        rule.skipped()
        loads.begin(target: item, active: rule.active, reported: rule.reported) { [unowned self] in self.outcomes.append($0) }
    }

    /// The player's item became ready, as the backend's followLoad.
    func ready() {
        _ = rule.ready()
        loads.ruleSettled(active: rule.active, reported: rule.reported)
    }
}

private final class TransactionBarrier {
    let firstPrepareEntered = DispatchSemaphore(value: 0)
    let releaseFirstPrepare = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inFlight = 0
    private var first = true
    private(set) var maxInFlight = 0
    private(set) var trace: [String] = []

    func enter(_ kind: PlaybackBackendKind) {
        lock.lock()
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        trace.append("enter:\(kind.rawValue)")
        let shouldWait = first
        first = false
        lock.unlock()
        if shouldWait {
            firstPrepareEntered.signal()
            releaseFirstPrepare.wait()
        }
    }

    func exit(_ kind: PlaybackBackendKind) {
        lock.lock()
        trace.append("exit:\(kind.rawValue)")
        inFlight -= 1
        lock.unlock()
    }
}

/// A local HLS server (Network framework) for the real-player test: a master playlist of three
/// audio renditions (r0, r1, r2), each a VOD playlist of four 4 s segments, and segments that
/// fail part way: the full Content-Length is announced, 3000 bytes of packed AAC are sent, the
/// connection is held for 2 s, then closed. It records each request's path and arrival time.
private final class PartialSegmentHLSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rntp.test.hls-server")
    private let lock = NSLock()
    private var requests: [(path: String, at: TimeInterval)] = []
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    var masterURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/master.m3u8")!
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { $0.path }
    }

    func firstRequestAt(_ matches: (String) -> Bool) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return requests.first { matches($0.path) }?.at
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self, error == nil else { return }
            var request = buffer
            if let data = data { request.append(data) }
            guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                if !isComplete { self.receiveRequest(on: connection, buffer: request) }
                return
            }
            let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.lock.lock()
            self.requests.append((path, ProcessInfo.processInfo.systemUptime))
            self.lock.unlock()
            self.respond(to: path, on: connection)
        }
    }

    private func respond(to path: String, on connection: NWConnection) {
        let playlist = "application/vnd.apple.mpegurl"
        if path == "/master.m3u8" {
            var body = "#EXTM3U\n#EXT-X-VERSION:3\n"
            for (name, bandwidth) in [("r0", 64_000), ("r1", 128_000), ("r2", 256_000)] {
                body += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"mp4a.40.2\"\n\(name)/index.m3u8\n"
            }
            send(Data(body.utf8), type: playlist, on: connection)
        } else if path.hasSuffix("/index.m3u8") {
            var body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            for index in 0..<4 { body += "#EXTINF:4.0,\nsegment-\(index).aac\n" }
            body += "#EXT-X-ENDLIST\n"
            send(Data(body.utf8), type: playlist, on: connection)
        } else if path.hasSuffix(".aac") {
            let segment = Self.packedAudioSegment()
            let head = "HTTP/1.1 200 OK\r\nContent-Type: audio/aac\r\nContent-Length: \(segment.count)\r\n\r\n"
            connection.send(content: Data(head.utf8) + segment.prefix(3_000), completion: .contentProcessed { _ in })
            queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        } else {
            send(Data(), type: "text/plain", status: "404 Not Found", on: connection)
        }
    }

    private func send(_ body: Data, type: String, status: String = "200 OK", on connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.receiveRequest(on: connection, buffer: Data())
        })
    }

    /// One 4 s packed-audio segment: the ID3 timestamp HLS requires, then AAC LC frames (44.1 kHz,
    /// stereo) with silent payloads.
    private static func packedAudioSegment() -> Data {
        func syncSafe(_ value: Int) -> [UInt8] {
            [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
        }
        let body = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0] + [UInt8](repeating: 0, count: 8)
        let frame = Array("PRIV".utf8) + syncSafe(body.count) + [0, 0] + body
        var data = Data(Array("ID3".utf8) + [4, 0, 0] + syncSafe(frame.count) + frame)
        // A silent AAC LC raw data block (single channel pair element) padded to a fixed size.
        let payload = [UInt8](repeating: 0, count: 32)
        let length = 7 + payload.count
        let header: [UInt8] = [
            0xFF, 0xF1, UInt8((1 << 6) | (4 << 2)), UInt8((2 << 6) | (length >> 11)),
            UInt8((length >> 3) & 0xFF), UInt8(((length & 7) << 5) | 0x1F), 0xFC,
        ]
        for _ in 0..<(4 * 44_100 / 1_024 + 1) { data.append(contentsOf: header + payload) }
        return data
    }
}

/// An item's reading with only its access log's bytes (`entries`: per entry, negative when
/// unknown, as ItemLoadSnapshot(of:) sums them): no loaded range, no event or error counted.
private func loggedBytes(_ entries: [Int64]) -> ItemLoadSnapshot {
    ItemLoadSnapshot(loadedRanges: [], transferredBytes: entries.reduce(0.0) { $0 + Double(max(0, $1)) }, accessLogEvents: 0, errorLogEntries: 0)
}

/// SwiftAudioEx 1.1.0's layout around its AVPlayer (AudioPlayer.wrapper → AVPlayerWrapper.avPlayer).
private protocol FakeAVPlayerWrapperProtocol: AnyObject {}

private final class FakeAVPlayerWrapper: FakeAVPlayerWrapperProtocol {
    var avPlayer = AVPlayer()
}

private class FakeAudioPlayer {
    let wrapper: FakeAVPlayerWrapperProtocol = FakeAVPlayerWrapper()
    var avPlayer: AVPlayer { return (wrapper as! FakeAVPlayerWrapper).avPlayer }
}

private final class FakeQueuedAudioPlayer: FakeAudioPlayer {
    var items: [String] = []
}
