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
const facade = read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackend.kt');
const standardBackend = read('android/src/main/java/com/doublesymmetry/trackplayer/service/KotlinAudioPlaybackBackend.kt');
const pingPongBackend = read('android/src/main/java/com/doublesymmetry/trackplayer/service/PingPongPlaybackBackend.kt');
const mediaSurface = read('android/src/main/java/com/doublesymmetry/trackplayer/service/AndroidOrchestratedMediaSurface.kt');
const sharedFlowAdmission = read('android/src/main/java/com/doublesymmetry/trackplayer/service/SharedFlowAdmission.kt');
const mediaSessionInstrumentation = read('android/src/androidTest/java/com/doublesymmetry/trackplayer/service/KotlinAudioMediaSessionControlInstrumentationTest.kt');

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
const setupPlayer = section(
  musicService,
  'fun setupPlayer(playerOptions: Bundle?)',
  'override fun onBind('
);
const createPlaybackBackend = section(
  musicService,
  'private fun createPlaybackBackend(',
  '@MainThread\n    fun setupPlayer('
);
const progressUpdateEvent = section(
  musicService,
  'private suspend fun progressUpdateEvent()',
  'private fun getPendingIntentFlags()'
);
const standardRelinquish = section(
  standardBackend,
  'override fun relinquishExclusiveControlSurfaceBeforeCommit()',
  'override fun commitQueue('
);
const standardDispose = section(
  standardBackend,
  'override suspend fun dispose()',
  'private fun releasePlayer()'
);

assert(
  prepareCrossfade.includes('crossfade_not_playing'),
  'Android crossFadePrepare must reject when playback is not active.'
);
assert(
  setupPlayer.includes('standardPlayerFactory = {') &&
    !setupPlayer.includes('createStandardPlayerBinding()') &&
    setupPlayer.includes('createPlaybackBackend(initialType, initiallyAuthoritative = true)'),
  'Android initial PingPong setup must keep the standard player factory lazy.'
);
assert(
  mediaSurface.includes('isActive = false') &&
    facade.includes('initialBackend.activateInitialControlSurface()') &&
    pingPongBackend.includes('override fun activateInitialControlSurface()'),
  'Android PingPong media control surface must start inactive and be explicitly activated by the facade.'
);
assert(
  facade.indexOf('previous.relinquishExclusiveControlSurfaceBeforeCommit()') <
    facade.indexOf('finalReplacement.commitQueue(snapshot)') &&
    facade.indexOf('finalReplacement.commitQueue(snapshot)') < facade.indexOf('backend = finalReplacement') &&
    facade.indexOf('backend = finalReplacement') < facade.indexOf('authority.publish(finalReplacement)') &&
    facade.indexOf('backend = finalReplacement') < facade.indexOf('finalReplacement.activateAfterCommit(snapshot)') &&
    !standardRelinquish.includes('releasePlayer()') &&
    standardDispose.includes('releasePlayer()'),
  'Android must defer standard-player destruction until post-commit disposal and activate the replacement only after commit.'
);
assert(
  facade.includes('owner?.let { it.type == type && it.identity === identity }') &&
    facade.includes('suspend fun routeIfAuthoritative(') &&
    facade.includes('val identity = Any()') &&
    facade.indexOf('candidateRemoteProxy = identity') <
      facade.indexOf('replacement = factory.create(type, identity)') &&
    createPlaybackBackend.includes('identity: Any = Any()') &&
    setupPlayer.includes('PlaybackBackendFactory { type, identity ->') &&
    setupPlayer.includes('createPlaybackBackend(type, identity = identity)') &&
    createPlaybackBackend.includes('createOrchestratedMediaSurface(identity)'),
  'Android authority, remotes, and media surfaces must pre-admit one exact identity per backend generation.'
);
assert(
  progressUpdateEvent.includes('withActivePlaybackBackendRead { backend ->') &&
    progressUpdateEvent.includes('backend.playbackState != AudioPlayerState.PLAYING') &&
    progressUpdateEvent.includes('backend.positionMs.toSeconds()') &&
    progressUpdateEvent.includes('backend.bufferedMs.toSeconds()'),
  'Android progress events must read one coherent backend snapshot under the facade mutex.'
);
assert(
  musicService.includes('withActivePlaybackBackend {\n            if (it.type == PlaybackBackendType.PING_PONG)') &&
    musicService.includes('withActivePlaybackBackend {\n            if (it.type == PlaybackBackendType.PING_PONG) {'),
  'Android legacy crossfade calls must decide their PingPong no-op inside the serialized facade route.'
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
  orchestrator.includes('private var activeCrossfadeCancellation: CompletableDeferred<Unit>?') &&
    orchestrator.includes('cancelCrossfade("pause", promoteIncoming = true)') &&
    crossFade.includes('delayCrossfade(intervalMs, runId, cancellation)'),
  'Android pause must cancel and release the exact active crossfade lease without waiting for its full duration.'
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
  !refreshOrchestratedMediaSurface.includes('notificationManager'),
  'Crossfade publication must use AndroidOrchestratedMediaSurface, not KotlinAudio notificationManager.'
);
assert(
  startTrackAt.indexOf('delegate.onActiveTrackChanged(index, previousIndex, oldPositionMs)') >= 0 &&
    startTrackAt.indexOf('delegate.onActiveTrackChanged(index, previousIndex, oldPositionMs)') <
      startTrackAt.indexOf('activeEngine.play(rate)'),
  'Direct Android crossfade skips must publish the active track before starting audible playback.'
);
assert(
  facade.includes('suspend fun <T> withCurrentBackend(') &&
    facade.includes('activeCommandLeases') &&
    facade.includes('withContext(NonCancellable)') &&
    musicService.includes('withActivePlaybackBackend { backend ->'),
  'Android playback commands must use cancellable operations with non-leaking facade leases.'
);
assert(
  standardBackend.includes('private val queueState = PlaybackBackendQueueState<TrackAudioItem>()') &&
    standardBackend.includes('queueState.captureAuthoritative(queue)') &&
    standardBackend.includes('queueStore.replaceWith(queueState.rollback())') &&
    pingPongBackend.includes('private val queueState = PlaybackBackendQueueState<TrackAudioItem>()') &&
    pingPongBackend.includes('queueState.captureAuthoritative(queue)') &&
    pingPongBackend.includes('queueStore.replaceWith(queueState.rollback())') &&
    facade.includes('rollbackHandoffQuiescence(') &&
    facade.includes('previous.cancelHandoffQuiescence(snapshot)') &&
    facade.includes('previous.resumeControlSurface(snapshot)'),
  'Android backend rollback must retain full TrackAudioItem identity and restore the authoritative queue.'
);
assert(
  standardBackend.includes('private val logicalPlaybackState = KotlinAudioLogicalPlaybackStateSidecar()') &&
    standardBackend.includes('override val currentIndex: Int\n        get() = logicalPlaybackState.currentIndex(player.currentIndex)') &&
    standardBackend.includes('selectFirstPhysicalItemIfNeeded()') &&
    standardBackend.includes('if (logicalPlaybackState.shouldIgnorePrevious()) return') &&
    mediaSessionInstrumentation.includes('testRestoredIdlePlayPublishesCanonicalFirstTrack') &&
    mediaSessionInstrumentation.includes('testRestoredIdleRetryPublishesCanonicalFirstTrack') &&
    mediaSessionInstrumentation.includes('testRestoredIdleLoadPublishesCanonicalCallbackAndQueue') &&
    mediaSessionInstrumentation.includes('testRestoredIdleQueueActivatesPhysicalZeroOnlyOnNext') &&
    mediaSessionInstrumentation.includes('canonicalActivationIndices()'),
  'Android restored standard-idle activation must publish exactly canonical index 0 and guard previous/double activation.'
);
assert(
  sharedFlowAdmission.includes('CoroutineStart.UNDISPATCHED') &&
    sharedFlowAdmission.includes('if (gate.acceptsEvents())') &&
    musicService.includes('val productAdmission = SharedFlowAdmissionGate()') &&
    musicService.includes('binding.productAdmission.suspendAdmission()') &&
    musicService.includes('binding.productAdmission.admitAfterProducerDrain(binding.ownerScope)'),
  'Android standard candidates must subscribe before restore and quarantine replayed product events until post-commit admission.'
);
assert(
  facade.includes('capturePhysicalRemoteTicket(') &&
    facade.includes('routePhysicalRemote(') &&
    musicService.includes('facade.capturePhysicalRemoteTicket(identity)') &&
    musicService.includes('facade.routePhysicalRemote(ticket)'),
  'Android physical remotes must use generation tickets that survive successful handoff and reject rollback generations.'
);
assert(
  musicService.includes('val initialType = if (crossfadeEnabled) PlaybackBackendType.PING_PONG else PlaybackBackendType.STANDARD') &&
    musicService.includes('initiallyAuthoritative = true'),
  'Android legacy crossfade setup must converge to the authoritative pingPong backend.'
);

// Every engine load and seek passes the app's settings (the total limit and the stall timeout),
// never a number.
assert(
  !/timeoutMs\s*=\s*\d/.test(orchestrator) &&
    (orchestrator.match(/timeoutMs = prepareTimeoutMs\(\)/g) || []).length === 6 &&
    (orchestrator.match(/timeoutMs = prepareTimeoutMs\(\), stallTimeoutMs = stallTimeoutMs\(\), ticket = ticket\)/g) || []).length === 6 &&
    orchestrator.includes('var stallTimeoutMs: () -> Long = { DEFAULT_STALL_TIMEOUT_MS }'),
  'Android engine loads and seeks must all pass prepareTimeoutMs() and stallTimeoutMs(), never a fixed timeout.'
);

// Every engine wait gives up on a stall (no bytes downloaded, nothing buffered) or at its cap.
const engineSource = read('android/src/main/java/com/doublesymmetry/trackplayer/service/AndroidCrossfadeEngine.kt');
const stallWatchSource = read('android/src/main/java/com/doublesymmetry/trackplayer/service/StallWatch.kt');
const enginePrepare = section(engineSource, 'override suspend fun prepare(', 'override fun play(rate: Float)');
const engineSeek = section(engineSource, 'override suspend fun seekTo(', 'override fun setVolume(');
for (const [label, wait] of [['load', enginePrepare], ['seek', engineSeek]]) {
  assert(
    wait.includes('awaitWhileProgressing(') &&
      wait.includes('stallTimeoutMs = stallTimeoutMs,') &&
      wait.includes('totalTimeoutMs = timeoutMs,') &&
      wait.includes('pollIntervalMs = ENGINE_WAIT_POLL_INTERVAL_MS,') &&
      wait.includes('readings = ::loadProgress') &&
      wait.includes('if (verdict != null) {') &&
      !wait.includes('elapsedRealtime() - startedAt'),
    `Android engine ${label} must wait with the stall watch (stallTimeoutMs, prepareTimeoutMs as cap), not a fixed total.`
  );
}
assert(
  engineSource.includes('longArrayOf(bytesLoaded.get(), player.bufferedPosition, player.totalBufferedDuration)') &&
    engineSource.includes('bytesLoaded.addAndGet(bytesTransferred.toLong())') &&
    engineSource.includes('.setTransferListener(object : TransferListener {') &&
    stallWatchSource.includes('val watch = StallWatch(stallTimeoutMs, totalTimeoutMs, nowMs())') &&
    stallWatchSource.includes('val verdict = watch.check(nowMs(), readings())'),
  'Android engine waits must read downloaded bytes and buffered media as progress.'
);

// Every crossfade track starts from the app's current low bandwidth estimate
// (initialBitrateEstimateBps), from setup or updateOptions, without rebuilding the players.
const perTrackMeter = read('android/src/main/java/com/doublesymmetry/trackplayer/service/PerTrackBandwidthMeter.kt');
const startTrack = section(perTrackMeter, 'fun startTrack(): Long {', 'override fun getBitrateEstimate()');
assert(
  engineSource.includes('.setBandwidthMeter(bandwidthMeter)') &&
    engineSource.includes('private val bandwidthMeter = PerTrackBandwidthMeter(initialBitrateEstimateBps) { estimate ->\n        crossfadeBandwidthMeter(context, estimate)') &&
    enginePrepare.includes('val initialEstimate = bandwidthMeter.startTrack()') &&
    enginePrepare.includes('androidXfadeLog("$name track start initialBitrateEstimateBps=$initialEstimate")') &&
    enginePrepare.indexOf('bandwidthMeter.startTrack()') < enginePrepare.indexOf('player.setMediaItem(buildMediaItem(item))') &&
    section(engineSource, 'internal fun crossfadeBandwidthMeter(', '/**').includes('.setInitialBitrateEstimate(initialBitrateEstimateBps)') &&
    startTrack.includes('val estimate = initialBitrateEstimateBps()') &&
    startTrack.includes('val fresh = newMeter(estimate)') &&
    startTrack.includes('current = fresh') &&
    perTrackMeter.includes('override fun getBitrateEstimate(): Long = current.bitrateEstimate') &&
    perTrackMeter.includes('override fun getTransferListener(): TransferListener = this') &&
    read('android/src/androidTest/java/com/doublesymmetry/trackplayer/service/CrossfadeBandwidthMeterInstrumentationTest.kt').includes('crossfadeBandwidthMeter(context, estimate).bitrateEstimate') &&
    orchestrator.includes('initialBitrateEstimateBps: () -> Long,') &&
    orchestrator.includes('AndroidCrossfadeEngine(context, "engineA", audioContentType, handleAudioFocus, initialBitrateEstimateBps, requestStallTimeoutMs)') &&
    orchestrator.includes('AndroidCrossfadeEngine(context, "engineB", audioContentType, handleAudioFocus, initialBitrateEstimateBps, requestStallTimeoutMs)') &&
    musicService.includes('private val initialBitrateEstimate = BitrateSetting(DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS)') &&
    musicService.includes('initialBitrateEstimateBps = { initialBitrateEstimate.bitsPerSecond },') &&
    section(musicService, 'private fun applyTimeouts(options: Bundle?)', '@MainThread').includes('applyTimeout(options, INITIAL_BITRATE_ESTIMATE_KEY, initialBitrateEstimate)'),
  'Android crossfade tracks must each start from the current initialBitrateEstimateBps (setupPlayer and updateOptions).'
);

// The app's load timeout (prepareTimeoutMs) reaches every orchestrator, from setup (even when the
// service is already set up) and from updateOptions.
const setupPlayerSection = section(musicService, 'fun setupPlayer(playerOptions: Bundle?)', 'val bufferConfig');
const updateOptionsSection = section(musicService, 'fun updateOptions(options: Bundle)', 'val androidOptions');
const applyTimeoutSection = section(musicService, 'private fun applyTimeouts(options: Bundle?)', '@MainThread');
assert(
  musicService.includes('private val prepareTimeout = TimeoutSetting(DEFAULT_PREPARE_TIMEOUT_MS)') &&
    musicService.includes('created.prepareTimeoutMs = { prepareTimeout.milliseconds }') &&
    setupPlayerSection.indexOf('applyTimeouts(playerOptions)') >= 0 &&
    setupPlayerSection.indexOf('applyTimeouts(playerOptions)') < setupPlayerSection.indexOf('if (isPrimaryPlayerInitialized())') &&
    updateOptionsSection.includes('applyTimeouts(options)') &&
    applyTimeoutSection.includes('applyTimeout(options, PREPARE_TIMEOUT_KEY, prepareTimeout)') &&
    applyTimeoutSection.includes('applyTimeout(options, STANDARD_READY_TIMEOUT_KEY, standardReadyTimeout)') &&
    applyTimeoutSection.includes('applyTimeout(options, STALL_TIMEOUT_KEY, stallTimeout)') &&
    musicService.includes('private val stallTimeout = TimeoutSetting(DEFAULT_STALL_TIMEOUT_MS)') &&
    musicService.includes('created.stallTimeoutMs = { stallTimeout.milliseconds }') &&
    section(musicService, 'private fun applyTimeout(options: Bundle?, key: String, setting: WholeNumberSetting)', '@MainThread').includes('setting.apply(value)') &&
    section(musicService, 'private fun applyTimeout(options: Bundle?, key: String, setting: WholeNumberSetting)', '@MainThread').includes('if (options?.containsKey(key) == true) options.get(key) else return'),
  'Android prepareTimeoutMs must be taken at setup (before the early return) and on updateOptions, and read by every orchestrator.'
);

// The standard backend's readiness wait reads the app's settings (standardReadyTimeoutMs as the
// cap, stallTimeoutMs) and the player's buffered position as progress.
const runtimeSource = read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt');
const gateAwait = section(runtimeSource, 'suspend fun await(', 'private fun notReadyError()');
assert(
  musicService.includes('private val standardReadyTimeout = TimeoutSetting(DEFAULT_STANDARD_READY_TIMEOUT_MS)') &&
    musicService.includes('readinessGate = StandardPlaybackReadinessGate(\n                        timeoutMs = { standardReadyTimeout.milliseconds },\n                        stallTimeoutMs = { stallTimeout.milliseconds }\n                    ),') &&
    runtimeSource.includes('private val timeoutMs: () -> Long,') &&
    runtimeSource.includes('private val stallTimeoutMs: () -> Long,') &&
    gateAwait.includes('stallTimeoutMs = stallTimeoutMs(),') &&
    gateAwait.includes('totalTimeoutMs = timeoutMs(),') &&
    gateAwait.includes('readings = { longArrayOf(current?.bufferedPositionMs ?: 0L) }') &&
    !gateAwait.includes('withTimeoutOrNull') &&
    standardBackend.includes('bufferedPositionMs = player.bufferedPosition') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/KotlinAudioPlaybackBackend.kt').includes('private val readinessGate: StandardPlaybackReadinessGate,') &&
    standardBackend.includes('        readinessGate.await(index, snapshot.positionMs) {'),
  'Android standard readiness wait must read standardReadyTimeoutMs and stallTimeoutMs, not a fixed total.'
);

for (const option of ['stallTimeoutMs', 'initialBitrateEstimateBps']) {
  assert(
    read('src/interfaces/PlayerOptions.ts').includes(`${option}?: number;`) &&
      read('docs/docs/api/objects/player-options.md').includes(`| \`${option}\` |`),
    `${option} must be typed and documented.`
  );
}
assert(
  ['stallTimeoutMs', 'initialBitrateEstimateBps'].every((option) =>
    read('src/interfaces/UpdateOptions.ts').includes(`${option}?: number;`) &&
      read('docs/docs/api/objects/update-options.md').includes(`| \`${option}\` |`)),
  'stallTimeoutMs and initialBitrateEstimateBps must be accepted by updateOptions.'
);

// The crossfade fallback grace is the app's incomingStallGraceMs, read at every fade step.
assert(
  orchestrator.includes('var incomingStallGraceMs: () -> Long = { DEFAULT_INCOMING_STALL_GRACE_MS }') &&
    orchestrator.includes('if (elapsedMs >= incomingStallGraceMs() &&') &&
    !orchestrator.includes('INCOMING_STALL_GRACE_MS =') &&
    musicService.includes('private val incomingStallGrace = TimeoutSetting(DEFAULT_INCOMING_STALL_GRACE_MS)') &&
    musicService.includes('created.incomingStallGraceMs = { incomingStallGrace.milliseconds }') &&
    section(musicService, 'private fun applyTimeouts(options: Bundle?)', '@MainThread').includes('applyTimeout(options, INCOMING_STALL_GRACE_KEY, incomingStallGrace)') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt').includes('fun aCrossfadeFallsBackAfterTheIncomingStallGraceTheAppSet()'),
  'Android crossfade fallback must read incomingStallGraceMs.'
);

// A transfer is tracked from its start to its end only: a failed open is not kept.
assert(
  section(perTrackMeter, 'override fun onTransferInitializing(', 'override fun onTransferStart(').indexOf('transfers[') < 0 &&
    section(perTrackMeter, 'override fun onTransferStart(', 'override fun onBytesTransferred(').includes('transfers[source] = meter') &&
    section(perTrackMeter, 'override fun onTransferEnd(', '\n}').includes('transfers.remove(source)'),
  'PerTrackBandwidthMeter must track a transfer from its start to its end only.'
);

// The crossfade players' HTTP connect/read timeouts follow the current stallTimeoutMs at every
// request: each request builds its DefaultHttpDataSource at open() with the value read then.
const perRequestHttp = read('android/src/main/java/com/doublesymmetry/trackplayer/service/CurrentTimeoutHttpDataSource.kt');
const perRequestOpen = section(perRequestHttp, 'override fun open(dataSpec: DataSpec): Long {', 'override fun read(');
assert(
  engineSource.includes('private val httpDataSourceFactory = CurrentTimeoutHttpDataSourceFactory(stallTimeoutMs)') &&
    engineSource.includes('DefaultDataSource.Factory(context, httpDataSourceFactory)') &&
    perRequestOpen.includes('val source = openRequestSource()') &&
    perRequestOpen.indexOf('listeners.forEach(source::addTransferListener)') < perRequestOpen.indexOf('return source.open(dataSpec)') &&
    section(perRequestHttp, 'private fun openRequestSource(): DataSource {', 'private inner class').includes('val timeoutMs = httpTimeoutMs(stallTimeoutMs())') &&
    perRequestHttp.includes('factory.setConnectTimeoutMs(timeoutMs).setReadTimeoutMs(timeoutMs).createDataSource()') &&
    perRequestHttp.includes('override fun createDataSource(): DataSource = PerRequestSource()') &&
    !/set(Connect|Read)TimeoutMs\(\d/.test(engineSource + perRequestHttp) &&
    orchestrator.includes('AndroidCrossfadeEngine(context, "engineA", audioContentType, handleAudioFocus, initialBitrateEstimateBps, requestStallTimeoutMs)') &&
    orchestrator.includes('AndroidCrossfadeEngine(context, "engineB", audioContentType, handleAudioFocus, initialBitrateEstimateBps, requestStallTimeoutMs)') &&
    musicService.includes('requestStallTimeoutMs = { stallTimeout.milliseconds },') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/CrossfadeHttpTimeoutsTest.kt').includes('fun aSourceCreatedBeforeAnOptionsChangeOpensWithTheNewTimeout()'),
  'Android crossfade HTTP timeouts must follow the current stallTimeoutMs at every request.'
);

// Android waits for a play to start (playStartTimeoutMs) and for a standard seek
// (standardSeekTimeoutMs), with the stall rule, as iOS does.
const playSection = section(orchestrator, 'suspend fun play() = withPlaybackOperation', 'private suspend fun awaitPlaybackStart(');
assert(
  playSection.includes('activeEngine.play(rate)\n        awaitPlaybackStart(ticket)\n        setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)') &&
    orchestrator.includes('            activeEngine.play(rate)\n            awaitPlaybackStart(ticket)\n            setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)') &&
    section(orchestrator, 'private suspend fun awaitPlaybackStart(', '\n    }\n').includes('activeEngine.awaitPlaying(timeoutMs = playStartTimeoutMs(), stallTimeoutMs = stallTimeoutMs(), ticket = ticket)') &&
    orchestrator.includes('var playStartTimeoutMs: () -> Long = { DEFAULT_PLAY_START_TIMEOUT_MS }') &&
    section(engineSource, 'override suspend fun awaitPlaying(', 'override fun pause()').includes('readings = { loadProgress() + longArrayOf(positionMs) }') &&
    section(engineSource, 'override suspend fun awaitPlaying(', 'override fun pause()').includes('player.pause()') &&
    section(orchestrator, '            incomingEngine.play(rate)\n', 'currentIndex = toIndex').includes('incomingEngine.awaitPlaying(timeoutMs = playStartTimeoutMs(), stallTimeoutMs = stallTimeoutMs(), ticket = ticket)') &&
    section(orchestrator, '            incomingEngine.play(rate)\n', 'currentIndex = toIndex').includes('emitCrossfade("error", fromIndex, toIndex, errorCode = "crossfade_start_failed")') &&
    musicService.includes('private val playStartTimeout = TimeoutSetting(DEFAULT_PLAY_START_TIMEOUT_MS)') &&
    musicService.includes('created.playStartTimeoutMs = { playStartTimeout.milliseconds }') &&
    section(musicService, 'private fun applyTimeouts(options: Bundle?)', '@MainThread').includes('applyTimeout(options, PLAY_START_TIMEOUT_KEY, playStartTimeout)') &&
    section(musicService, 'private fun applyTimeouts(options: Bundle?)', '@MainThread').includes('applyTimeout(options, STANDARD_SEEK_TIMEOUT_KEY, standardSeekTimeout)') &&
    musicService.includes('seekGate = StandardSeekGate(\n                        timeoutMs = { standardSeekTimeout.milliseconds },\n                        stallTimeoutMs = { stallTimeout.milliseconds }') &&
    section(standardBackend, 'override suspend fun seekTo(positionMs: Long) {', '\n    }\n').includes('player.seek(positionMs, TimeUnit.MILLISECONDS)\n        seekGate.await(positionMs) {') &&
    section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal class StandardSeekGate(', 'internal class PlaybackOperationCancelledException').includes('readings = { longArrayOf(current?.bufferedPositionMs ?: 0L) }'),
  'Android must wait for a play start and a standard seek like iOS.'
);

// The standard player is the vendored KotlinAudio, with the same start-low and per-request
// HTTP timeouts as the crossfade players.
const buildGradle = read('android/build.gradle');
const vendoredBase = read('android/src/vendor/kotlinaudio/java/com/doublesymmetry/kotlinaudio/players/BaseAudioPlayer.kt');
const standardHooks = section(musicService, 'private fun standardPlayerHooks() = PlayerHooks(', '/**');
assert(
  !buildGradle.includes("com.github.doublesymmetry:kotlinaudio") &&
    buildGradle.includes("java.srcDirs += 'src/vendor/kotlinaudio/java'") &&
    buildGradle.includes("res.srcDirs += 'src/vendor/kotlinaudio/res'") &&
    read('android/src/vendor/kotlinaudio/LICENSE').includes('Apache License') &&
    read('android/src/vendor/kotlinaudio/VENDORED.md').includes('bf71120704bfe4be2311cf86fc1e2ee1c3c702b7') &&
    vendoredBase.includes('hooks.configureExoPlayer(this)\n            }\n            .build()') &&
    vendoredBase.includes('val tempFactory = hooks.httpDataSourceFactory?.invoke(configureHttp)') &&
    musicService.includes('QueuedAudioPlayer(this@MusicService, playerConfig, bufferConfig, cacheConfig, standardPlayerHooks())') &&
    standardHooks.includes('StartLowTrackSelectionFactory({ initialBitrateEstimate.bitsPerSecond })') &&
    standardHooks.includes('configureExoPlayer = { builder ->\n            builder.setTrackSelector(\n                DefaultTrackSelector(') &&
    standardHooks.includes('httpDataSourceFactory = standardHttpDataSourceFactory({ stallTimeout.milliseconds })') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('StartLowBandwidthMeter(bandwidthMeter, initialBitrateEstimateBps())') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelectionTest.kt').includes('fun everyTrackSelectionReadsTheCurrentSetting()') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/CrossfadeHttpTimeoutsTest.kt').includes('fun theStandardPlayersRequestsKeepKotlinAudiosConfigurationAndFollowTheCurrentStallTimeout()'),
  'The Android standard player must start each track low and follow stallTimeoutMs per request, like the crossfade path.'
);

// Calls, other apps' audio and headphones (DJE-204/205/206): one policy for both backends, one
// focus holder for the crossfade orchestrator (none per engine), the same remote-duck meaning.
const applyInterruptionKt = section(musicService, 'private fun applyInterruption(', '/**');
assert(
  musicService.includes('private val interruptionPolicy = InterruptionPolicy { autoHandleInterruptions }') &&
    musicService.includes('autoHandleInterruptions = handleAudioFocus') &&
    musicService.includes('            handleAudioFocus = false,\n            audioContentType = audioContentType') &&
    musicService.includes('orchestratorHandlesAudioFocus = false\n        registerBecomingNoisyReceiver()') &&
    musicService.includes('onAudioFocusChange = { onAudioFocusChange(it) }') &&
    musicService.includes('applyInterruption { isPlaying -> interruptionPolicy.onFocusChange(focusChange, isPlaying) }') &&
    musicService.includes('applyInterruption { isPlaying -> interruptionPolicy.noisy(isPlaying) }') &&
    musicService.includes('IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)') &&
    applyInterruptionKt.includes('val decision = decide(backend.playWhenReady)') &&
    applyInterruptionKt.includes('InterruptionAction.PAUSE -> backend.pause()') &&
    applyInterruptionKt.includes('if (backend.type == PlaybackBackendType.PING_PONG) orchestratorFocus.requestIfNeeded()\n                            backend.play()') &&
    applyInterruptionKt.includes('putBoolean(IS_FOCUS_LOSS_PERMANENT_KEY, duck.permanent)') &&
    ['suspend fun play() {\n        interruptionPolicy.userCommand()', 'suspend fun pause() {\n        interruptionPolicy.userCommand()',
      'suspend fun setPlayWhenReady(value: Boolean) {\n        interruptionPolicy.userCommand()',
      'suspend fun stop() {\n        interruptionPolicy.userCommand()\n        orchestratorFocus.abandon()'].every((s) => musicService.includes(s)) &&
    musicService.includes('if (backend.type == PlaybackBackendType.PING_PONG) orchestratorFocus.requestIfNeeded()\n            backend.play()') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/OrchestratorAudioFocus.kt').includes('.setWillPauseWhenDucked(true)') &&
    vendoredBase.includes('hooks.onAudioFocusChange?.let { onChange ->') &&
    vendoredBase.includes('.setWillPauseWhenDucked(playerOptions.alwaysPauseOnInterruption || hooks.onAudioFocusChange != null)') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/InterruptionPolicyTest.kt').includes('scripts/fixtures/interruption-scenarios.json'),
  'Android interruptions must go through InterruptionPolicy on both backends, with one focus holder for the orchestrator.'
);

console.log('Android crossfade contracts OK');
