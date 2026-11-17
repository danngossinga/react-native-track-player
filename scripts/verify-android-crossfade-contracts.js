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
    (orchestrator.match(/timeoutMs = prepareTimeoutMs\(\)/g) || []).length === 4 &&
    (orchestrator.match(/timeoutMs = prepareTimeoutMs\(\), stallTimeoutMs = stallTimeoutMs\(\), ticket = ticket\)/g) || []).length === 4 &&
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
    musicService.includes('readinessGate = StandardPlaybackReadinessGate(\n                        timeoutMs = { standardReadyTimeout.milliseconds },\n                        stallTimeoutMs = { stallTimeout.milliseconds },\n                        positionToleranceMs = { backendSwitchPositionTolerance.milliseconds }\n                    ),') &&
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
    // The track's headers and user agent (configure) reach every request.
    section(perRequestHttp, 'private fun openRequestSource(): DataSource {', 'private inner class').includes('return synchronized(http) { newRequestSource(http, timeoutMs) }') &&
    section(perRequestHttp, 'fun configure(', 'override fun createDataSource()').includes('synchronized(http) { http.change() }') &&
    section(engineSource, 'private fun configureRequestOptions(', '\n    }\n').includes('httpDataSourceFactory.configure {\n            setDefaultRequestProperties(options?.headers ?: emptyMap())') &&
    section(perRequestHttp, 'override fun close() {', '\n        }\n').includes('source?.close()') &&
    section(perRequestHttp, 'override fun addTransferListener(', 'override fun open(').includes('current?.addTransferListener(transferListener)') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/CrossfadeHttpTimeoutsTest.kt').includes('fun eachRequestCarriesTheTracksHeadersAndUserAgent()') &&
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
const playSection = section(orchestrator, 'private suspend fun playFromStill() = withPlaybackOperation', 'private suspend fun awaitPlaybackStart(');
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
    standardBackend.includes('override suspend fun seekTo(positionMs: Long) = seekGate.seek(seekPlayer, positionMs)') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt').includes('    if (item != null && player.kotlinAudioState == AudioPlayerState.STOPPED) player.prepare()\n    if (item != null) player.seekTo(positionMs)\n    await(positionMs, item) { player.seekObservation() }') &&
    // A skip ends a seek in progress at once (standard_seek_cancelled), as on iOS.
    (section(standardBackend, 'override suspend fun skip(index: Int) {', 'override suspend fun seekBy(').match(/seekGate\.cancel\("skip"\)/g) || []).length === 3 &&
    // So do a pause, a stop, a load and a relative seek (iOS: cancelPendingSeeks).
    ['seekGate.cancel("pause")\n        player.pause()', 'seekGate.cancel("stop")\n        player.stop()',
      'seekGate.cancel("load")\n        runActivatingOperation('].every((s) => standardBackend.includes(s)) &&
    // seekBy is a waited seek with the same limits, as on iOS.
    standardBackend.includes('override suspend fun seekBy(offsetMs: Long) = seekTo(maxOf(0L, player.position + offsetMs))') &&
    // At the target: no fixed tolerance (what playback played since the seek, plus one poll).
    !section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal class StandardSeekGate(', 'internal interface StandardSeekPlayer {').includes('positionToleranceMs') &&
    section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal class StandardSeekGate(', 'internal class PlaybackOperationCancelledException').includes('isAtSeekTarget(observed.positionMs, target, playedMs.toLong())') &&
    standardBackend.includes('override val rate: Float get() = player.playbackSpeed') &&
    // A play after the queue ended starts the current track from 0, as on iOS.
    section(orchestrator, 'private suspend fun playFromStill() = withPlaybackOperation', 'private suspend fun awaitPlaybackStart(').includes('if (state == AndroidPlaybackOrchestratorState.ENDED) {') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt').includes('fun aPlayAfterTheQueueEndedStartsTheLastTrackAgainFromTheStartAsOnIos()') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntimePrimitivesTest.kt').includes('fun aNewerSeekASkipOrAnotherItemEndsTheOlderSeekAtOnce()') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntimePrimitivesTest.kt').includes('fun aStandardSeekThatReachesTheEndOfTheTrackCompletes()') &&
    // The real engine pauses when its play start gives up.
    section(engineSource, 'override suspend fun awaitPlaying(', 'override fun pause()').includes('if (verdict != null) {\n            // Audio must not start by itself later, as on iOS.\n            player.playWhenReady = false\n            player.pause()') &&
    // A natural advance is an operation: a pause during the next track's start cancels it.
    section(orchestrator, 'private suspend fun monitorActiveEngine()', 'private fun cancelCrossfade(').includes('val ticket = beginOperation()\n        try {\n            startTrackAt(nextIndex, 0L, emitTrackChange = true, oldPositionMs = endedPositionMs, ticket = ticket)') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt').includes('fun aPauseDuringTheNextTracksStartCancelsItWithNoPlaybackError()') &&
    section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal class StandardSeekGate(', 'internal class PlaybackOperationCancelledException').includes('readings = { longArrayOf(latest?.bufferedPositionMs ?: 0L) }'),
  'Android must wait for a play start and a standard seek like iOS.'
);

// The standard player is the vendored KotlinAudio, with the same start-low and per-request
// HTTP timeouts as the crossfade players.
const buildGradle = read('android/build.gradle');
const vendoredBase = read('android/src/vendor/kotlinaudio/java/com/doublesymmetry/kotlinaudio/players/BaseAudioPlayer.kt');
const standardHooks = section(musicService, 'private fun standardPlayerHooks(analytics: StandardPlayerAnalytics) = PlayerHooks(', '/**');
assert(
  !buildGradle.includes("com.github.doublesymmetry:kotlinaudio") &&
    buildGradle.includes("java.srcDirs += 'src/vendor/kotlinaudio/java'") &&
    buildGradle.includes("res.srcDirs += 'src/vendor/kotlinaudio/res'") &&
    read('android/src/vendor/kotlinaudio/LICENSE').includes('Apache License') &&
    read('android/src/vendor/kotlinaudio/VENDORED.md').includes('bf71120704bfe4be2311cf86fc1e2ee1c3c702b7') &&
    vendoredBase.includes('hooks.configureExoPlayer(this)\n            }\n            .build()') &&
    vendoredBase.includes('val tempFactory = hooks.httpDataSourceFactory?.invoke(configureHttp)') &&
    musicService.includes('QueuedAudioPlayer(this@MusicService, playerConfig, bufferConfig, cacheConfig, standardPlayerHooks(analytics))') &&
    // Start-low per track: each media period's own media loads (not its manifest, not another's).
    standardHooks.includes('val startLow = StandardStartLow(\n                { initialBitrateEstimate.bitsPerSecond },') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('    val meter: BandwidthMeter = newMeter(unmeasuredBps)\n    val selectionFactory = StartLowTrackSelectionFactory(initialBitrateEstimateBps, loads, unmeasuredBps, adaptive)') &&
    standardHooks.includes('newMeter = { bps -> DefaultBandwidthMeter.Builder(this@MusicService).setInitialBitrateEstimate(bps).build() }') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('return if (hasMeasured && estimate != unmeasuredEstimateBps) estimate else initialEstimateBps') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('loads.retainPeriodsOf(eventTime.timeline)') &&
    standardHooks.includes('builder.setBandwidthMeter(startLow.meter)\n            builder.setTrackSelector(DefaultTrackSelector(this@MusicService, startLow.selectionFactory))\n            analytics.addListener(startLow.loadListener)\n            builder.setAnalyticsCollector(analytics)') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt').includes('        super.setPlayer(player, looper)\n        this.player = player') &&
    musicService.includes('                        standardAnalytics.remove(disposed)') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('hasOwnMeasurement = { loads.hasMeasured(mediaPeriodId) }') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('if (mediaLoadData.dataType != C.DATA_TYPE_MEDIA) return\n        eventTime.mediaPeriodId?.let(loads::mediaLoaded)') &&
    ['fun theNextTrackPreparedAheadStartsLowUntilItsOwnMediaIsLoaded()', 'fun twoEqualItemsInTheQueueAreMeasuredApart()', 'fun aReplayedTrackStartsLowAgain()']
      .every((t) => read('android/src/test/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelectionTest.kt').includes(t)) &&
    // A seek at the end with repeat-one, and a seek while stopped, as on iOS.
    section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal class StandardSeekGate(', 'internal class PlaybackOperationCancelledException').includes('if (observed.autoTransitions > startTransitions) return@awaitWhileProgressing true') &&
    // ExoPlayer's own state (masked at once by seekTo), not KotlinAudio's (a message later).
    standardBackend.includes('override val exo: ExoSeekState = CapturedExoSeekState { analytics()?.player }') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt').includes('exo.playbackState == com.google.android.exoplayer2.Player.STATE_READY && exo.isPlaying -> AudioPlayerState.PLAYING') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt').includes('observed.state != AudioPlayerState.IDLE &&') &&
    standardBackend.includes('override val autoTransitions: Long get() = analytics()?.transitions?.count ?: 0L') &&
    musicService.includes('analytics = { standardAnalytics[binding.player] },') &&
    musicService.includes('.also { standardAnalytics[it] = analytics }') &&
    // backendSwitchPositionToleranceMs on both Android backends' restores, as on iOS.
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/PingPongPlaybackBackend.kt').includes('if (indexChanged || kotlin.math.abs(orchestrator.positionMs - snapshot.positionMs) > positionToleranceMs()) {') &&
    standardBackend.includes('val steps = standardRestoreSteps(') && standardBackend.includes('positionToleranceMs = positionToleranceMs()\n            )\n            if (steps.jump) player.jumpToItem(index)\n            if (steps.seek) player.seek(snapshot.positionMs, TimeUnit.MILLISECONDS)') &&
    (musicService.match(/positionToleranceMs = \{ backendSwitchPositionTolerance\.milliseconds \},/g) || []).length === 2 &&
    // Unplugging pauses through the service's receiver only (KotlinAudio's own handling off).
    musicService.includes('            handleAudioBecomingNoisy = false,') &&
    // The restored-position tolerance at a backend switch is the app's setting.
    musicService.includes('positionToleranceMs = { backendSwitchPositionTolerance.milliseconds }') &&
    section(musicService, 'private fun applyTimeouts(options: Bundle?)', '@MainThread').includes('applyTimeout(options, BACKEND_SWITCH_POSITION_TOLERANCE_KEY, backendSwitchPositionTolerance)') &&
    !/positionToleranceMs: Long = \d/.test(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt')) &&
    standardHooks.includes('configureExoPlayer = { builder ->') &&
    true &&
    standardHooks.includes('httpDataSourceFactory = standardHttpDataSourceFactory({ stallTimeout.milliseconds })') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('StartLowBandwidthMeter(\n            bandwidthMeter,\n            initialBitrateEstimateBps(),') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelectionTest.kt').includes('fun everyTrackSelectionReadsTheCurrentSetting()') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/CrossfadeHttpTimeoutsTest.kt').includes('fun theStandardPlayersRequestsKeepKotlinAudiosConfigurationAndFollowTheCurrentStallTimeout()'),
  'The Android standard player must start each track low and follow stallTimeoutMs per request, like the crossfade path.'
);

// Calls, other apps' audio and headphones (DJE-204/205/206): one policy and one audio focus for
// both backends (KotlinAudio and the engines hold none), the same remote-duck meaning, and every
// user play, pause, stop and reset (app or remote control) through the same service paths.
const applyInterruptionKt = section(musicService, 'private fun applyInterruption(', '/**');
const coordinatorKt = read('android/src/main/java/com/doublesymmetry/trackplayer/service/InterruptionCoordinator.kt');
const focusKt = read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackAudioFocus.kt');
const remoteSurface = section(musicService, 'override fun onRemotePlay() =', 'override fun onRemoteNext() =');
const userCommandsKt = section(musicService, 'suspend fun play() {', 'suspend fun removeUpcomingTracks()');
assert(
  musicService.includes('autoResume = { autoHandleInterruptions },\n            focusRequester = SystemAudioFocusRequester(this) { focusContentType },\n            noisyReceiver = ContextNoisyReceiverRegistrar(this),\n            onInterruption = ::applyInterruption') &&
    musicService.includes('autoHandleInterruptions = handleAudioFocus') &&
    musicService.includes('            handleAudioFocus = false,\n            audioContentType = audioContentType') &&
    musicService.includes('orchestratorHandlesAudioFocus = false\n        interruptions.start()') &&
    standardHooks.includes('hostOwnsAudioFocus = true') &&
    // KotlinAudio never takes the focus itself (upstream: at READY, even while paused).
    vendoredBase.includes('if (!playerConfig.handleAudioFocus && !hooks.hostOwnsAudioFocus) {\n                    when (value) {') &&
    !vendoredBase.includes('onAudioFocusChange?.') &&
    read('android/src/vendor/kotlinaudio/java/com/doublesymmetry/kotlinaudio/models/PlayerHooks.kt').includes('val hostOwnsAudioFocus: Boolean = false') &&
    // The only focus requests are the service's.
    !/requestAudioFocus\(/.test(musicService + orchestrator + engineSource) &&
    focusKt.includes('.setWillPauseWhenDucked(true)') &&
    focusKt.includes('AudioManager.AUDIOFOCUS_LOSS -> abandon()') &&
    coordinatorKt.includes('fun userPlay(): Boolean = policy.userPlay(activate = focus::requestIfNeeded) == UserPlayDecision.PLAY') &&
    coordinatorKt.includes('        if (userPlay()) {\n            play()\n        } else {\n            refuse()\n            throw audioFocusRefused()') &&
    coordinatorKt.includes('fun userStop() {\n        policy.userStop()\n        focus.abandon()') &&
    coordinatorKt.includes('fun userPause() {\n        policy.userPause()\n    }') &&
    coordinatorKt.includes('fun destroy() {\n        noisyReceiver.unregister()\n        focus.abandon()') &&
    coordinatorKt.includes('InterruptionAction.RESUME -> {\n                val granted = focus.requestIfNeeded()') &&
    coordinatorKt.includes('                if (!granted) {\n                    // Decision B: no play without the focus; reported, not retried.\n                    onResumeFailed(audioFocusRefused())\n                    return decision') &&
    coordinatorKt.includes('            playWhenReady = backend.playWhenReady,\n            state = backend.playbackState,') &&
    applyInterruptionKt.includes('interruptions.applyOn(\n                    facade = facade,\n                    scope = scope,') &&
    coordinatorKt.includes('val decision = decide(interruptionCountsAsPlaying(playWhenReady, state)) ?: return null') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/InterruptionPolicy.kt').includes('playWhenReady && state !in INTERRUPTION_FINISHED_STATES') &&
    // remote-duck when the pause is done, or before the resumed play is awaited (as on iOS).
    coordinatorKt.includes('val granted = focus.requestIfNeeded()\n                decision.duck?.let(emit)\n                if (!granted) {') &&
    coordinatorKt.includes('                    return decision\n                }\n                try {\n                    play()') &&
    focusKt.includes('.setContentType(contentType())') &&
    musicService.includes('SystemAudioFocusRequester(this) { focusContentType }') &&
    musicService.includes('focusContentType = focusContentTypeOf(playerConfig.audioContentType)') &&
    coordinatorKt.includes('            pause = { backend.pause() },\n            play = {\n                scope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {\n                    try {\n                        backend.play()') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/PlaybackBackendTransactionTest.kt').includes('fun aBackendSwitchDoesNotWaitForAnInterruptionResumeToStart()') &&
    applyInterruptionKt.includes('putBoolean(IS_FOCUS_LOSS_PERMANENT_KEY, duck.permanent)') &&
    // User commands: inside the admitted operation (ordered with the interruption events).
    userCommandsKt.includes('withActivePlaybackBackend { backend ->\n            playOn(backend)') &&
    userCommandsKt.includes('if (value) playOn(backend) else pauseOn(backend)') &&
    userCommandsKt.includes('withActivePlaybackBackend { backend ->\n            pauseOn(backend)') &&
    userCommandsKt.includes('withActivePlaybackBackend { backend ->\n            stopOn(backend)') &&
    userCommandsKt.includes('private suspend fun playOn(backend: AndroidPlaybackBackendRouting) {\n        // Decision B: refused focus, no play (paused, silent) and `audio_focus_refused`.\n        interruptions.playOrRefuse(play = { backend.play() }, refuse = { backend.pause() })') &&
    musicService.includes('            } catch (error: Exception) {\n                reportIfAudioFocusRefused(error)\n                androidXfadeLog("remote command failed') &&
    musicService.includes('                    onResumeFailed = {\n                        reportIfAudioFocusRefused(it)') &&
    section(musicService, 'private fun reportIfAudioFocusRefused(', '\n    }\n').includes('if (rejection.code != AUDIO_FOCUS_REFUSED) return\n        emit(MusicEvents.PLAYBACK_ERROR, Bundle().apply {') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/InterruptionCoordinatorTest.kt').includes('fun aPlayTheSystemRefusesDoesNotStartAndRejectsWithAudioFocusRefused()') &&
    userCommandsKt.includes('private suspend fun pauseOn(backend: AndroidPlaybackBackendRouting) {\n        interruptions.userPause()\n        backend.pause()') &&
    userCommandsKt.includes('private suspend fun stopOn(backend: AndroidPlaybackBackendRouting) {\n        interruptions.userStop()\n        backend.stop()') &&
    section(musicService, 'suspend fun reset() {', '@MainThread').includes('withActivePlaybackBackend { backend ->\n            interruptions.userStop()\n            backend.stop()') &&
    // Notification, lock screen, Bluetooth and headset commands take the same paths.
    remoteSurface.includes('runOrchestratedRemoteCommand(identity, "play", MusicEvents.BUTTON_PLAY) { playOn(it) }') &&
    remoteSurface.includes('runOrchestratedRemoteCommand(identity, "pause", MusicEvents.BUTTON_PAUSE) { pauseOn(it) }') &&
    remoteSurface.includes('stopOn(it)\n                    created.hide()') &&
    !/interruptionPolicy|orchestratorFocus|OrchestratorAudioFocus|onAudioFocusChanged/.test(musicService) &&
    section(musicService, 'override fun onDestroy() {', 'allPlayers().forEach { it.destroy() }').includes('interruptions.destroy()') &&
    !musicService.includes('alwaysPauseOnInterruption =') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/InterruptionPolicyTest.kt').includes('scripts/fixtures/interruption-scenarios.json') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/InterruptionCoordinatorTest.kt').includes('fun destroyUnregistersTheReceiverAndGivesTheFocusUp()'),
  'Android interruptions must go through one InterruptionCoordinator on both backends, with one focus holder for the service.'
);

// A stalled crossfade seek, as on iOS: the engine pauses and fails, the orchestrator reports an
// error instead of staying in seeking.
assert(
  section(engineSeek, 'if (verdict != null) {', 'throw RejectionException(').includes('player.playWhenReady = false\n            player.pause()') &&
    section(engineSeek, 'if (verdict != null) {', 'throw RejectionException(').includes('state = AndroidCrossfadeEngineState.FAILED') &&
    section(orchestrator, 'suspend fun seekTo(positionMs: Long)', 'suspend fun seekBy(').includes('} catch (error: RejectionException) {\n            // As on iOS: a seek that fails leaves the player in an error state (not seeking).\n            setState(AndroidPlaybackOrchestratorState.ERROR)\n            throw error') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt').includes('fun aStalledSeekLeavesThePlayerInErrorAsOnIos()'),
  'A stalled Android crossfade seek must pause, fail and leave the player in error, as on iOS.'
);

// Seventh review: exact pins where the code needs the Android runtime (KotlinAudio's player,
// the real ExoPlayer engine).
const engineAwaitPlaying = section(engineSource, 'override suspend fun awaitPlaying(', 'override fun pause()');
assert(
  // The seek adapter forwards the player's own readings.
  standardBackend.includes('        override val durationMs: Long get() = player.duration\n') &&
    standardBackend.includes('        override val bufferedPositionMs: Long get() = player.bufferedPosition\n') &&
    standardBackend.includes('        override val positionMs: Long get() = player.position\n') &&
    // The engine's play start: a player error fails at once (crossfade_engine_error), a reset
    // during the wait cancels it, and a give-up leaves the engine failed.
    engineAwaitPlaying.includes('            if (player.playerError != null) {\n                if (operationGeneration == generation) state = AndroidCrossfadeEngineState.FAILED\n                throw RejectionException(player.playerError?.message ?: "$name failed to play.", "crossfade_engine_error")\n            }\n            player.isPlaying') &&
    engineAwaitPlaying.includes('        ticket?.ensureActive()\n        if (operationGeneration != generation) throw PlaybackOperationCancelledException("engine_reset")\n        if (verdict != null) {') &&
    engineAwaitPlaying.includes('            player.playWhenReady = false\n            player.pause()\n            state = AndroidCrossfadeEngineState.FAILED\n'),
  'Android seventh-review pins must stay in place.'
);

// Eleventh review: every operation begins armed with the cancelled-operation clean-up (no
// bare operationController.begin() left), and that clean-up silences the engines.
assert(
  (orchestrator.match(/operationController\.begin\(\)/g) || []).length === 2 &&
    orchestrator.includes('operationController.begin().also(::stabilizeIfCancelled)') &&
    !/val \w+ = operationController\.begin\(\)/.test(orchestrator) &&
    section(orchestrator, 'private fun stabilizeIfCancelled(', '    /**').includes('                activeEngine.pause()\n                standbyEngine.pause()'),
  'Android orchestrator operations must all begin armed, and the clean-up must silence the engines.'
);

// Twelfth review: a failed load leaves no prepared track (play reloads, as iOS), a failed play
// start is silent, every active load goes through prepareActiveOrFail, and a crossfade error
// state carries no standard-player error (iOS sends {}).
assert(
  section(engineSource, 'override suspend fun prepare(', 'override fun play(rate: Float)').includes('        } catch (error: Exception) {\n            if (operationGeneration == generation && preparedTrackKey == trackKey) {\n                preparedItem = null\n                preparedTrackKey = null\n            }\n            throw error\n        }') &&
    section(orchestrator, 'private suspend fun awaitPlaybackStart(', '\n    }\n').includes('            playWhenReady = false\n            // Silent, as iOS (loadIndex\'s autoplay failure pauses the engine).\n            activeEngine.pause()\n            setState(AndroidPlaybackOrchestratorState.PAUSED)') &&
    (orchestrator.match(/activeEngine\.prepare\(/g) || []).length === 1 &&
    (orchestrator.match(/prepareActiveOrFail\(/g) || []).length === 4 &&
    musicService.includes('emit(MusicEvents.PLAYBACK_STATE, getPlayerStateBundle(state, includeStandardError = false))') &&
    musicService.includes('bundle.putBundle(ERROR_KEY, if (includeStandardError) getPlaybackErrorBundle() else Bundle())'),
  'Android twelfth-review fixes must stay in place.'
);

// Thirteenth review: setPlayWhenReady settles its promise like play (a refusal rejects), and
// every command that loads or moves the active track is a user play when it starts the audio
// (commandStartsPlayback), from the app or a remote control, as on iOS.
const androidModule = read('android/src/main/java/com/doublesymmetry/trackplayer/module/MusicModule.kt');
assert(
  section(androidModule, 'fun setPlayWhenReady(playWhenReady: Boolean, callback: Promise) {', '@ReactMethod').includes('completeCommand(callback) { musicService.setPlayWhenReady(playWhenReady) }') &&
    !section(androidModule, 'fun setPlayWhenReady(playWhenReady: Boolean, callback: Promise) {', '@ReactMethod').includes('callback.resolve') &&
    [['fun load(data: ReadableMap?', 'musicService.load('], ['fun skip(index: Double', 'musicService.skip('],
      ['fun skipToNext(initialTime: Double', 'musicService.skipToNext('], ['fun skipToPrevious(initialTime: Double', 'musicService.skipToPrevious('],
      ['fun seekTo(seconds: Double', 'musicService.seekTo('], ['fun seekBy(offset: Double', 'musicService.seekBy('],
      ['fun retry(callback: Promise', 'musicService.retry(']].every(([start, call]) => {
      const body = section(androidModule, start, '@ReactMethod');
      return body.indexOf('completeCommand(callback) {') >= 0 && body.indexOf('completeCommand(callback) {') < body.indexOf(call);
    }) &&
    section(coordinatorKt, 'suspend fun runStartingCommand(', '/** A pause from the user').includes('        if (!commandStartsPlayback(playWhenReady, state) || userPlay()) {\n            command()\n            return true\n        }\n        pause()\n        command()\n        return false') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/InterruptionPolicy.kt').includes('    playWhenReady && state in INTERRUPTION_FINISHED_STATES') &&
    section(musicService, 'private suspend fun runStartingCommand(', '@MainThread').includes('        if (!allowed) throw audioFocusRefused()') &&
    [['suspend fun load(track: Track)', 'runStartingCommand(backend, "load") { backend.load(track.toAudioItem()) }'],
      ['suspend fun skip(index: Int', 'runStartingCommand(backend, "skip") {\n                backend.skip(index)'],
      ['suspend fun skipToNext(', 'runStartingCommand(backend, "skip-next") {\n                backend.skipToNext()'],
      ['suspend fun skipToPrevious(', 'runStartingCommand(backend, "skip-previous") {\n                backend.skipToPrevious()'],
      ['suspend fun seekTo(seconds: Float)', 'runStartingCommand(backend, "seek-to") { backend.seekTo('],
      ['suspend fun seekBy(offset: Float)', 'runStartingCommand(backend, "seek-by") { backend.seekBy('],
      ['suspend fun retry()', 'runStartingCommand(backend, "retry") { backend.retry() }']].every(([start, call]) =>
      section(musicService, start, '@MainThread').includes(call)) &&
    (musicService.match(/runStartingCommand\(it, null\) \{ it\.(skipToNext|skipToPrevious|seekTo|seekBy)\(/g) || []).length === 5 &&
    section(musicService, 'private fun runOrchestratedRemoteCommand(', '@MainThread').includes('                if (refreshAfter && routedBackendType == PlaybackBackendType.PING_PONG) {\n                    refreshOrchestratedMediaSurface(reason = "remote-$reason")\n                }\n                refused?.let { throw it }') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/InterruptionCoordinatorTest.kt').includes('fun aSkipAfterTheFocusWasLostWhileTheQueueEndedIsRefusedAndSilent()') &&
    read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt').includes('fun aSkipAfterTheQueueEndedPausedFirstStaysSilent()'),
  'Android thirteenth-review fixes must stay in place.'
);

// Every track's headers and user agent reach the per-request HTTP source (set before the item).
{
  const prepareBody = section(engineSource, 'override suspend fun prepare(', 'override fun play(rate: Float)');
  const requestOptions = section(engineSource, 'private fun configureRequestOptions(', '\n    }\n');
  assert(
    prepareBody.includes('configureRequestOptions(item)') &&
      prepareBody.indexOf('configureRequestOptions(item)') < prepareBody.indexOf('player.setMediaItem(') &&
      requestOptions.includes('options?.userAgent?.takeIf { it.isNotBlank() }?.let { setUserAgent(it) }') &&
      requestOptions.includes('setDefaultRequestProperties'),
    'Android crossfade must give each track its headers and user agent before setting the item.'
  );
}

// The settings are read by the players' loading threads (HTTP timeouts): the value stays volatile.
assert(
  /internal open class WholeNumberSetting\(defaultValue: Long\) \{\s*@Volatile\s*var value: Long/.test(engineSource),
  'WholeNumberSetting.value must stay @Volatile: loading threads read it at every HTTP request.'
);

// An uncached adaptive track starts at its lowest rendition: the crossfade players' track
// selector lets audio renditions with unknown channel counts or sample rates (an HLS master
// playlist names neither) adapt from the bandwidth estimate. Pinned behaviour:
// android/robolectric-tests CrossfadeEngineHlsTest.anUncachedTrack...
{
  const builder = section(engineSource, 'val player: ExoPlayer = ExoPlayer.Builder(context)', '.build()');
  const parameters = section(engineSource, 'internal fun crossfadeTrackSelectorParameters(', '.build()');
  assert(
    builder.includes('.setTrackSelector(crossfadeTrackSelector(context))') &&
      builder.includes('.setBandwidthMeter(bandwidthMeter)') &&
      parameters.includes('.setAllowAudioMixedChannelCountAdaptiveness(true)') &&
      parameters.includes('.setAllowAudioMixedSampleRateAdaptiveness(true)') &&
      read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/CrossfadeEngineHlsTest.kt')
        .includes('fun anUncachedTrackAsksForItsFirstSegmentAtTheLowestRenditionHighestListedFirst()'),
    'Android crossfade players must select adaptively among audio renditions (lowest first at a low estimate).'
  );
}

// A load or seek an engine gives up on stops loading (no background retries) and forgets the
// track, as iOS removes the item.
{
  const abandon = section(engineSource, 'private fun abandonLoad(generation: Long) {', '\n    }\n');
  const prepareBody = section(engineSource, 'override suspend fun prepare(', 'override fun play(rate: Float)');
  const seekBody = section(engineSource, 'override suspend fun seekTo(', 'override fun setVolume(');
  assert(
    abandon.includes('if (operationGeneration != generation) return') &&
      abandon.includes('player.stop()') &&
      abandon.includes('preparedItem = null') &&
      abandon.includes('preparedTrackKey = null') &&
      prepareBody.includes('} catch (error: RejectionException) {\n            abandonLoad(generation)\n            throw error') &&
      section(prepareBody, 'if (verdict != null) {', 'throw RejectionException(').includes('abandonLoad(generation)') &&
      section(seekBody, 'if (verdict != null) {', 'throw RejectionException(').includes('abandonLoad(generation)'),
    'An Android engine that gives up on a load or seek must stop the player and forget the track.'
  );
}

// A track that fails to load leaves the player in error (as iOS); the load started when a track
// ends reports its failure as a playback-error (no command waits for it), as iOS.
{
  const startTrack = section(orchestrator, 'private suspend fun startTrackAt(', 'private suspend fun ensureActivePrepared(');
  const monitor = section(orchestrator, 'private suspend fun monitorActiveEngine() {', 'private suspend fun advanceToNextTrack(');
  const advance = section(orchestrator, 'private suspend fun advanceToNextTrack(', 'private fun cancelCrossfade(');
  assert(
    startTrack.includes('prepareActiveOrFail(queue[index], positionMs, ticket)') &&
      section(orchestrator, 'private suspend fun prepareActiveOrFail(', '\n    }\n').includes('        } catch (error: RejectionException) {') &&
      section(section(orchestrator, 'private suspend fun prepareActiveOrFail(', '\n    }\n'), '} catch (error: RejectionException) {', 'throw error').includes('setState(AndroidPlaybackOrchestratorState.ERROR)') &&
      monitor.includes('advanceToNextTrack(nextIndex, endedPosition)') &&
      !monitor.includes('startTrackAt(') &&
      advance.includes('val ticket = beginOperation()') &&
      advance.includes('if (state == AndroidPlaybackOrchestratorState.ERROR) delegate.onPlaybackError(error.code, error.message)') &&
      read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt').includes('fun aNaturalAdvanceWhosePlayStartStallsReportsOnePlaybackError()') &&
      advance.includes('operationController.finish(ticket)') &&
      musicService.includes('override fun onPlaybackError(code: String, message: String?) {') &&
      musicService.includes('emit(MusicEvents.PLAYBACK_ERROR, Bundle().apply {\n                        putString("code", code)'),
    'A failed Android natural advance must leave the player in error and emit playback-error.'
  );
}

console.log('Android crossfade contracts OK');
