const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8');
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function section(source, startToken, endToken) {
  const start = source.indexOf(startToken);
  const end = source.indexOf(endToken, start + startToken.length);
  if (start < 0 || end < 0) {
    throw new Error(`Unable to isolate section ${startToken}`);
  }
  return source.slice(start, end);
}

const orchestrator = read('ios/RNTrackPlayer/IOSPlaybackOrchestrator.swift');
const facade = read('ios/RNTrackPlayer/PlaybackBackend.swift');
const standardBackend = read('ios/RNTrackPlayer/StandardPlaybackBackend.swift');
const pingPongBackend = read('ios/RNTrackPlayer/PingPongPlaybackBackend.swift');
const player = read('ios/RNTrackPlayer/RNTrackPlayer.swift');
const engine = read('ios/RNTrackPlayer/IOSCrossfadeEngine.swift');
const iosIntegrationTests = read('example/ios/exampleTests/IOSPlaybackBackendIntegrationTests.swift');
const playerOptions = read('src/interfaces/PlayerOptions.ts');
const playerOptionsDocs = read('docs/docs/api/objects/player-options.md');
const podspec = read('react-native-track-player.podspec');
const finishCrossfade = section(
  orchestrator,
  'private func finishCrossfade(',
  'private func schedulePostCrossfadeStandbyMaintenance('
);
const postCrossfadeMaintenance = section(
  orchestrator,
  'private func schedulePostCrossfadeStandbyMaintenance(',
  'private func fallbackToTargetAfterStalledCrossfade('
);
const cancelAllWork = section(
  orchestrator,
  'private func cancelAllWork()',
  'private func checkpoint(reason: String)'
);
const cancelScheduledPlaybackWork = section(
  orchestrator,
  'private func cancelScheduledPlaybackWork()',
  'private func queueHash()'
);
const cancelStandbyMaintenanceLocked = section(
  orchestrator,
  'private func cancelStandbyMaintenanceLocked()',
  'private func isStandbyPreparationSuperseded('
);
const pingPongPrepare = section(
  pingPongBackend,
  'func prepareSilently(',
  'func restore('
);
const pingPongCommit = section(
  pingPongBackend,
  'func commitQueue(',
  'func play()'
);
const makePlaybackBackend = section(
  player,
  'private func makePlaybackBackend(',
  'private func makeStandardPlayerCandidate()'
);
const remoteHandlers = section(
  player,
  'private func configureRemoteCommandHandlers(',
  'private func installPlaybackBackendFacade('
);
const setupPlayer = section(
  player,
  'public func setupPlayer(',
  'private func configureAudioSession()'
);
const progressTimer = section(
  player,
  'private func startOrchestratedProgressUpdates()',
  'private func stopOrchestratedProgressUpdates()'
);

assert(
  orchestrator.includes('private var standbyMaintenanceWorkItem: DispatchWorkItem?'),
  'iOS orchestrator must track deferred standby maintenance work.'
);
assert(
  podspec.includes('s.exclude_files = "ios/RNTrackPlayerTests/**/*"'),
  'The production iOS pod must exclude the standalone transaction-test target sources.'
);
assert(
  engine.includes('final class IOSCrossfadeEngine') &&
    !fs.existsSync(path.join(root, 'ios/RNTrackPlayer/IOSCrossfadeCoordinator.swift')),
  'iOS must expose only the RNTP-owned crossfade engine, with no legacy coordinator source.'
);
assert(
  playerOptions.includes("crossfadeEngineMode?: 'orchestratedDualEngine' | 'legacyHybrid'") &&
    playerOptions.includes('@deprecated RNTP owns a single crossfade engine') &&
    playerOptionsDocs.includes('Both `orchestratedDualEngine` and the historical `legacyHybrid` value select the same') &&
    !player.includes('legacyHybrid'),
  'iOS must keep the deprecated setup type alias without restoring a legacy playback owner.'
);
assert(
  facade.includes('var identity: AnyObject { get }') &&
    facade.includes('ObjectIdentifier($0.identity)') &&
    !facade.includes('self.authority.clear()') &&
    facade.includes('authority.publish(initial)') &&
    facade.includes('authority.publish(replacement)'),
  'iOS must keep the old exact-generation authority published through candidate preparation and publish the replacement only at commit.'
);
assert(
  facade.indexOf('try previous.relinquishExclusiveControlSurfaceBeforeCommit()') <
    facade.indexOf('replacement.commitQueue(quiescedSnapshot)') &&
    facade.indexOf('replacement.commitQueue(quiescedSnapshot)') <
      facade.indexOf('self.backend = replacement') &&
    facade.indexOf('self.backend = replacement') < facade.indexOf('self.authority.publish(replacement)') &&
    facade.includes('initial.activateInitialControlSurface()'),
  'iOS must commit the queue before publishing the facade pointer and exact authority.'
);
assert(
  facade.includes('private let cleanupDiagnosticQueue = DispatchQueue(') &&
    facade.includes('let observer = onCleanupDiagnostic') &&
    facade.includes('cleanupDiagnosticQueue.async {') &&
    facade.includes('observer(.disposalFailed)') &&
    facade.indexOf(
      'completion(.success(PlaybackBackendTransactionResult(',
      facade.indexOf('replacement.activateAfterCommit')
    ) < facade.indexOf('self.disposeCommittedBackend(previous)') &&
    !facade.includes('self.onCleanupDiagnostic(.disposalFailed)'),
  'iOS post-commit cleanup diagnostics must be observational and unable to block transaction completion.'
);
assert(
  makePlaybackBackend.includes('let incomingQueueProvider: (() -> [Track])?') &&
    makePlaybackBackend.includes('incomingQueueProvider = { [weak self] in self?.playerTracks() ?? [] }') &&
    makePlaybackBackend.includes('let source = initiallyAuthoritative ? player : makeStandardPlayerCandidate()') &&
    makePlaybackBackend.includes('incomingQueueProvider: incomingQueueProvider') &&
    standardBackend.includes('playbackBackendQueueForRestore('),
  'iOS PingPong-to-standard swaps must create a fresh player and restore the incoming Track objects.'
);
assert(
  makePlaybackBackend.includes('let orchestrator = IOSPlaybackOrchestrator()') &&
    makePlaybackBackend.includes('queueProvider: { [weak source]') &&
    makePlaybackBackend.includes('self?.commitStandardPlayer(committed)') &&
    player.includes('private func commitStandardPlayer(_ committed: QueuedAudioPlayer)') &&
    player.includes('configurePlayerEvents(committed)'),
  'iOS must create fresh per-generation players/orchestrators and bind events to their immutable source.'
);
assert(
  remoteHandlers.includes('ObjectIdentifier(identity)') &&
    remoteHandlers.includes('playbackBackendAuthority.isAuthoritative(kind, identity: expectedIdentity)') &&
    !setupPlayer.includes('remoteCommandController.handle'),
  'iOS remote handlers must be exact-generation guarded and never overwritten by setup legacy handlers.'
);
assert(
  player.includes('configuredRemoteCommands = remoteCommands') &&
    player.includes('committed.remoteCommands = configuredRemoteCommands') &&
    player.includes('queuePlayer.remoteCommands = configuredRemoteCommands'),
  'iOS remote command configuration must replay on every committed backend generation.'
);
assert(
  progressTimer.includes('let owner = playbackOrchestrator') &&
    progressTimer.includes('isAuthoritative(.pingPong, identity: owner)') &&
    player.includes('handleAudioPlayerSecondElapse(source: QueuedAudioPlayer') &&
    player.includes('isAuthoritative(.standard, identity: source)'),
  'iOS progress and player callbacks must remain bound to the exact authoritative generation.'
);
assert(
  orchestrator.includes('private func schedulePostCrossfadeStandbyMaintenance('),
  'iOS orchestrator must schedule post-crossfade standby maintenance.'
);
assert(
  finishCrossfade.includes('schedulePostCrossfadeStandbyMaintenance(afterCrossfadeDurationMs: context.durationMs)'),
  'iOS finishCrossfade must defer standby maintenance after the audible crossfade completes.'
);
assert(
  postCrossfadeMaintenance.includes('self.standbyEngine.reset()') &&
    postCrossfadeMaintenance.includes('self.preloadNextIfPossibleLocked()'),
  'iOS post-crossfade maintenance must own standby reset and next preload.'
);
assert(
  !finishCrossfade.includes('preloadNextIfPossible()'),
  'iOS finishCrossfade must not preload the next track synchronously on the audio-critical path.'
);
assert(
  finishCrossfade.includes('activeEngine.setVolume(0)') &&
    finishCrossfade.includes('activeEngine.pause()') &&
    !finishCrossfade.includes('activeEngine.reset()'),
  'iOS finishCrossfade must mute/pause the outgoing engine without resetting its AVPlayer synchronously.'
);
assert(
  cancelAllWork.includes('cancelStandbyMaintenanceLocked()') &&
    cancelScheduledPlaybackWork.includes('cancelStandbyMaintenanceLocked()') &&
    cancelStandbyMaintenanceLocked.includes('standbyMaintenanceWorkItem?.cancel()'),
  'iOS deferred standby maintenance must be cancelled with other playback work.'
);
assert(
  orchestrator.includes('private let crossfadeCommandSlot = PlaybackBackendExclusiveCommandSlot<Void>()') &&
    orchestrator.includes('crossfadeCommandSlot.takeResolver(') &&
    orchestrator.includes('crossfadeCommandSlot.takeCurrentResolver(') &&
    orchestrator.includes('cancelActiveCrossfade(errorCode: "pause")') &&
    orchestrator.includes('cancelActiveCrossfade(errorCode: "backend_swap")'),
  'iOS pause and backend swap must resolve the exact active crossfade command lease.'
);
assert(
  !pingPongPrepare.includes('player.') &&
    pingPongCommit.includes('player.volume = 0') &&
    pingPongCommit.includes('player.playWhenReady = false'),
  'iOS pingPong candidate must not mutate the shared standard player before the facade commit.'
);
assert(
  standardBackend.includes('private let queueState = PlaybackBackendQueueState<Track>()') &&
    standardBackend.includes('queueState.captureAuthoritative(queue)') &&
    standardBackend.includes('samePlaybackBackendTrackObjects') &&
    facade.includes('let rollbackSnapshot = finalSnapshot ??') &&
    facade.includes('try previous.cancelHandoffQuiescence(rollbackSnapshot)') &&
    facade.includes('previous.resumeEventDeliveryAfterHandoff(rollbackSnapshot)'),
  'iOS backend rollback must preserve full Track object identity and restore the authoritative queue.'
);
assert(
  standardBackend.includes('var publicPlaybackError: IOSPlaybackErrorSnapshot? { get }') &&
    facade.includes('struct IOSPlaybackErrorSnapshot: Equatable') &&
    standardBackend.includes('func iosPlaybackErrorSnapshot(') &&
    pingPongBackend.includes('var publicPlaybackError: IOSPlaybackErrorSnapshot? { return nil }') &&
    player.includes('error: $0.publicPlaybackError') &&
    !player.includes('getPlaybackStateErrorKeyValues') &&
    player.includes('if state == .error') &&
    iosIntegrationTests.includes('test_iosPlaybackStateErrorContractUsesBackendReadLease') &&
    iosIntegrationTests.includes('XCTAssertFalse(getter.contains("getPlaybackStateBodyKeyValues(state: $0.playbackState)"))'),
  'iOS PlaybackState.error must be generated from the authoritative backend read lease, not the global standard player.'
);
assert(
  facade.includes('withCurrentBackendAsync') &&
    facade.includes('PlaybackBackendCommandCompletion') &&
    facade.includes('activeCommandLeases') &&
    !facade.includes('"playback_backend_command_timeout"') &&
    player.includes('withActivePlaybackBackendAsync'),
  'iOS playback commands must use exact-completion leases and must not report a timeout while native work can still mutate state.'
);
assert(
  player.includes('let initialBackend: PlaybackBackendKind = crossfadeEnabled ? .pingPong : .standard') &&
    player.includes('initiallyAuthoritative: true'),
  'iOS legacy crossfade setup must converge to the authoritative pingPong backend.'
);

// The crossfade engine's waits all run on the tested StallWaitDriver (PlaybackBackend.swift):
// the load (one wait under prepareTimeoutMs, cap-only until the asset is playable, then
// stallTimeoutMs through the ready wait, the seek and the preroll), every seek (prepareTimeoutMs,
// as on Android) and the play start (playStartTimeoutMs).
const enginePrepare = section(engine, 'func prepare(track: Track', 'func seek(to position: Double');
const engineSeek = section(engine, 'func seek(to position: Double', 'func play(\n        rate: Float,');
const waitForPlaying = section(engine, 'private func waitForPlaying(', 'private func startWait(');
const startWait = section(engine, 'private func startWait(', 'private func endWait(');
const prepareGiveUp = section(enginePrepare, ') { [weak self] verdict, watch in', 'loadWait = wait');
assert(
  enginePrepare.includes('let wait = startWait(\n            totalTimeoutMs: prepareTimeoutMs(),\n            readings: { loadItem.map(Self.loadProgress(of:)) }') &&
    enginePrepare.includes('loadItem = item\n                wait.noteProgress()') &&
    (enginePrepare.match(/wait\.noteProgress\(\)/g) || []).length === 2 &&
    enginePrepare.includes('self.seek(to: position, watched: false)') &&
    prepareGiveUp.includes('settle(.failure(NSError(') &&
    prepareGiveUp.includes('self.pendingAsset?.cancelLoading()') &&
    prepareGiveUp.includes('self.player.cancelPendingPrerolls()') &&
    prepareGiveUp.includes('loadItem?.cancelPendingSeeks()') &&
    (enginePrepare.match(/guard let self = self, self\.generation == currentGeneration, !settled else \{ return \}/g) || []).length === 4 &&
    // The settle step and the preroll callback both refuse a second result after a give-up.
    (enginePrepare.match(/guard !settled else \{ return \}/g) || []).length === 2 &&
    engineSeek.includes('seekWait = startWait(\n                totalTimeoutMs: prepareTimeoutMs(),') &&
    engineSeek.includes('if watched, completion != nil {') &&
    // Every seek is watched unless it runs inside the load's own wait.
    engine.includes('func seek(to position: Double, watched: Bool = true, completion: ((Result<Void, Error>) -> Void)? = nil) {') &&
    (engine.match(/watched: false\)/g) || []).length === 1 &&
    enginePrepare.includes('self.seek(to: position, watched: false)') &&
    orchestrator.includes('seekOperation: @escaping SeekOperation = { engine, position, completion in\n            engine.seek(to: position, completion: completion)\n        },') &&
    !orchestrator.includes('watched:') &&
    waitForPlaying.includes('weak var observation: NSKeyValueObservation?') &&
    // A failed start pauses the engine wherever playback starts (play and a load that plays).
    orchestrator.includes('self.playWhenReady = false\n                                            // As after a failed play(): audio must not start by itself later.\n                                            self.activeEngine.pause()') &&
    engineSeek.includes('readings: { item.map(Self.loadProgress(of:)) ?? [0, 0] }') &&
    section(engineSeek, ') { [weak self] verdict, watch in', 'player.seek(to: time').includes('item?.cancelPendingSeeks()\n                // The player goes to an error state: audio must not resume by itself when the\n                // data arrives later, as after a failed play start.\n                self.player.pause()') &&
    // Every wait ends (stops and leaves the engine) when it settles, gives up or is reset.
    enginePrepare.includes('if let loadWait = loadWait { self.endWait(loadWait) }\n            loadWait = nil\n            settleCrossfadeLoad(result, stopLoading: { self.abandonLoad() }, complete: completion)') &&
    engineSeek.includes('if let seekWait = seekWait { endWait(seekWait) }\n            seekWait = nil\n            settleCrossfadeSeek(\n                result,\n                isLatest: seeks.isLatest(seekNumber),\n                stopLoading: { self.abandonLoad() },\n                complete: { completion?($0) }\n            )') &&
    waitForPlaying.includes('if let playWait = playWait { self.endWait(playWait) }\n            playWait = nil\n            completion(result)') &&
    startWait.includes('if let self = self, let driver = driver { self.endWait(driver) }\n            onGiveUp(verdict, watch)') &&
    section(engine, 'private func endWait(_ driver: StallWaitDriver) {', '\n    }').includes('driver.cancel()\n        waits.removeAll { $0 === driver }') &&
    section(engine, 'func reset() {', 'private func preroll(').includes('waits.forEach { $0.cancel() }\n        waits.removeAll()') &&
    // Each play-start wait owns its observation; a reset ends them all.
    waitForPlaying.includes('timeControlObservations.append(observed)') &&
    waitForPlaying.includes('self.timeControlObservations.removeAll { $0 === observation }') &&
    !engine.includes('timeControlObservation =') &&
    section(engine, 'func reset() {', 'private func preroll(').includes('timeControlObservations.forEach { $0.invalidate() }') &&
    section(engineSeek, ') { [weak self] verdict, watch in', 'player.seek(to: time').includes('finish(.failure(NSError(') &&
    waitForPlaying.includes('playWait = startWait(\n            totalTimeoutMs: timeoutMs,') &&
    waitForPlaying.includes('return (self.player.currentItem.map(Self.loadProgress(of:)) ?? [0, 0]) + [self.currentTime]') &&
    waitForPlaying.indexOf(') { [weak self] verdict, watch in') > 0 &&
    waitForPlaying.slice(waitForPlaying.indexOf(') { [weak self] verdict, watch in')).includes('finish(.failure(NSError(') &&
    startWait.includes('stallTimeoutMs: stallTimeoutMs(),\n            totalTimeoutMs: totalTimeoutMs,') &&
    startWait.includes('waits.append(created)') &&
    startWait.includes('created.start()') &&
    section(engine, 'func reset() {', 'private func preroll(').includes('waits.forEach { $0.cancel() }') &&
    !engine.includes('asyncAfter') &&
    !engine.includes('DispatchWorkItem') &&
    engine.includes('let loadedSeconds = item.loadedTimeRanges.reduce(0.0) { total, value in') &&
    engine.includes('total + Double(max(0, event.numberOfBytesTransferred))') &&
    engine.includes('var stallTimeoutMs: () -> Int = { stallTimeoutDefaultMs }') &&
    engine.includes('waitForPlaying(generation: currentGeneration, timeoutMs: playStartTimeoutMs(), completion: completion)') &&
    orchestrator.includes('engineA.stallTimeoutMs = stallTimeoutMs') &&
    orchestrator.includes('engineB.stallTimeoutMs = stallTimeoutMs'),
  'iOS engine load, seek and play start must wait on StallWaitDriver with stallTimeoutMs and their limits.'
);
const driverSource = section(facade, 'final class StallWaitDriver {', 'func backendStepTimeout(');
const transactionTests = read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift');
assert(
  driverSource.includes('let verdict = readings?().map { watch.check(at: at, readings: $0) } ?? watch.capVerdict(at: at)') &&
    // A wait releases its closures (the caller's completion, the engine) when it ends.
    section(driverSource, 'func cancel() {', 'func noteProgress()').includes('readings = nil') &&
    section(driverSource, 'func cancel() {', 'func noteProgress()').includes('onGiveUp = nil') &&
    section(driverSource, 'private func tick() {', '\n    }\n}').includes('onGiveUp = nil\n        giveUp?(verdict, watch)') &&
    facade.includes('let stallCheckIntervalMs = 250') &&
    standardBackend.includes('deinit {\n            wait?.cancel()\n        }') &&
    transactionTests.includes('func testWaitDriverReleasesItsClosuresWhenCancelledAndWhenItGivesUp()') &&
    driverSource.includes('guard isActive else { return }') &&
    ['testWaitDriverKeepsASlowButProgressingWaitUntilItsCap', 'testWaitDriverFailsAStalledWaitAtTheStallTimeout',
      'testWaitDriverWithoutASignalIsBoundOnlyByItsCapAndAStageRestartsTheStallClock',
      'testWaitDriverReschedulesUntilCancelledAndThenNeverGivesUp', 'testCrossfadeIncomingStallReadsTheGraceItIsGiven']
      .every((name) => transactionTests.includes(`func ${name}()`)),
  'The iOS wait driver must stay in the tested core with its tests.'
);
// The crossfade fallback grace is the app's incomingStallGraceMs, never a number.
assert(
  orchestrator.includes('var incomingStallGraceMs: () -> Int = { incomingStallGraceDefaultMs }') &&
    orchestrator.includes('if crossfadeIncomingStalled(\n            elapsedMs: context.elapsedMs,\n            graceMs: incomingStallGraceMs(),') &&
    !/elapsedMs >= \d/.test(orchestrator) &&
    facade.includes('let incomingStallGraceDefaultMs = 2000') &&
    player.includes('private let incomingStallGrace = TimeoutSetting(optionKey: "incomingStallGraceMs", defaultMs: incomingStallGraceDefaultMs)') &&
    player.includes('stallTimeout, incomingStallGrace, backendSwitchPositionTolerance]') &&
    section(player, 'case .pingPong:', 'return PingPongPlaybackBackend(').includes('orchestrator.incomingStallGraceMs = { [weak self] in self?.incomingStallGrace.milliseconds ?? incomingStallGraceDefaultMs }') &&
    section(player, 'public func setupPlayer(', 'installPlaybackBackendFacade(initialKind:').includes('playbackOrchestrator.incomingStallGraceMs = { [weak self] in self?.incomingStallGrace.milliseconds ?? incomingStallGraceDefaultMs }') &&
    ['src/interfaces/PlayerOptions.ts', 'src/interfaces/UpdateOptions.ts'].every((f) => read(f).includes('incomingStallGraceMs?: number;')) &&
    ['docs/docs/api/objects/player-options.md', 'docs/docs/api/objects/update-options.md'].every((f) => read(f).includes('| `incomingStallGraceMs` |')),
  'iOS crossfade fallback must read incomingStallGraceMs.'
);
// Parser, stored setting and step formula live in PlaybackBackend.swift, tested by RNTrackPlayerTests.
assert(
  facade.includes('let prepareTimeoutDefaultMs = 60000') &&
    facade.includes('final class TimeoutSetting') &&
    facade.includes('let playStartTimeoutDefaultMs = 60000') &&
    facade.includes('let standardReadyTimeoutDefaultMs = 60000') &&
    facade.includes('let standardSeekTimeoutDefaultMs = 60000') &&
    facade.includes('let stallTimeoutDefaultMs = 10000') &&
    facade.includes('struct StallWatch') &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('testStallWatchKeepsASlowButProgressingLoadPastTheStallTimeout') &&
    facade.includes('func backendStepTimeout(loadTimeoutMs: Int, playStartTimeoutMs: Int) -> TimeInterval') &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('testPrepareTimeoutSettingKeepsTheDefaultUntilTheAppGivesAValidValue'),
  'iOS prepareTimeoutMs parsing, setting and step formula must stay in the tested core.'
);
assert(
  orchestrator.includes('engineA.prepareTimeoutMs = prepareTimeoutMs') &&
    orchestrator.includes('engineB.prepareTimeoutMs = prepareTimeoutMs'),
  'iOS orchestrator must give its load timeout provider to both engines.'
);
const awaitResult = section(pingPongBackend, 'private func awaitResult(', 'throw playbackBackendError(');
assert(
  !awaitResult.includes('timeout: TimeInterval') &&
    awaitResult.includes('let timeout = backendStepTimeout(\n') &&
    awaitResult.includes('loadTimeoutMs: orchestrator.prepareTimeoutMs(),') &&
    awaitResult.includes('playStartTimeoutMs: orchestrator.playStartTimeoutMs()') &&
    !/awaitResult\(timeout/.test(pingPongBackend) &&
    awaitResult.includes('guard semaphore.wait(timeout: .now() + timeout) == .success else {'),
  'iOS ping-pong backend steps must wait backendStepTimeout (load or play-start timeout plus a margin, at least 10 s), not a fixed 10 s.'
);
const pingPongFactory = section(player, 'case .pingPong:', 'return PingPongPlaybackBackend(');
const setupPlayerTimeout = section(player, 'public func setupPlayer(', 'installPlaybackBackendFacade(initialKind:');
assert(
  player.includes('private let prepareTimeout = TimeoutSetting(optionKey: "prepareTimeoutMs", defaultMs: prepareTimeoutDefaultMs)') &&
    section(player, 'private func applyTimeouts(', '@objc(updateOptions:').includes('for setting in [prepareTimeout, playStartTimeout, standardReadyTimeout, standardSeekTimeout, stallTimeout, incomingStallGrace, backendSwitchPositionTolerance]') &&
    player.includes('private let stallTimeout = TimeoutSetting(optionKey: "stallTimeoutMs", defaultMs: stallTimeoutDefaultMs)') &&
    pingPongFactory.includes('orchestrator.stallTimeoutMs = { [weak self] in self?.stallTimeout.milliseconds ?? stallTimeoutDefaultMs }') &&
    setupPlayerTimeout.includes('playbackOrchestrator.stallTimeoutMs = { [weak self] in self?.stallTimeout.milliseconds ?? stallTimeoutDefaultMs }') &&
    player.includes('stallTimeoutMs: { [weak self] in self?.stallTimeout.milliseconds ?? stallTimeoutDefaultMs },') &&
    section(player, 'private func applyTimeouts(', '@objc(updateOptions:').includes('switch setting.apply(options) {') &&
    pingPongFactory.includes('orchestrator.prepareTimeoutMs = { [weak self] in self?.prepareTimeout.milliseconds ?? prepareTimeoutDefaultMs }') &&
    setupPlayerTimeout.includes('applyTimeouts(config)') &&
    setupPlayerTimeout.includes('playbackOrchestrator.prepareTimeoutMs = { [weak self] in self?.prepareTimeout.milliseconds ?? prepareTimeoutDefaultMs }') &&
    section(player, 'public func update(options:', 'var capabilitiesStr').includes('applyTimeouts(options)'),
  'iOS setupPlayer and updateOptions must take prepareTimeoutMs, and every orchestrator must read it.'
);
assert(
  playerOptionsDocs.includes('| `prepareTimeoutMs` |') && playerOptions.includes('prepareTimeoutMs?: number;') &&
    read('docs/docs/api/objects/update-options.md').includes('| `prepareTimeoutMs` |') &&
    read('src/interfaces/UpdateOptions.ts').includes('prepareTimeoutMs?: number;'),
  'prepareTimeoutMs must be typed and documented.'
);

// The player's other waits (play start, standard readiness, standard seek) read the app's settings.
const standardBackend2 = read('ios/RNTrackPlayer/StandardPlaybackBackend.swift');
assert(
  engine.includes('waitForPlaying(generation: currentGeneration, timeoutMs: playStartTimeoutMs(), completion: completion)') &&
    !/timeoutMs: Int = \d/.test(engine) &&
    orchestrator.includes('var prepareTimeoutMs: () -> Int = { prepareTimeoutDefaultMs } {\n        didSet {\n            engineA.prepareTimeoutMs = prepareTimeoutMs\n            engineB.prepareTimeoutMs = prepareTimeoutMs\n        }\n    }') &&
    orchestrator.includes('var playStartTimeoutMs: () -> Int = { playStartTimeoutDefaultMs } {\n        didSet {\n            engineA.playStartTimeoutMs = playStartTimeoutMs\n            engineB.playStartTimeoutMs = playStartTimeoutMs\n        }\n    }') &&
    orchestrator.includes('engineA.playStartTimeoutMs = playStartTimeoutMs') &&
    orchestrator.includes('engineB.playStartTimeoutMs = playStartTimeoutMs') &&
    player.includes('orchestrator.playStartTimeoutMs = { [weak self] in self?.playStartTimeout.milliseconds ?? playStartTimeoutDefaultMs }') &&
    player.includes('private let playStartTimeout = TimeoutSetting(optionKey: "playStartTimeoutMs", defaultMs: playStartTimeoutDefaultMs)') &&
    player.includes('private let standardReadyTimeout = TimeoutSetting(optionKey: "standardReadyTimeoutMs", defaultMs: standardReadyTimeoutDefaultMs)') &&
    player.includes('private let standardSeekTimeout = TimeoutSetting(optionKey: "standardSeekTimeoutMs", defaultMs: standardSeekTimeoutDefaultMs)') &&
    player.includes('readinessTimeoutMs: { [weak self] in self?.standardReadyTimeout.milliseconds ?? standardReadyTimeoutDefaultMs }') &&
    player.includes('seekTimeoutMs: { [weak self] in self?.standardSeekTimeout.milliseconds ?? standardSeekTimeoutDefaultMs }') &&
    standardBackend2.includes('let stallMs = stallTimeoutMs()') &&
    standardBackend2.includes('let wait = StallWaitDriver(\n            stallTimeoutMs: stallMs,\n            totalTimeoutMs: seekTimeoutMs(),') &&
    standardBackend2.includes('guard let self = self, let request = request, request.issued else { return nil }') &&
    standardBackend2.includes('return [self.player.bufferedPosition]') &&
    standardBackend2.includes('request.issued = true\n            request.wait?.noteProgress()\n            nativeSeeks.issued(request, at: request.position)\n            player.seek(to: request.position)') &&
    standardBackend2.includes('request.wait = wait\n        // A newer seek ends the older ones at once (standard_seek_cancelled), as on Android.') &&
    standardBackend2.includes('        pendingSeeks.append(request)\n        wait.start()\n        pumpSeeks()') &&
    section(standardBackend2, '// A newer seek ends the older ones at once', 'pendingSeeks.append(request)').includes('issued.finish(.failure(seekError("standard_seek_cancelled", "A newer seek replaced this one.")))') &&
    section(standardBackend2, '// A newer seek ends the older ones at once', 'pendingSeeks.append(request)').includes('superseded.forEach {') &&
    standardBackend2.includes('onMain { enqueueSeek(to: player.currentTime + offset, completion: completion) }') &&
    section(standardBackend2, 'func finish(_ result: Result<Void, Error>) {', 'private var pendingSeeks').includes('wait?.cancel()') &&
    !standardBackend2.includes('DispatchWorkItem { [weak self, weak request]') &&
    !/asyncAfter\(deadline: \.now\(\) \+ [\d.]+, execute: timeout\)/.test(standardBackend2) &&
    !/timeout: TimeInterval = \d/.test(standardBackend2) &&
    standardBackend2.includes('timeoutMs: readinessTimeoutMs(),\n                positionToleranceMs: positionToleranceMs(),\n                stallTimeoutMs: stallTimeoutMs()') &&
    standardBackend2.includes('        timeoutMs: timeoutMs,\n        stallTimeoutMs: stallTimeoutMs,\n        positionToleranceMs: positionToleranceMs,\n        observe: {') &&
    standardBackend2.includes('buffered: player.bufferedPosition') &&
    standardBackend2.includes('self.seekTimeoutMs = seekTimeoutMs') &&
    standardBackend2.includes('self.stallTimeoutMs = stallTimeoutMs') &&
    standardBackend2.includes('var watch = StallWatch(stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: timeoutMs, startedAt: now())') &&
    standardBackend2.includes('let verdict = watch.check(at: now(), readings: [observation.buffered])') &&
    !standardBackend2.includes('Date().addingTimeInterval') &&
    standardBackend2.includes('stallTimeoutMs: @escaping () -> Int,') &&
    standardBackend2.includes('readinessTimeoutMs: @escaping () -> Int,') &&
    standardBackend2.includes('seekTimeoutMs: @escaping () -> Int,') &&
    !/\.milliseconds\(\d+\)/.test(engine.slice(engine.indexOf('private func waitForPlaying('))) &&
    setupPlayerTimeout.includes('playbackOrchestrator.playStartTimeoutMs = { [weak self] in self?.playStartTimeout.milliseconds ?? playStartTimeoutDefaultMs }') &&
    ['playStartTimeoutMs', 'standardReadyTimeoutMs', 'standardSeekTimeoutMs', 'stallTimeoutMs'].every((option) =>
      playerOptions.includes(`${option}?: number;`) &&
        read('src/interfaces/UpdateOptions.ts').includes(`${option}?: number;`) &&
        playerOptionsDocs.includes(`| \`${option}\` |`) &&
        read('docs/docs/api/objects/update-options.md').includes(`| \`${option}\` |`)),
  'iOS play-start, standard readiness and standard seek waits must read the app\'s settings, not fixed numbers.'
);

// Calls, other apps' audio and headphones: one policy for both backends (DJE-204/205/206).
const interruptionSection = section(player, 'public func handleInterruption(type: InterruptionType) {', '// MARK: - Bridged Methods');
const applyInterruption = section(player, 'private func applyInterruption(', 'private func checkpointOrchestratorForSystemEvent(');
const routeChange = section(player, '@objc private func handleAudioSessionRouteChange(', 'private func applyInterruption(');
const commandBody = (start, end) => section(player, start, end);
assert(
  facade.includes('final class InterruptionPolicy {') &&
    // Thread-safe and created with the module, not lazily.
    section(facade, 'final class InterruptionPolicy {', 'final class LockedValue<Value> {').includes('private let lock = NSLock()') &&
    player.includes('private let interruptionPolicy: InterruptionPolicy') &&
    player.includes('interruptionPolicy = InterruptionPolicy(autoResume: { autoResume.value })\n        super.init()') &&
    player.includes('self.shouldResumePlaybackAfterInterruptionEnds.value = autoHandleInterruptions') &&
    interruptionSection.includes('applyInterruption { policy, isPlaying in policy.began(isPlaying: isPlaying) }') &&
    interruptionSection.includes('applyInterruption { policy, _ in policy.ended(shouldResume: shouldResume) }') &&
    routeChange.includes('== .oldDeviceUnavailable else { return }') &&
    routeChange.includes('applyInterruption { policy, isPlaying in policy.noisy(isPlaying: isPlaying) }') &&
    // Off the main thread and the module's queue: only the facade published at setup is read.
    !/hasInitialized|playbackBackendFacade/.test(routeChange + applyInterruption) &&
    applyInterruption.includes('guard let facade = interruptionFacade.value else { return }') &&
    player.includes('hasInitialized = true\n        interruptionFacade.value = playbackBackendFacade') &&
    // Both backends, no guard on the kind before the decision.
    applyInterruption.includes('let (action, duck) = decide(self.interruptionPolicy, backend.interruptionIsPlaying)') &&
    !/guard[^\n]*kind|kind (==|!=) \.(standard|pingPong)[^\n]*(return|\{\s*\n\s*return)/.test(applyInterruption.slice(0, applyInterruption.indexOf('let (action, duck) = decide('))) &&
    applyInterruption.includes('case .pause: backend.pause()') &&
    applyInterruption.includes('backend.play { result in') &&
    applyInterruption.includes('completion(.success(duck))') &&
    applyInterruption.includes('"permanent": duck.permanent') &&
    // Was it playing: the module's last request, not SwiftAudioEx's own pause at the interruption.
    // One rule on all four backends: asked to play, with an active track not ended/failed/stopped.
    facade.includes('let interruptionFinishedStates: Set<String> = ["none", "ended", "error", "stopped"]') &&
    facade.includes('return playWhenReady && !interruptionFinishedStates.contains(stateRawValue)') &&
    standardBackend.includes('return onMain {\n            interruptionCountsAsPlaying(playWhenReady: requested.playWhenReady, stateRawValue: playbackState.rawValue)') &&
    pingPongBackend.includes('interruptionCountsAsPlaying(playWhenReady: orchestrator.playWhenReady, stateRawValue: orchestrator.playbackState.rawValue)') &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('func isPlaying() -> Bool { interruptionCountsAsPlaying(playWhenReady: playing, stateRawValue: state) }') &&
    section(standardBackend, '    func play() throws {', '    func seek(to position: Double) throws {').includes('requested.request(true)\n            player.play()') &&
    section(standardBackend, '    func pause() {', '    func seek(to position: Double) throws {').includes('requested.request(false)\n            player.pause()') &&
    section(standardBackend, '    func stop() {', '    func setPlayWhenReady(').includes('requested.request(false)\n            player.stop()') &&
    section(standardBackend, '    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {', '    func seek(to position: Double, completion').includes('player.playWhenReady = value\n            requested.request(value)') &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('func testAnInterruptionResumesWhenTheSDKPausedThePlayerBeforeItWasRead()') &&
    // reset runs from deinit too: its operation holds the policy, not the module.
    section(player, 'public func reset(resolve:', 'public func play(resolve:').includes('withActivePlaybackBackendSerialized({ [interruptionPolicy] backend in') &&
    // Every user command, inside its admitted operation (ordered with the interruption events).
    [['public func play(resolve:', 'public func pause(resolve:'],
      ['public func pause(resolve:', 'public func setPlayWhenReady(playWhenReady:'],
      ['public func setPlayWhenReady(playWhenReady:', 'public func getPlayWhenReady('],
      ['public func stop(resolve:', 'public func seekTo(time:'],
      ['public func reset(resolve:', 'public func play(resolve:']].every(([start, end]) => {
      const body = commandBody(start, end);
      const call = body.search(/(self\.)?interruptionPolicy\.user(Pause|Stop)\(\)|self\.userPlayIsAllowed\(backend\)/);
      return call >= 0 && body.indexOf('withActivePlaybackBackend') < call;
    }) &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('scripts/fixtures/interruption-scenarios.json'),
  'iOS interruptions and unplugging must go through InterruptionPolicy on both backends.'
);

// A play start that gives up: the same rejection code and playback-error event as Android; a
// crossfade whose incoming song does not start rejects with crossfade_start_failed, as on Android.
assert(
  engine.includes('"code": "crossfade_play_start_timeout"') &&
    engine.includes('"code": "crossfade_engine_error"') &&
    // Where play, a load that plays, skip and a recovery start playback (not the backend switch's
    // activation, which Android does not wait for either).
    section(orchestrator, 'private func loadIndex(', 'private func ').includes('self.reportPlaybackStartFailure(error)') &&
    (orchestrator.match(/self\.reportPlaybackStartFailure\(error\)/g) || []).length === 1 &&
    // The codes sent as they are (sharedRejectionCodes, tested by
    // testTheBridgeSendsTheSameRejectionCodesAsAndroid), read by every command's rejection.
    player.includes('return bridgeRejectionCode((error as NSError).userInfo["code"] as? String, fallback: fallback)') &&
    !player.includes('static let sharedRejectionCodes') &&
    (player.match(/reject\(self\.rejectionCode\(error, "seek_failed"\), "Unable to seek\.", error\)/g) || []).length === 2 &&
    orchestrator.includes('completion(.failure(self.makeError("crossfade_start_failed", error.localizedDescription)))') &&
    player.includes('emit(event: EventType.PlaybackError, body: ["code": code, "message": message])') &&
    player.includes('reject(self.rejectionCode(error, "playback_failed"), "Unable to start playback.", error)') &&
    player.includes('reject(self.rejectionCode(error, "crossfade_failed"), "Unable to complete crossfade.", error)'),
  'iOS play-start failures must reject and report like Android.'
);

// Third review: exact pins for what the XCTest target cannot reach (StandardPlaybackBackend,
// the engine, the ping-pong backend and the module are not compiled into it).
assert(
  // A newer seek ends every queued one and the issued one; each native callback resolves only
  // the seek it completes (NativeSeekLedger, tested).
  standardBackend.includes('        let superseded = pendingSeeks\n        pendingSeeks.removeAll()\n        superseded.forEach {\n            $0.finish(.failure(seekError("standard_seek_cancelled", "A newer seek replaced this one.")))\n        }') &&
    standardBackend.includes('        if let issued = issuedSeek {\n            // Its native callback still comes (NativeSeekLedger) but resolves nothing.\n            issuedSeek = nil\n            nativeSeeks.release(issued)\n            issued.finish(.failure(seekError("standard_seek_cancelled", "A newer seek replaced this one.")))\n        }') &&
    standardBackend.includes('            nativeSeeks.issued(request, at: request.position)\n            player.seek(to: request.position)') &&
    standardBackend.includes('        guard let request = nativeSeeks.completed(at: position) else { return }\n        let wasIssued = issuedSeek === request\n        if wasIssued { issuedSeek = nil }') &&
    !standardBackend.includes('request.position == position') &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('func testANativeSeekCallbackResolvesOnlyTheSeekItCompletes()') &&
    // The module's request follows every playWhenReady it sets (restore, a cancelled handoff,
    // the activation after a switch).
    section(standardBackend, '    func restore(_ snapshot: PlaybackBackendSnapshot) throws {', '    func ').includes('            player.playWhenReady = false\n            requested.request(false)\n            player.pause()') &&
    section(standardBackend, '    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws {', '    func ').includes('            player.playWhenReady = snapshot.playWhenReady\n            requested.request(snapshot.playWhenReady)') &&
    section(standardBackend, '    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {', '    func ').includes('        player.playWhenReady = !idleWithoutActiveTrack && snapshot.playWhenReady\n        requested.request(player.playWhenReady)') &&
    // The crossfade engine gives up at once with crossfade_engine_error when the player fails.
    engine.includes('                if let failure = self.player.currentItem?.error ?? self.player.error,\n                   self.player.currentItem?.status == .failed || self.player.status == .failed {\n                    DispatchQueue.main.async {\n                        guard self.generation == generation, !didComplete else { return }\n                        self.state = .failed\n                        finish(.failure(NSError(') &&
    // The ping-pong backend reads the orchestrator on main.
    pingPongBackend.includes('    var interruptionIsPlaying: Bool {\n        return (try? performPlaybackBackendOnMainSync {\n            interruptionCountsAsPlaying(playWhenReady: orchestrator.playWhenReady, stateRawValue: orchestrator.playbackState.rawValue)\n        }) ?? false\n    }') &&
    // Only the authoritative orchestrator reports a failed play start.
    player.includes('    func playbackOrchestrator(_ orchestrator: IOSPlaybackOrchestrator, didFailPlaybackStart code: String, message: String) {\n        guard playbackBackendAuthority.isAuthoritative(.pingPong, identity: orchestrator),\n              orchestrator === playbackOrchestrator else { return }\n        // The same playback-error as Android\'s for a play start that gives up.\n        emit(event: EventType.PlaybackError, body: ["code": code, "message": message])') &&
    // The interruption resume is not awaited: remote-duck goes out at once, a user pause is not
    // queued behind it (as on Android).
    section(player, 'private func applyInterruption(', 'private func checkpointOrchestratorForSystemEvent(').includes('                backend.play { result in\n                    if case .failure(let error) = result {') &&
    !/try backend\.play\(\)/.test(section(player, 'private func applyInterruption(', 'private func checkpointOrchestratorForSystemEvent(')) &&
    // backendSwitchPositionToleranceMs, the same option as Android, on both backends.
    standardBackend.includes('abs(observation.position - restoredPosition) <= Double(positionToleranceMs) / 1000 {') &&
    standardBackend.includes('abs(player.currentTime - max(0, snapshot.position)) > Double(positionToleranceMs()) / 1000 {') &&
    pingPongBackend.includes('abs(orchestrator.currentTime - snapshot.position) > Double(positionToleranceMs()) / 1000 {') &&
    !/> 0\.75|<= 0\.75/.test(standardBackend + pingPongBackend) &&
    player.includes('optionKey: "backendSwitchPositionToleranceMs",') &&
    player.includes('stallTimeout, incomingStallGrace, backendSwitchPositionTolerance] {') &&
    (player.match(/self\?\.backendSwitchPositionTolerance\.milliseconds \?\? backendSwitchPositionToleranceDefaultMs/g) || []).length === 2,
  'iOS third-review fixes must stay in place.'
);

// Decision B: a play the system refuses does not start, on both iOS backends.
const userPlayAllowed = section(player, 'private func userPlayIsAllowed(', '@objc(setupPlayer:');
assert(
  userPlayAllowed.includes('guard interruptionPolicy.userPlay(activate: { activateAudioSessionForPlayback() }) == .play else {\n            backend.pause()\n            return false') &&
    !player.includes('isInterrupted') &&
    section(player, 'private func activateAudioSessionForPlayback()', 'private func userPlayIsAllowed(').includes('        do {\n            try audioSessionController.activateSession()\n        } catch {\n            activated = false\n        }') &&
    section(player, 'private func activateAudioSessionForPlayback()', 'private func userPlayIsAllowed(').includes('        return activated\n') &&
    section(player, 'public func play(resolve:', 'public func pause(resolve:').includes('            guard self.userPlayIsAllowed(backend) else {\n                completion(.failure(audioFocusRefusedError()))\n                return\n            }\n            backend.play(completion: completion)') &&
    section(player, 'public func setPlayWhenReady(playWhenReady:', 'public func getPlayWhenReady(').includes('            if playWhenReady {\n                guard self.userPlayIsAllowed(backend) else {\n                    completion(.failure(audioFocusRefusedError()))') &&
    section(player, 'private func applyInterruption(', 'private func checkpointOrchestratorForSystemEvent(').includes('            switch self.interruptionPolicy.step(for: action, activate: { self.activateAudioSessionForPlayback() }) {\n            case .pause: backend.pause()\n            case .resumeRefused:\n                let error = audioFocusRefusedError()\n                DispatchQueue.main.async {\n                    self.emit(event: EventType.PlaybackError, body: [\n                        "code": audioFocusRefusedCode,') &&
    // Thirteenth review: every command that loads or moves the active track is a user play
    // when it starts the audio (commandStartsPlayback, read on main on both backends).
    section(player, 'private func runStartingCommand<Value>(', '@objc(setupPlayer:').includes('let allowed = !backend.startingCommandPlays || userPlayIsAllowed(backend)\n        command { result in completion(applyingPlayRefusal(refused: !allowed, to: result)) }') &&
    [['public func load(', 'public func remove(tracks'],
      ['public func skip(', 'public func skipToNext('],
      ['public func skipToNext(', 'public func skipToPrevious('],
      ['public func skipToPrevious(', 'public func reset(resolve:'],
      ['public func seekTo(time:', 'public func seekBy(offset:'],
      ['public func seekBy(offset:', 'public func retry(resolve:'],
      ['public func retry(resolve:', 'public func setRepeatMode(']].every(([start, end]) =>
      section(player, start, end).includes('self.runStartingCommand(backend, completion: completion)')) &&
    (player.match(/backend\.(load\(track|skip\(to: index|skipToNext\(initialTime|skipToPrevious\(initialTime|seek\(to: time|seek\(by: offset|retry\(\))/g) || []).length === 7 &&
    section(player, 'public func retry(resolve:', 'public func setRepeatMode(').includes('reject(self.rejectionCode(error, "retry_failed")') &&
    standardBackend.includes('    var startingCommandPlays: Bool {\n        return onMain {\n            commandStartsPlayback(playWhenReady: publicPlayWhenReady, stateRawValue: playbackState.rawValue)') &&
    pingPongBackend.includes('    var startingCommandPlays: Bool {\n        return (try? performPlaybackBackendOnMainSync {\n            commandStartsPlayback(playWhenReady: orchestrator.playWhenReady, stateRawValue: orchestrator.playbackState.rawValue)') &&
    facade.includes('    "cancelled", audioFocusRefusedCode,\n]') &&
    facade.includes('let audioFocusRefusedCode = "audio_focus_refused"') &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('func testAPlayIsDecidedFromTheActivationAlone()') &&
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('func testAResumeNeedsTheSessionAndNothingElseActivatesIt()'),
  'iOS must refuse a play the system does not give the audio to (audio_focus_refused) on both backends.'
);

// The seek watch can be skipped only by the load's own seek, anywhere in the module.
{
  const fs = require('fs');
  const path = require('path');
  const dir = path.join(__dirname, '..', 'ios', 'RNTrackPlayer');
  const unwatched = fs.readdirSync(dir).filter((f) => f.endsWith('.swift')).reduce((count, f) => {
    const code = fs.readFileSync(path.join(dir, f), 'utf8').split('\n').filter((line) => !line.trim().startsWith('///') && !line.trim().startsWith('//')).join('\n');
    return count + (code.match(/watched:\s*false/g) || []).length;
  }, 0);
  assert(unwatched === 1, 'Only the load\'s own seek may pass watched: false in ios/RNTrackPlayer (found ' + unwatched + ').');
}

// The load started when a track ends reports its failure as a playback-error (no command waits
// for it), with the same fields as Android's orchestrator.
{
  const observeEnd = section(orchestrator, 'private func observeEnd() {', 'private func stabilizeCancelledOperation() {');
  const delegateImpl = section(player, 'func playbackOrchestrator(_ orchestrator: IOSPlaybackOrchestrator, didFailToAdvance failure: PlaybackAdvanceFailure) {', '\n    }\n');
  assert(
    observeEnd.includes('advanceAfterTrackEnd(\n                    skip: { completion in self.skip(to: next, initialTime: 0, completion: completion) },') &&
      observeEnd.includes('playerInError: { [weak self] in self?.state == .error },') &&
      observeEnd.includes('self.delegate?.playbackOrchestrator(self, didFailToAdvance: failure)') &&
      !observeEnd.includes('{ _ in }') &&
      delegateImpl.includes('isAuthoritative(.pingPong, identity: orchestrator)') &&
      delegateImpl.includes('emit(event: EventType.PlaybackError, body: failure.eventBody)') &&
      facade.includes('struct PlaybackAdvanceFailure: Equatable {'),
    'A failed iOS natural advance must emit playback-error with its code and message.'
  );
}

// A load or seek an engine gives up on stops loading (the item leaves the player), as Android's
// engine stops its player.
{
  const prepare = section(engine, 'func prepare(track: Track, position: Double, completion:', 'asset.loadValuesAsynchronously(');
  const seek = section(engine, 'func seek(to position: Double, watched: Bool = true,', 'player.seek(to: time,');
  assert(
    engine.includes('private func abandonLoad() {') &&
      section(engine, 'private func abandonLoad() {', '\n    }\n').includes('stopLoading(player)') &&
      section(facade, 'func stopLoading(_ player: ItemLoadingPlayer) {', '\n}\n').includes('player.replaceCurrentItem(with: nil)') &&
      prepare.includes('settleCrossfadeLoad(result, stopLoading: { self.abandonLoad() }, complete: completion)') &&
      section(facade, 'func settleCrossfadeLoad(', '\n}\n').includes('if case .failure = result { stopLoading() }') &&
      section(engine, 'private func abandonLoad() {', '\n    }\n').includes('pendingAsset?.cancelLoading()') &&
      prepare.includes('"code": "crossfade_prepare_timeout"') &&
      seek.includes('let seekNumber = seeks.begin()') &&
      section(facade, 'func settleCrossfadeSeek(', '\n}\n').includes('if case .failure = result, isLatest { stopLoading() }') &&
      seek.includes('"code": "crossfade_seek_timeout"'),
    'An iOS engine that gives up on a load or seek must remove the item (stop loading) and name the code.'
  );
}

// A track becomes the active one once it loaded (loadIndex's success branches only): a load that
// fails or is cancelled leaves the previous track active, and play reloads that one. Android
// aligns on it (startTrackAt). Chosen alignment for the parity docs.
{
  const loadIndex = section(orchestrator, 'private func loadIndex(', 'private func startCrossfade(');
  const beforeSuccess = loadIndex.slice(0, loadIndex.indexOf('case .success:'));
  const failure = loadIndex.slice(loadIndex.lastIndexOf('case .failure(let error):'));
  assert(
    !beforeSuccess.includes('currentIndex = index') &&
      !beforeSuccess.includes('didChangeActiveTrack') &&
      (loadIndex.match(/self\.currentIndex = index/g) || []).length === 2 &&
      !failure.includes('currentIndex') &&
      failure.includes('self.state = .error') &&
      section(orchestrator, 'func load(track: Track, completion:', 'func play(').includes('replaceQueue([track], currentIndex: -1)'),
    'iOS must commit the active track only once its load succeeded.'
  );
}

// After a failed seek the position is its target (the item was dropped), as on Android.
assert(
  section(orchestrator, 'func seek(to position: Double, completion:', 'func seek(by offset: Double')
    .includes('self.checkpoint(position: position, reason: "seek_failed")\n                    self.state = .error') &&
    section(orchestrator, 'private func observeEnd() {', 'if total > 0').includes('state == .playingSingle || state == .preloadingNext'),
  'An iOS failed seek must report its target; the end observer must act while preloading.'
);

// The standard player's loads follow the stall rule, as the crossfade path and Android's standard
// player: a load with no progress for stallTimeoutMs (its item's access-log bytes, its item
// appearing, buffered media) or over prepareTimeoutMs
// stops loading (SwiftAudioEx stop: the item leaves the AVPlayer), is in error and reports
// crossfade_prepare_timeout as a PlaybackError (a skip or load waiting for it rejects with it
// instead); a stalled seek stops loading and
// leaves the player in error (its rejection is the report).
{
  const backendSource = read('ios/RNTrackPlayer/StandardPlaybackBackend.swift');
  const poll = section(backendSource, 'private func observeLoad() -> StandardLoadObservation {', '\n    }\n');
  // The give-up's stop, an adapter of StandardLoadCoordinator's player (the sequence is the
  // coordinator's, tested).
  const giveUp = section(backendSource, 'func stopLoading(log: String) {', '\n    }\n');
  const driver = section(facade, 'final class StandardLoadDriver {', '\n}\n');
  const gaveUp = section(player, 'func handleStandardLoadGaveUp(source: QueuedAudioPlayer, report: StandardGiveUpReport) {', '\n    }\n');
  const eventTypes = read('ios/RNTrackPlayer/Utils/EventType.swift');
  const tests = read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift');
  assert(
    poll.includes('guard isAuthoritative, !disposed, hostFailure == nil, !idleWithoutActiveTrack, let watch = loadWatch else {') &&
      poll.includes('let phase = standardLoadPhase(stateRawValue: player.playerState.rawValue, bufferedPosition: player.bufferedPosition)') &&
      poll.includes('let ownedElsewhere = issuedSeek != nil || !pendingSeeks.isEmpty') &&
      // A load's progress (StandardLoadBytes, tested): started per load before its first reading,
      // its item read from SwiftAudioEx's AVPlayer, its access-log bytes with the buffered position.
      poll.includes('if watch.startsLoad(StandardLoadObservation(item: item, phase: phase, readings: [], ownedElsewhere: ownedElsewhere)) {\n            loadBytes.startLoad(url: currentAssetURL())') &&
      poll.includes('let playerItem = standardPlayerItem(of: player)\n        if case let .item(current) = playerItem {\n            loadBytes.playerItem(current)') &&
      // No readings while the player has no AVPlayerItem (standardLoadReadings, tested): the
      // playable stage has only the total limit, as crossfade's prepare.
      poll.includes('readings: standardLoadReadings(playerItem, bytes: loadBytes.read(standardAccessLogBytes), buffered: player.bufferedPosition),') &&
      section(backendSource, 'private func currentAssetURL() -> URL? {', '\n    }\n').includes('return standardAssetURL(source: track.getSourceUrl(), isFile: track.getSourceType() == .file)') &&
      // AVFoundation's item events check the load at once when they are its item's.
      backendSource.includes('itemObservers = [.AVPlayerItemNewAccessLogEntry, .AVPlayerItemNewErrorLogEntry, .AVPlayerItemFailedToPlayToEndTime].map { name in') &&
      backendSource.includes('DispatchQueue.main.async { self?.itemEvent(item) }') &&
      section(backendSource, 'private func itemEvent(_ item: AVPlayerItem) {', '\n    }\n').includes('if loadBytes.isLoadEvent(item, url: url, player: standardPlayerItem(of: player)) {\n            loadDriver?.poke()') &&
      backendSource.includes('itemObservers.forEach { NotificationCenter.default.removeObserver($0) }') &&
      // The give-up's decisions and sequence are StandardGiveUps' and StandardLoadCoordinator's
      // (tested): the backend hands the watch's verdict over, then only stops and emits.
      backendSource.includes('giveUp: { [unowned self] verdict in\n                    self.loads.giveUpLoad(verdict, stallTimeoutMs: watch.lastStallTimeoutMs, totalTimeoutMs: watch.lastTotalTimeoutMs)') &&
      // Event-driven (SwiftAudioEx's state events), one timer only while a load is watched, at an
      // interval from the settings; no fixed poll.
      backendSource.includes('player.event.stateChange.addListener(stateListener) { [weak self] _ in\n                DispatchQueue.main.async { self?.loadDriver?.poke() }') &&
      driver.includes('guard !stopped, let delay = watch.nextCheckInMs() else { return }') &&
      facade.includes('return max(1, stallTimeoutMs / 10)') &&
      !backendSource.includes('stallCheckIntervalMs') &&
      // A failed seek keeps its target as the position, with no playback error.
      section(backendSource, 'let wait = StallWaitDriver(', 'request.wait = wait').includes('self.loads.seekTimedOut(issued: request.issued, track: ObjectIdentifier(request.track), message: message, keptPosition: request.position)') &&
      // Every give-up, a seek's too, fails its track (FailedLoadRule.failed: none for the loaded
      // track): a seek after a failed skip that gives up leaves the play to the previous track
      // (Android: StandardBackendHlsTest.aSeekThatGivesUpOnTheTrackASkipFailedToLoadLeavesThePlayToThePreviousTrack;
      // the rule: LOAD-14).
      !backendSource.includes('failsLoad') &&
      backendSource.includes('func emitGiveUp(_ report: StandardGiveUpReport) { onLoadGaveUp(player, report) }') &&
      // A seek that finds its track failed to load leaves it failed (Android: the same).
      section(backendSource, 'private func pumpSeeks() {', '\n    }\n').includes('if player.playerState == .failed {\n                // Its track failed to load (a player error): it stays failed, as Android.\n                loads.failLoadedTrack()') &&
      // A play, setPlayWhenReady(true) or retry that loads the active track drops a failed seek's
      // target (its own track's).
      backendSource.includes('if !loadActiveTrackAfterFailedLoad() { reloadAtKeptPosition(kept) }\n            requested.request(true)\n            player.play()') &&
      section(backendSource, '    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {', '    func seek(to position: Double, completion').includes('if !loadActiveTrackAfterFailedLoad() { reloadAtKeptPosition(kept) }') &&
      section(backendSource, '    func retry() {', '\n    }\n').includes('if jumped {\n        } else if kept != nil {') &&
      // A seek, pause, setPlayWhenReady(false) or stop that cancels a skip or load still waiting
      // goes back to the reported track (standardTrackToReturnTo, tested; Android's
      // StandardBackendHlsTest a*DuringASkipsLoad* on the real player).
      section(backendSource, 'private func enqueueSeek(', 'let request = PendingSeek(').includes('let cancelledWait = commandLoads.cancel()\n        clearHostFailure()\n        _ = failedLoads.command()\n        returnToReportedTrack(cancelledWait, at: position)') &&
      section(backendSource, '    func pause() {', '    func seek(to position: Double) throws {').includes('returnToReportedTrack(commandLoads.cancel(), at: nil)') &&
      section(backendSource, '    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {', '    func seek(to position: Double, completion').includes('guard value else {\n                // As pause (Android: the same command): a give-up\'s error stays, and a skip or\n                // load still waiting ends cancelled and does not take effect.\n                cancelPendingSeeks()\n                returnToReportedTrack(commandLoads.cancel(), at: nil)') &&
      section(backendSource, '    func stop() {', '    func setPlayWhenReady(').includes('returnToReportedTrack(cancelledWait, at: nil)') &&
      section(backendSource, 'private func returnToReportedTrack(', '\n    }\n').includes('guard let target = standardTrackToReturnTo(cancelledWait: cancelledWait, playerItem: current, reported: failedLoads.reported),') &&
      section(backendSource, 'private func returnToReportedTrack(', '\n    }\n').includes('try? player.jumpToItem(atIndex: index, playWhenReady: false)') &&
      // After a give-up: setPlayWhenReady(false) keeps the error (no clearHostFailure before its
      // return), a stop ends it and emits the stopped state (StandardGiveUps.stopped, tested).
      !section(backendSource, '    func setPlayWhenReady(_ value: Bool, completion: @escaping (Result<Void, Error>) -> Void) {', '            let kept = clearHostFailure()').includes('clearHostFailure') &&
      section(backendSource, '    func stop() {', '    func setPlayWhenReady(').includes('let ended = giveUps.stopped(playerStopped: player.playerState == .stopped)') &&
      section(backendSource, '    func stop() {', '    func setPlayWhenReady(').includes('player.stop()\n            if let ended = ended { onLoadGaveUp(player, ended) }') &&
      backendSource.includes('position: giveUps.position(live: idleWithoutActiveTrack ? 0 : player.currentTime),') &&
      backendSource.includes('return giveUps.clear()') &&
      giveUp.includes('IOSPlaybackLog.log("standard load abandoned (\\(log))")') &&
      giveUp.includes('requested.request(false)\n        player.stop()') &&
      backendSource.includes('if hostFailure != nil { return .error }') &&
      backendSource.includes('return hostFailure ?? iosPlaybackErrorSnapshot(from: player.playbackError)') &&
      section(backendSource, 'let wait = StallWaitDriver(', 'request.wait = wait').includes('self.seekError("standard_seek_timeout", message)') &&
      // SwiftAudioEx's own stopped after a give-up is not emitted (StandardLoadCoordinator.emitsPlayerState, tested).
      section(player, 'func handleAudioPlayerStateChange(source: QueuedAudioPlayer, state: AVPlayerWrapperState) {', '\n    }\n').includes('backend.identity === source, !backend.emitsPlayerState(state.rawValue) {\n            return') &&
      backendSource.includes('func emitsPlayerState(_ stateRawValue: String) -> Bool {\n        return loads.emitsPlayerState(stateRawValue)') &&
      player.includes('prepareTimeoutMs: { [weak self] in self?.prepareTimeout.milliseconds ?? prepareTimeoutDefaultMs },\n                onLoadGaveUp: { [weak self] source, report in\n                    self?.handleStandardLoadGaveUp(source: source, report: report)') &&
      // RNTrackPlayer emits StandardGiveUpReport's events (tested) by EventType's raw values.
      gaveUp.includes('for event in report.events {\n            guard let type = EventType(rawValue: event.name) else { continue }\n            emit(event: type, body: event.body)') &&
      eventTypes.includes('case PlaybackError = "playback-error"') &&
      eventTypes.includes('case PlaybackState = "playback-state"') &&
      section(facade, 'struct StandardGiveUpReport {', '\n}\n').includes('(name: "playback-state", body: ["state": "error", "error": failure.dictionary])') &&
      read('ios/RNTrackPlayer/Models/State.swift').includes('case none, ready, playing, paused, stopped, buffering, loading, error, ended') &&
      facade.includes('let standardPrepareTimeoutCode = "crossfade_prepare_timeout"') &&
      ['testStandardLoadAnItemLoadingThatNeverWasReadyGivesUpAtTheStallTimeout', 'testStandardLoadARebufferAfterReadyIsNotALoad',
        'testStandardLoadARetryAfterAStopOrAFailureIsANewLoad', 'testStandardLoadPhaseCountsAnItemReadyOnlyOnceItPlaysOrHasMedia',
        'testStandardLoadBytesArrivingKeepALoadGoingWhileItsBufferedPositionStandsStill',
        'testStandardLoadBytesTheItemAppearingIsProgressAndUnknownBytesCountAsNothing',
        'testStandardLoadBytesALoadCountsOnlyItsOwnItem',
        'testStandardLoadBytesALoadWatchedAgainAfterASeekKeepsCountingItsItem',
        'testStandardLoadBytesWithoutThePlayersItemTheLoadTakesTheFirstLoggedItemOfItsURL',
        'testStandardPlayerItemIsReadThroughSwiftAudioExsPrivateWrapper',
        'testStandardLoadWatchStartsALoadWhereItsCheckBeginsWatching',
        'testStandardGiveUpOfALoadNoCommandWaitsForIsAnErrorStateAndAPlaybackError',
        'testStandardGiveUpOfALoadACommandWaitsForRejectsItAndIsNoPlaybackError',
        'testStandardGiveUpOfASeekKeepsItsTargetAndIsNoPlaybackError',
        'testStandardGiveUpTheNextCommandClearsTheError',
        'testStandardGiveUpAStopEndsTheErrorStoppedAndAPauseKeepsIt',
        'testStandardCommandLoadASeekPauseOrStopThatCancelsAWaitGoesBackToTheReportedTrack',
        'testStandardLoadCoordinatorASkipWaitsForItsTrackToLoadThenReportsItAndEnds',
        'testStandardLoadCoordinatorAWaitReloadsATrackStandingStillAndEndsAtOnceWhenNothingIsToWaitFor',
        'testStandardLoadCoordinatorALoadGiveUpStopsThePlayerErrorsAndKeepsTheActiveTrack',
        'testStandardLoadCoordinatorASeekThatGivesUpStopsThePlayerOnlyWhenIssuedOnItsTrack',
        'testStandardLoadCoordinatorAPlayerFailureFailsTheLoadOnceAndRejectsTheWaitWithItsError',
        'testStandardCommandLoadResultIsTheCommandsResolution']
        .every((t) => tests.includes(`func ${t}()`)),
    'The iOS standard player must give up a load with no progress at stallTimeoutMs, as crossfade and Android.'
  );
}

// The standard player follows the shared failed-load rule (FailedLoadRule; Android the same).
{
  const backendSource = read('ios/RNTrackPlayer/StandardPlaybackBackend.swift');
  assert(
    read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('appendingPathComponent("scripts/fixtures/failed-load-scenarios.json")') &&
      backendSource.includes('if failedLoads.isPending((player.currentItem as AnyObject?).map(ObjectIdentifier.init)) {\n            return indexOfItem(failedLoads.reported) ?? -1') &&
      // One explicit state (FailedLoadRule.Phase and PlayerError): the backend keeps no flag of its own.
      read('ios/RNTrackPlayer/PlaybackBackend.swift').includes('    enum Phase: Equatable {\n        case selecting') &&
      !backendSource.includes('sawPlayerFailure') &&
      // The load's sequences are StandardLoadCoordinator's (tested), the backend its player.
      section(backendSource, 'private func observeLoad() -> StandardLoadObservation {', '\n    }\n').includes('loads.followLoad(observed)') &&
      backendSource.includes('loads = StandardLoadCoordinator(player: self, watched: loadWatch != nil)') &&
      backendSource.includes('extension StandardPlaybackBackend: StandardLoadPlayer {') &&
      [
        'var currentLoadItem: ObjectIdentifier? { return (player.currentItem as AnyObject?).map(ObjectIdentifier.init) }',
        'var loadStateRawValue: String { return player.playerState.rawValue }',
        'var loadErrorMessage: String? { return player.playbackError?.localizedDescription }',
        'func reloadForCommand() { player.reload(startFromCurrentTime: false) }',
        'func checkLoad() { loadDriver?.poke() }',
        'func reportActiveTrack(_ change: FailedLoadRule.Report) { report(change) }',
        'func showAfterFailedLoad(_ reported: ObjectIdentifier?) { onLoadFailed(player, indexOfItem(reported)) }'
      ].every((line) => backendSource.includes(line)) &&
      section(backendSource, '    func dispose() throws {', '\n    }\n').includes('loads.dispose()') &&
      // A track is reported once it loaded (deferred), both events, and the lock screen points
      // back to the active track after a failed load.
      player.includes('!backend.itemMoved(item, lastItem: lastItem, lastPosition: lastPosition ?? 0) {') &&
      player.includes('func handleStandardActiveTrackChanged(source: QueuedAudioPlayer, index: Int?, lastTrack: Track?, lastIndex: Int?, lastPosition: Double) {') &&
      section(player, 'private func emitStandardActiveTrackChanged(', '\n    }\n').includes('emit(event: EventType.PlaybackTrackChanged, body: b)') &&
      section(player, 'func handleStandardLoadFailed(source: QueuedAudioPlayer, activeIndex: Int?) {', '\n    }\n').includes('Metadata.update(for: source, with: track.toObject(), through: (source.nowPlayingInfoController as? StandardNowPlayingInfoController)?.direct)') &&
      // The crossfade play after a failed first load retries the track that failed (Android too).
      section(orchestrator, '        case .error:', '        }\n        refreshNowPlaying()').includes('indexToPlayAfterFailedLoad(') &&
      read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift').includes('func testAPlayAfterAFailedFirstLoadRetriesTheTrackThatFailed()') &&
      section(backendSource, 'private func cancelPendingSeeks() {', '\n    }\n').includes('pokeLoadWatchAfterSeek()') &&
      section(backendSource, 'private func didCompleteNativeSeek(', '\n    }\n').includes('loads.nativeSeekEnded(didFinish: didFinish, track: ObjectIdentifier(request.track), isLatest: wasIssued && pendingSeeks.isEmpty, seekable: seekable, keptPosition: request.position)') &&
      // A seek on an item AVPlayer cannot seek in completes where the player is (Android: where
      // ExoPlayer lands), and one on a stream with no duration is issued once its item is ready.
      section(backendSource, 'private func didCompleteNativeSeek(', '\n    }\n').includes('let seekable = standardSeekItem(standardPlayerItem(of: player)).seekable') &&
      section(backendSource, 'private func didCompleteNativeSeek(', '\n    }\n').includes('request.finish(standardSeekEndCompletes(didFinish: didFinish, sameTrack: sameTrack, seekable: seekable) && !disposed') &&
      section(backendSource, 'private func pumpSeeks() {', '\n    }\n').includes('guard standardSeekCanBeIssued(duration: player.duration, item: standardSeekItem(standardPlayerItem(of: player))) else {') &&
      section(backendSource, 'func remove(at indexes: [Int]) throws {', '\n    }\n').includes('reportRemovedTrack(before)'),
    'The iOS standard player must keep the previous track active after a failed load, as crossfade.'
  );
}

// A load that gives up says the same as on Android whichever stage it reached.
assert(
  !engine.includes('did not become playable') &&
    section(engine, 'func prepare(track: Track, position: Double, completion:', 'asset.loadValuesAsynchronously(').includes('NSLocalizedDescriptionKey: crossfadeLoadTimeoutMessage(reason),'),
  'An iOS load that gives up must use the shared give-up message at every stage.'
);

// Standard skip, next, previous and load end as crossfade's and Android's (smart-music-player
// reads the active index right after them): once the track loaded and is the active one, then
// any initial seek, or rejected with the load's failure (crossfade_prepare_timeout,
// crossfade_engine_error) or `cancelled`, codes JS receives as on Android; a failure a command
// waits for is not also a playback error. The XCTest target reaches StandardCommandLoad only.
{
  const tests = read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift');
  assert(
    facade.includes('let standardLoadErrorCode = "crossfade_engine_error"') &&
      section(standardBackend, 'func load(_ track: Track, completion: @escaping (Result<Int, Error>) -> Void) {', '\n    }\n').includes('waitForCommandLoad { [weak self] result in') &&
      section(standardBackend, 'func skip(to index: Int, initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {', 'func skipToNext(').includes('finishCommandLoad(') &&
      (section(standardBackend, 'func skipToNext(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {', 'func skipToPrevious(').match(/finishCommandLoad\(seekTo: initialTime >= 0 \? initialTime : nil, completion: completion\)/g) || []).length === 2 &&
      section(standardBackend, 'func skipToPrevious(initialTime: Double, completion: @escaping (Result<Void, Error>) -> Void) {', 'func play(completion:').includes('finishCommandLoad(seekTo: initialTime >= 0 ? initialTime : nil, completion: completion)') &&
      section(standardBackend, 'private func waitForCommandLoad(', '\n    }\n').includes('loads.waitForCommandLoad { outcome in completion(standardCommandLoadResult(outcome)) }') &&
      section(standardBackend, 'func play() throws {', '\n    }\n').includes('commandLoads.failureCleared()') &&
      section(standardBackend, 'func retry() {', '\n    }\n').includes('onMain { commandLoads.failureCleared() }') &&
      section(facade, 'func loadGaveUp(', '\n    }\n').includes('commandLoads.failed(item, code: standardPrepareTimeoutCode, message: message, reportedByPlayer: false)') &&
      section(standardBackend, 'private func enqueueSeek(', 'let request = PendingSeek(').includes('commandLoads.cancel()') &&
      ['func stop() {', 'func replaceQueue(_ tracks: [Track]) throws {', 'func clearQueue() {'].every((start) =>
        section(standardBackend, start, '\n    }\n').includes('commandLoads.cancel()')) &&
      // Disposed: StandardLoadCoordinator.dispose cancels a waiting command (tested).
      section(standardBackend, 'func dispose() throws {', '\n    }\n').includes('loads.dispose()') &&
      section(player, 'func handleAudioPlayerFailed(source: QueuedAudioPlayer, error: Error?) {', '\n    }\n').includes('backend.identity === source, backend.reportsPlayerErrorThroughCommand() {') &&
      ['testStandardCommandLoadSmartMusicPlayersSequenceEndsOnceTheTargetLoadedAndIsReported',
        'testStandardCommandLoadASkipToTheSelectedFirstTrackEndsAtItsLoadNotAtItsSelection',
        'testStandardCommandLoadAFailedLoadRejectsWithItsCodeAndTheCommandReportsIt',
        'testStandardCommandLoadANewerCommandCancelsTheOlderWait',
        'testStandardCommandLoadAGiveUpTheCommandRejectedWithLeavesTheTracksLaterFailuresReported',
        'testStandardCommandLoadAWaitStartsItsTracksLoadOnlyWhenThePlayerStandsStill'].every((t) => tests.includes(`func ${t}()`)),
    'iOS standard skip, next, previous and load must end once their track loaded, as crossfade and Android.'
  );
}

// The standard seek and backend-switch waits sample every stallTimeoutMs / 10 (as the load watch
// and Android) and look at every player event between; no fixed poll. The crossfade engine keeps
// stallCheckIntervalMs (out of scope).
{
  assert(
    section(standardBackend, 'private func enqueueSeek(', 'request.wait = wait').includes('intervalMs: standardLoadSampleIntervalMs(stallMs),') &&
      section(standardBackend, 'private func pumpSeeks() {', '\n    }\n').includes('DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(standardLoadSampleIntervalMs(stallTimeoutMs())), execute: poll)') &&
      !standardBackend.includes('asyncAfter(deadline: .now() + 0.02') &&
      !standardBackend.includes('Thread.sleep(forTimeInterval:') &&
      standardBackend.includes('player.event.updateDuration.addListener(seekEventListener) { [weak self] _ in\n            DispatchQueue.main.async { self?.pumpSeeksWaitingForTheItem() }') &&
      standardBackend.includes('player.event.stateChange.addListener(seekEventListener) { [weak self] _ in\n            DispatchQueue.main.async { self?.pumpSeeksWaitingForTheItem() }') &&
      section(standardBackend, 'private func waitForStandardPlaybackActivation(', '\n}\n').includes('let sampleMs = standardLoadSampleIntervalMs(stallTimeoutMs)') &&
      section(standardBackend, 'private func waitForStandardPlaybackActivation(', '\n}\n').includes('waitForNextPoll: { _ = wake.wait(timeout: .now() + .milliseconds(sampleMs)) }') &&
      ['player.event.stateChange.addListener(listener) { _ in wake.signal() }', 'player.event.updateDuration.addListener(listener) { _ in wake.signal() }', 'player.event.seek.addListener(listener) { _ in wake.signal() }']
        .every((line) => section(standardBackend, 'private func waitForStandardPlaybackActivation(', '\n}\n').includes(line)),
    'iOS standard seek and readiness waits must sample every stallTimeoutMs / 10 and wake at player events, as Android.'
  );
}

// Rule 13: while a standard track loads, every reader agrees with the reported active track
// (ReportedTrackProgress, ReportedNowPlaying: tested in PlaybackBackend.swift); the wiring the
// XCTest target cannot reach.
{
  const metadata = read('ios/RNTrackPlayer/Utils/Metadata.swift');
  const secondElapse = section(player, 'func handleAudioPlayerSecondElapse(source: QueuedAudioPlayer, seconds: Double) {', '\n    }\n');
  const nowPlayingHandler = section(player, 'func handleStandardNowPlaying(source: QueuedAudioPlayer, index: Int?, held: Bool) {', '\n    }\n');
  assert(
    ['var position: Double { return reportedProgress().position }', 'var duration: Double { return reportedProgress().duration }', 'var bufferedPosition: Double { return reportedProgress().buffered }']
      .every((line) => standardBackend.includes(line)) &&
      section(standardBackend, 'private func reportedProgress() -> TrackProgress {', '\n    }\n').includes('reported: failedLoads.reported,') &&
      section(standardBackend, 'func itemMoved(', '\n    }\n').includes('progress.left((lastItem as AnyObject?).map(ObjectIdentifier.init), position: lastPosition)') &&
      section(standardBackend, 'func itemMoved(', '\n    }\n').includes('followNowPlaying()') &&
      section(standardBackend, 'private func observeLoad() -> StandardLoadObservation {', '    func followNowPlaying() {').includes('_ = reportedProgress()\n        followNowPlaying()') &&
      section(standardBackend, 'private func report(_ change: FailedLoadRule.Report', '\n    }\n').includes('followNowPlaying()') &&
      section(standardBackend, '    func followNowPlaying() {', '\n    }\n').includes('nowPlaying.follow(reported: failedLoads.reported, playerItem: current)') &&
      section(standardBackend, 'func dispose() throws {', '\n    }\n').includes('(player.nowPlayingInfoController as? StandardNowPlayingInfoController)?.isHeld = false') &&
      ['func set(keyValue: NowPlayingInfoKeyValue) {\n        if !isHeld { base.set(keyValue: keyValue) }', 'func set(keyValues: [NowPlayingInfoKeyValue]) {\n        if !isHeld { base.set(keyValues: keyValues) }', 'func setWithoutUpdate(keyValues: [NowPlayingInfoKeyValue]) {\n        if !isHeld { base.setWithoutUpdate(keyValues: keyValues) }']
        .every((line) => standardBackend.includes(line)) &&
      (player.match(/QueuedAudioPlayer\(nowPlayingInfoController: StandardNowPlayingInfoController\(\)\)/g) || []).length === 2 &&
      !/QueuedAudioPlayer\(\)/.test(player) &&
      player.includes('onNowPlaying: { [weak self] source, index, held in\n                    self?.handleStandardNowPlaying(source: source, index: index, held: held)') &&
      nowPlayingHandler.includes('gate.isHeld = held && autoUpdateNowPlayingInfo') &&
      nowPlayingHandler.includes('Metadata.update(for: source, with: metadata, through: gate.direct)') &&
      nowPlayingHandler.includes('metadata["elapsedTime"] = backend?.position ?? source.currentTime') &&
      metadata.includes('let target = controller ?? player.nowPlayingInfoController') &&
      !metadata.includes('player?.nowPlayingInfoController') &&
      secondElapse.includes('"position": backend.position,') &&
      secondElapse.includes('"track": backend.currentIndex,') &&
      section(player, 'public func updateMetadata(for trackIndex: NSNumber', '\n    }\n').includes('} else if !useOrchestratedCrossfade, activePlaybackBackend.currentIndex == index {\n            Metadata.update(for: player, with: metadata, through: direct)'),
    'iOS standard readers (progress, events, lock screen) must agree with the reported active track while another loads, as Android.'
  );
}

console.log('iOS crossfade contracts OK');
