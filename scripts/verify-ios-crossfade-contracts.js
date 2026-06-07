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

assert(
  orchestrator.includes('private var standbyMaintenanceWorkItem: DispatchWorkItem?'),
  'iOS orchestrator must track deferred standby maintenance work.'
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

console.log('iOS crossfade contracts OK');
