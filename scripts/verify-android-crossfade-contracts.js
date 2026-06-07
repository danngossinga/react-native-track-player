const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8');
}

function section(source, startToken, endToken) {
  const start = source.indexOf(startToken);
  const end = source.indexOf(endToken, start + startToken.length);
  if (start < 0 || end < 0) {
    throw new Error(`Unable to isolate section ${startToken}`);
  }
  return source.slice(start, end);
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const orchestrator = read('android/src/main/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestrator.kt');
const musicService = read('android/src/main/java/com/doublesymmetry/trackplayer/service/MusicService.kt');

const prepareCrossfade = section(
  orchestrator,
  'suspend fun crossFadePrepare(',
  'suspend fun crossFade('
);
const crossFade = section(
  orchestrator,
  'suspend fun crossFade(',
  'private suspend fun fallbackToTargetAfterStalledCrossfade('
);
const postCrossfadeMaintenance = section(
  orchestrator,
  'private fun schedulePostCrossfadeStandbyMaintenance(',
  'fun release()'
);
const setupPlayer = section(
  musicService,
  'fun setupPlayer(playerOptions: Bundle?)',
  'private fun AudioContentType.toExoAudioContentType()'
);
const crossfadeSetupBranch = section(
  setupPlayer,
  'if (crossfadeEnabled) {',
  '} else {'
);
const refreshOrchestratedMediaSurface = section(
  musicService,
  'private fun refreshOrchestratedMediaSurface(',
  'private fun runOrchestratedRemoteCommand('
);
const startTrackAt = section(
  orchestrator,
  'private suspend fun startTrackAt(',
  'private suspend fun ensureActivePrepared('
);

assert(
  prepareCrossfade.includes('crossfade_not_playing'),
  'Android crossFadePrepare must reject when playback is not active.'
);
assert(
  crossFade.includes('crossfade_not_playing'),
  'Android crossFade must cancel/reject when playback is not active.'
);
assert(
  !crossFade.includes('playWhenReady = true'),
  'Android crossFade must not invent playback intent; play() owns playWhenReady=true.'
);
assert(
  !crossFade.includes('correcting playWhenReady'),
  'Android crossFade must not patch over playWhenReady=false.'
);
assert(
  crossFade.includes('error.code != "crossfade_not_playing"'),
  'Android crossFade must treat pause/not-playing cancellation as non-fatal.'
);
assert(
  crossFade.indexOf('delegate.onActiveTrackChanged(toIndex, fromIndex, oldPositionMs)') >= 0 &&
    crossFade.indexOf('delegate.onActiveTrackChanged(toIndex, fromIndex, oldPositionMs)') <
      crossFade.indexOf('delegate.onNowPlayingChanged(toIndex)'),
  'Android crossFade must publish the active track change before refreshing now-playing metadata.'
);
assert(
  orchestrator.includes('private var standbyMaintenanceJob: Job? = null'),
  'Android orchestrator must track deferred standby maintenance work.'
);
assert(
  crossFade.includes('outgoingEngine.setVolume(0f)') &&
    crossFade.includes('outgoingEngine.pause()') &&
    !crossFade.includes('outgoingEngine.reset()'),
  'Android crossFade completion must mute/pause the outgoing ExoPlayer without resetting it synchronously.'
);
assert(
  crossFade.includes('schedulePostCrossfadeStandbyMaintenance(crossfadeDurationMs = durationMs)') &&
    !crossFade.includes('preloadNextIfPossible()'),
  'Android crossFade completion must defer next standby preload off the audible completion path.'
);
assert(
  postCrossfadeMaintenance.includes('standbyEngine.reset()') &&
    postCrossfadeMaintenance.includes('preloadNextIfPossible()'),
  'Android post-crossfade maintenance must own standby reset and next preload.'
);
assert(
  musicService.includes('LocalBroadcastManager.getInstance(this).sendBroadcast(intent)'),
  'MusicService events must go through MusicEvents local broadcast transport.'
);
assert(
  !musicService.includes('DeviceEventManagerModule') && !musicService.includes('currentReactContext'),
  'MusicService must not emit JS events through a separate ReactContext lookup.'
);
assert(
  !musicService.includes('suppressKotlinAudioMediaSurface'),
  'Crossfade mode must not patch over KotlinAudio media surface suppression.'
);
assert(
  !musicService.includes('getDeclaredField("mediaSession")') &&
    !musicService.includes('getDeclaredField("mediaSessionConnector")'),
  'Crossfade mode must not use reflection to deactivate KotlinAudio private MediaSession state.'
);
assert(
  !crossfadeSetupBranch.includes('QueuedAudioPlayer('),
  'Crossfade setup must not instantiate KotlinAudio QueuedAudioPlayer.'
);
assert(
  !crossfadeSetupBranch.includes('notificationManager') &&
    !refreshOrchestratedMediaSurface.includes('notificationManager'),
  'Crossfade publication must use AndroidOrchestratedMediaSurface, not KotlinAudio notificationManager.'
);
assert(
  startTrackAt.indexOf('delegate.onActiveTrackChanged(index, previousIndex, oldPositionMs)') >= 0 &&
    startTrackAt.indexOf('delegate.onActiveTrackChanged(index, previousIndex, oldPositionMs)') <
      startTrackAt.indexOf('activeEngine.play(rate)'),
  'Direct Android crossfade skips must publish the active track before starting audible playback.'
);

console.log('Android crossfade contracts OK');
