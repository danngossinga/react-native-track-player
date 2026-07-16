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
    facade.indexOf('replacement.commitQueue(captured.snapshot)') &&
    facade.indexOf('replacement.commitQueue(captured.snapshot)') <
      facade.indexOf('self.backend = replacement') &&
    facade.indexOf('self.backend = replacement') < facade.indexOf('self.authority.publish(replacement)') &&
    facade.includes('initial.activateInitialControlSurface()'),
  'iOS must commit the queue before publishing the facade pointer and exact authority.'
);
assert(
  facade.includes('private let cleanupDiagnosticQueue = DispatchQueue(') &&
    facade.includes('self.reportCleanupDiagnostic(.disposalFailed)') &&
    facade.includes('cleanupDiagnosticQueue.async {') &&
    !facade.includes('self.onCleanupDiagnostic(.disposalFailed)'),
  'iOS post-commit cleanup diagnostics must be observational and unable to block transaction completion.'
);
assert(
  makePlaybackBackend.includes('let incomingQueue = initiallyAuthoritative ? nil : playerTracks()') &&
    makePlaybackBackend.includes('let source = initiallyAuthoritative ? player : makeStandardPlayerCandidate()') &&
    makePlaybackBackend.includes('incomingQueue: incomingQueue') &&
    standardBackend.includes('playbackBackendQueueForRestore('),
  'iOS PingPong-to-standard swaps must create a fresh player and restore the incoming Track objects.'
);
assert(
  makePlaybackBackend.includes('let orchestrator = IOSPlaybackOrchestrator()') &&
    makePlaybackBackend.includes('queueProvider: { [weak source]') &&
    makePlaybackBackend.includes('configurePlayerEvents(source)'),
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
    postCrossfadeMaintenance.includes('self.preloadNextIfPossible()'),
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
  cancelAllWork.includes('standbyMaintenanceWorkItem?.cancel()') &&
    cancelScheduledPlaybackWork.includes('standbyMaintenanceWorkItem?.cancel()'),
  'iOS deferred standby maintenance must be cancelled with other playback work.'
);
assert(
  orchestrator.includes('private var activeCrossfadeCompletion: PlaybackBackendCommandCompletion<Void>?') &&
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
  standardBackend.includes('authoritativeQueue') &&
    standardBackend.includes('samePlaybackBackendTrackObjects') &&
    facade.includes('restoreAuthoritativeBackend(previous, snapshot: captured.snapshot)'),
  'iOS backend rollback must preserve full Track object identity and restore the authoritative queue.'
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

console.log('iOS crossfade contracts OK');
