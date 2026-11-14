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
    standardBackend.includes('struct IOSPlaybackErrorSnapshot: Equatable') &&
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

// The crossfade engine's load: one stall watch from the start, the app's prepareTimeoutMs as the
// cap (the playable stage too) and stallTimeoutMs once an item loads media.
const waitForReadyItem = section(engine, 'private func waitForReadyItem(', 'private func waitForPlaying(');
const enginePrepare = section(engine, 'func prepare(track: Track', 'func seek(to position: Double');
assert(
  enginePrepare.includes('stallTimeoutMs: stallTimeoutMs(),\n            totalTimeoutMs: prepareTimeoutMs(),') &&
    enginePrepare.includes('guard loadWatch.capVerdict(at: Self.now()) == .capExceeded else { return true }') &&
    enginePrepare.includes('self.pendingAsset?.cancelLoading()') &&
    enginePrepare.includes('guard let self = self, self.generation == currentGeneration, !playableSettled else { return }') &&
    enginePrepare.includes('readyWatch.noteProgress(at: Self.now())') &&
    enginePrepare.includes('watch: readyWatch') &&
    waitForReadyItem.includes('let verdict = watch.check(at: Self.now(), readings: Self.loadProgress(of: item))') &&
    !/\.milliseconds\(\d+\)/.test(waitForReadyItem) &&
    !waitForReadyItem.includes('asyncAfter'),
  'iOS engine load must give up on a stall (stallTimeoutMs) or at prepareTimeoutMs, playable stage included.'
);
const waitForPlaying = section(engine, 'private func waitForPlaying(', 'private func scheduleWaitCheck(');
assert(
  waitForPlaying.includes('var watch = StallWatch(stallTimeoutMs: stallTimeoutMs(), totalTimeoutMs: timeoutMs, startedAt: Self.now())') &&
    waitForPlaying.includes('readings: (self.player.currentItem.map(Self.loadProgress(of:)) ?? [0, 0]) + [self.currentTime]') &&
    !waitForPlaying.includes('asyncAfter') &&
    engine.includes('DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stallCheckIntervalMs), execute: tick)') &&
    engine.includes('let loadedSeconds = item.loadedTimeRanges.reduce(0.0) { total, value in') &&
    engine.includes('total + Double(max(0, event.numberOfBytesTransferred))') &&
    engine.includes('var stallTimeoutMs: () -> Int = { stallTimeoutDefaultMs }') &&
    orchestrator.includes('engineA.stallTimeoutMs = stallTimeoutMs') &&
    orchestrator.includes('engineB.stallTimeoutMs = stallTimeoutMs'),
  'iOS engine play start must give up on a stall (stallTimeoutMs) or at playStartTimeoutMs.'
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
    section(player, 'private func applyTimeouts(', '@objc(updateOptions:').includes('for setting in [prepareTimeout, playStartTimeout, standardReadyTimeout, standardSeekTimeout, stallTimeout]') &&
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
    standardBackend2.includes('stallTimeoutMs: stallTimeoutMs(),\n            totalTimeoutMs: seekTimeoutMs(),') &&
    standardBackend2.includes('scheduleSeekCheck(request, watch: watch)') &&
    standardBackend2.includes('readings: [self.player.bufferedPosition]') &&
    standardBackend2.includes('DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stallCheckIntervalMs), execute: check)') &&
    !/asyncAfter\(deadline: \.now\(\) \+ [\d.]+, execute: timeout\)/.test(standardBackend2) &&
    !/timeout: TimeInterval = \d/.test(standardBackend2) &&
    standardBackend2.includes('timeoutMs: readinessTimeoutMs(),\n                stallTimeoutMs: stallTimeoutMs()') &&
    standardBackend2.includes('        timeoutMs: timeoutMs,\n        stallTimeoutMs: stallTimeoutMs,\n        observe: {') &&
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

console.log('iOS crossfade contracts OK');
