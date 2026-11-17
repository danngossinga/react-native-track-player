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
    standardBackend.includes('override val currentIndex: Int\n        get() = if (failedLoads.isPending(player.currentItem)) reportedIndex() else logicalPlaybackState.currentIndex(player.currentIndex)') &&
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
    (orchestrator.match(/prepareActiveOrFail\(/g) || []).length === 4 &&
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
  engineSource.includes('longArrayOf(currentLoad.bytesLoaded.get(), player.bufferedPosition, player.totalBufferedDuration)') &&
    engineSource.includes('bytesLoaded.addAndGet(bytesTransferred.toLong())') &&
    engineSource.includes('val mediaListener: TransferListener = object : TransferListener {') &&
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
    enginePrepare.indexOf('bandwidthMeter.startTrack()') < enginePrepare.indexOf('player.setMediaSource(mediaSourceFactory.createMediaSource(buildMediaItem(item), load))') &&
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
    gateAwait.includes('val stallMs = stallTimeoutMs()') &&
    gateAwait.includes('stallTimeoutMs = stallMs,') &&
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
  engineSource.includes('private val httpDataSourceFactory = CurrentTimeoutHttpDataSourceFactory(stallTimeoutMs, requestSource)') &&
    engineSource.includes('requestSource: (DefaultHttpDataSource.Factory, Int) -> DataSource = ::httpSourceWithTimeouts') &&
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
    standardBackend.includes('        val cancelledWait = commandLoads.cancel()\n        failedLoads.command()\n        leaveCancelledLoad(cancelledWait, positionMs, actsOnReportedTrack = true)\n') &&
    // A skip, next, previous or load loads the player's own track (FailedLoadRule.skipped,
    // LOAD-16); a seek or stop acts on the active track (owner decision, 2026-11-17, LOAD-06;
    // StandardBackendHlsTest.aSeekAfterASkipThatGaveUp..., aStopAfterASkipThatGaveUp...).
    (standardBackend.match(/failedLoads\.skipped\(\)/g) || []).length === 4 &&
    (standardBackend.match(/failedLoads\.command\(\)/g) || []).length === 2 &&
    // With no active track (a cancel with none reported stopped the load): the seek rejects, the
    // player's own item does not load (StandardBackendHlsTest.aSeekCancellingASkipWithNoActiveTrack...).
    section(standardBackend, 'leaveCancelledLoad(cancelledWait, positionMs, actsOnReportedTrack = true)\n', 'seekGate.seekOrGiveUp(seekPlayer, positionMs) { error ->').includes('if (logicalPlaybackState.isIdle) {\n            seekGate.cancel("seek")\n            throw RejectionException("No active track is available for seeking.", STANDARD_SEEK_UNAVAILABLE_CODE)') &&
    // A seek that gives up, or finds its track failed to load, leaves that track failed: the next
    // play loads the active track (FailedLoadRule; StandardBackendHlsTest's seek-after-failed-skip tests).
    standardBackend.includes('player.failLoad(PlaybackError(error.code, error.message, fromHost = true), report = false)\n                // Its track failed (again): the next play loads the active track, as after a failed\n                // load (FailedLoadRule.failed changes nothing on the loaded track).\n                failLoadedTrack()') &&
    standardBackend.includes('if (error.code == STANDARD_SEEK_UNAVAILABLE_CODE && player.currentItem != null) failLoadedTrack()') &&
    // A seek, pause or stop that cancels a waiting skip or load goes back to the reported track,
    // releasing the cancelled track's source, or with none reported stops in idle (crossfade's
    // cancelled operation; standardCancelledLoad).
    standardBackend.includes('leaveCancelledLoad(commandLoads.cancel(), positionMs = null)\n        player.pause()') &&
    standardBackend.includes('leaveCancelledLoad(cancelledWait, positionMs = null, actsOnReportedTrack = true)\n        player.stop()') &&
    standardBackend.includes('when (val left = standardCancelledLoad(cancelledWait, player.currentItem, failedLoads.reported, actsOnReportedTrack)) {') &&
    standardBackend.includes('                player.jumpToItem(index, playWhenReady = false)\n                player.seek(position, TimeUnit.MILLISECONDS)\n                // Its source is released') &&
    standardBackend.includes('                player.releaseSource(cancelled)\n') &&
    standardBackend.includes('            StandardCancelledLoad.StopsInIdle -> {\n                player.stop()\n                logicalPlaybackState.enterIdle(player.items.size)') &&
    read('android/src/vendor/kotlinaudio/java/com/doublesymmetry/kotlinaudio/players/QueuedAudioPlayer.kt').includes('        exoPlayer.addMediaSource(index + 1, mediaSource)\n        exoPlayer.removeMediaItem(index)\n    }') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt').includes('    if (item != null && player.kotlinAudioState == AudioPlayerState.STOPPED) player.prepare()\n    if (item != null) player.seekTo(positionMs)\n    await(positionMs, item) { player.seekObservation() }') &&
    // A skip ends a seek in progress at once (standard_seek_cancelled), as on iOS.
    (section(standardBackend, 'override suspend fun skip(index: Int) {', 'override suspend fun seekBy(').match(/seekGate\.cancel\("skip"\)/g) || []).length === 3 &&
    // So do a pause, a stop, a load and a relative seek (iOS: cancelPendingSeeks).
    ['seekGate.cancel("pause")\n        // As crossfade\'s pause', 'seekGate.cancel("stop")\n        // As crossfade\'s stop',
      'seekGate.cancel("load")\n        runActivatingOperation('].every((s) => standardBackend.includes(s)) &&
    // seekBy is a waited seek with the same limits, as on iOS, relative to the position the app
    // reads (the reported track's while another loads: StandardBackendHlsTest.aSeekByDuringASkipsLoad...).
    standardBackend.includes('override suspend fun seekBy(offsetMs: Long) = seekTo(maxOf(0L, positionMs + offsetMs))') &&
    // The remote jump buttons are that seekBy (the standard notification's FORWARD/REWIND go to
    // JS, which calls seekBy).
    musicService.includes('{ runStartingCommand(it, null) { it.seekBy(interval * 1000L) } }') &&
    musicService.includes('{ runStartingCommand(it, null) { it.seekBy(-interval * 1000L) } }') &&
    // At the target: no fixed tolerance and not the sampling period (what playback played since
    // the seek and since the last reading).
    !section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal class StandardSeekGate(', 'internal interface StandardSeekPlayer {').includes('positionToleranceMs') &&
    section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal class StandardSeekGate(', 'internal class PlaybackOperationCancelledException').includes('standardSeekIsAtTarget(observed.positionMs, target, playedMs.toLong(), sinceLastMs.toLong())') &&
    // The seek and readiness waits sample every stallTimeoutMs / 10 and wake at every player event.
    (read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt').match(/pollIntervalMs \?: standardLoadSampleIntervalMs\(stallMs\)/g) || []).length === 2 &&
    !/pollIntervalMs: Long = \d/.test(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt')) &&
    section(standardBackend, 'fun startLoadWatch(handler: android.os.Handler) {', 'val watch = loadWatch ?: return').includes('seekGate.poke()\n                readinessGate.poke()') &&
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
const standardConfig = section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt'), 'internal fun configureStandardExoPlayer(', '\n}\n');
// The service's hooks are a shared function (the Robolectric tests build the player with it too).
const standardHooks = section(read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt'), 'internal fun standardPlayerHooks(', '\n)\n');
assert(
  !buildGradle.includes("com.github.doublesymmetry:kotlinaudio") &&
    buildGradle.includes("java.srcDirs += 'src/vendor/kotlinaudio/java'") &&
    buildGradle.includes("res.srcDirs += 'src/vendor/kotlinaudio/res'") &&
    read('android/src/vendor/kotlinaudio/LICENSE').includes('Apache License') &&
    read('android/src/vendor/kotlinaudio/VENDORED.md').includes('bf71120704bfe4be2311cf86fc1e2ee1c3c702b7') &&
    vendoredBase.includes('hooks.configureExoPlayer(this)\n            }\n            .build()') &&
    vendoredBase.includes('val tempFactory = hooks.httpDataSourceFactory?.invoke(configureHttp)') &&
    musicService.includes('QueuedAudioPlayer(\n                this@MusicService, playerConfig, bufferConfig, cacheConfig,\n                standardPlayerHooks(this@MusicService, analytics, { initialBitrateEstimate.bitsPerSecond }, { stallTimeout.milliseconds })\n            )') &&
    // Start-low per track: each media period's own media loads (not its manifest, not another's).
    standardHooks.includes('configureStandardExoPlayer(builder, context, initialBitrateEstimateBps, analytics)') &&
    standardConfig.includes('val startLow = StandardStartLow(\n        initialBitrateEstimateBps,') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('    val meter: BandwidthMeter = newMeter(unmeasuredBps)\n    val selectionFactory = StartLowTrackSelectionFactory(initialBitrateEstimateBps, loads, unmeasuredBps, adaptive)') &&
    standardConfig.includes('newMeter = { bps -> DefaultBandwidthMeter.Builder(context).setInitialBitrateEstimate(bps).build() }') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('return if (hasMeasured && estimate != unmeasuredEstimateBps) estimate else initialEstimateBps') &&
    read('android/src/main/java/com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt').includes('loads.retainPeriodsOf(eventTime.timeline)') &&
    standardConfig.includes('    builder.setBandwidthMeter(startLow.meter)\n') &&
    // HLS audio renditions adapt (the crossfade players' parameters, shared), lowest first at the
    // default estimate. Pinned behaviour: android/robolectric-tests StandardPlayerHlsTest.
    standardConfig.includes('        DefaultTrackSelector(\n            context,\n            crossfadeTrackSelectorParameters(DefaultTrackSelector.Parameters.Builder(context)),\n            startLow.selectionFactory\n        )') &&
    standardConfig.includes('    analytics.addListener(startLow.loadListener)\n    builder.setAnalyticsCollector(analytics)') &&
    read('android/robolectric-tests/build.gradle.kts').includes('"com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt",') &&
    ['fun theStandardPlayerAsksForTheFirstSegmentAtTheLowestRenditionHighestListedFirst()', 'fun theNextTrackPreparedAheadAlsoAsksForItsFirstSegmentAtTheLowestRendition()']
      .every((t) => read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/StandardPlayerHlsTest.kt').includes(t)) &&
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
    standardHooks.includes('httpDataSourceFactory = standardHttpDataSourceFactory(stallTimeoutMs),') &&
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
    engineAwaitPlaying.includes('            if (player.playerError != null) {\n                if (operationGeneration == generation) state = AndroidCrossfadeEngineState.FAILED\n                throw RejectionException(player.playerError?.message ?: "Crossfade engine failed to play.", "crossfade_engine_error")\n            }\n            player.isPlaying') &&
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
      prepareBody.indexOf('configureRequestOptions(item)') < prepareBody.indexOf('player.setMediaSource(') &&
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
      true,
    'Android crossfade players must select adaptively among audio renditions (lowest first at a low estimate).'
  );
}

// A load or seek an engine gives up on stops loading (no background retries) and forgets the
// track, as iOS removes the item.
{
  const abandon = section(engineSource, 'private fun abandonLoad(generation: Long, why: String) {', '\n    }\n');
  const prepareBody = section(engineSource, 'override suspend fun prepare(', 'override fun play(rate: Float)');
  const seekBody = section(engineSource, 'override suspend fun seekTo(', 'override fun setVolume(');
  assert(
    abandon.includes('if (operationGeneration != generation) return') &&
      abandon.includes('player.stop()') &&
      abandon.includes('preparedItem = null') &&
      abandon.includes('preparedTrackKey = null') &&
      abandon.includes('load abandoned ($why)') &&
      prepareBody.includes('} catch (error: RejectionException) {\n            abandonLoad(generation, "load ${error.code}: ${error.message}")\n            throw error') &&
      section(prepareBody, 'if (verdict != null) {', 'throw RejectionException(').includes('abandonLoad(generation, "load $reason")') &&
      section(seekBody, 'if (verdict != null) {', 'throw RejectionException(').includes('abandonLoad(generation, "seek $reason")') &&
      seekBody.includes('player.playerError?.let { error ->') &&
      seekBody.includes('abandonLoad(generation, "seek ${error.code}: ${error.message}")'),
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
      section(orchestrator, 'private suspend fun ensureActivePrepared(', 'private suspend fun prepareStandby(').includes('prepareActiveOrFail(item, positionMs, ticket)') &&
      section(orchestrator, 'suspend fun load(item: TrackAudioItem)', 'fun setNowPlayingOverride(').includes('prepareActiveOrFail(item, 0L, ticket)') &&
      section(orchestrator, 'private suspend fun prepareActiveOrFail(', 'private suspend fun prepareStandby(').includes('} catch (error: RejectionException) {\n            // With no active track, the next play from the error state retries it\n            // (indexToPlayAfterFailedLoad; only read in ERROR, so a cancelled load is harmless).\n            failedLoadItem = item\n            ticket?.ensureActive()\n            setState(AndroidPlaybackOrchestratorState.ERROR)\n            throw error') &&
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

// As iOS's loadIndex: the active track is committed once its load succeeded; a load that fails or
// is cancelled leaves the previous track active (load() of a new track: none, -1).
{
  const startTrack = section(orchestrator, 'private suspend fun startTrackAt(', 'private suspend fun ensureActivePrepared(');
  const loadBody = section(orchestrator, 'suspend fun load(item: TrackAudioItem) = withPlaybackOperation', 'fun setNowPlayingOverride(');
  const test = read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt');
  assert(
    startTrack.indexOf('prepareActiveOrFail(queue[index], positionMs, ticket)') < startTrack.indexOf('currentIndex = index') &&
      startTrack.indexOf('prepareActiveOrFail(queue[index], positionMs, ticket)') < startTrack.indexOf('delegate.onActiveTrackChanged(index, previousIndex, oldPositionMs)') &&
      (startTrack.match(/currentIndex = /g) || []).length === 1 &&
      loadBody.includes('            queue = listOf(item)\n            currentIndex = -1\n') &&
      loadBody.indexOf('prepareActiveOrFail(item, 0L, ticket)') < loadBody.indexOf('            currentIndex = 0\n') &&
      ['fun aFailedSkipKeepsThePreviousTrackActiveAndAPlayReloadsItAsOnIos()', 'fun aFailedLoadOfANewTrackLeavesNoActiveTrackAsOnIos()',
        'fun aPlayOrASeekAfterAFailedSkipWhoseReloadFailsEndsInErrorAsOnIos()'].every((t) => test.includes(t)),
    'Android must commit the active track only once its load succeeded, as iOS.'
  );
}

// The engine behaviours are pinned by the Robolectric tests (real ExoPlayer, local HLS server),
// which CI runs: each named test must keep its assertion, and the workflow must run the project.
{
  const hlsTests = read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/CrossfadeEngineHlsTest.kt');
  const workflow = read('.github/workflows/validate.yml');
  const testBody = (name) => section(hlsTests, `fun ${name}()`, '\n    @Test');
  for (const name of [
    'anUncachedTrackAsksForItsFirstSegmentAtTheLowestRenditionHighestListedFirst',
    'anUncachedTrackAsksForItsFirstSegmentAtTheLowestRenditionLowestListedFirst'
  ]) {
    assert(
      testBody(name).includes('assertEquals("v064", awaitFirstSegmentRendition(server))'),
      `${name} must assert the first segment requested is the lowest rendition.`
    );
  }
  assert(
    testBody('failingSegmentsGiveUpAtTheStallTimeoutThoughThePlayerFallsBackToOtherRenditions')
      .includes('gaveUpAfterMs < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS') &&
      hlsTests.includes('assertStopsLoading(engine, item, stalled, gaveUpAtMs)') &&
      hlsTests.includes('assertFalse("a track that failed is not prepared", engine.isPreparedFor(item))') &&
      hlsTests.includes('assertEquals(SEEK_TARGET_MS, runBlocking(engineThread) { engine.positionMs })') &&
      workflow.includes('cd android/robolectric-tests') &&
      workflow.includes('./gradlew testDebugUnitTest') &&
      workflow.includes(':react-native-track-player:testDebugUnitTest'),
    'The Robolectric engine tests must keep their assertions and run in CI with the unit tests.'
  );
}

// A load's progress is its own (LoadProgress, one per load: a request of an earlier track cannot
// change it). Media bytes count; HLS playlists and keys count until the load asks for its first
// segment, not after (reloads when the player falls back to another rendition).
{
  const factory = section(engineSource, 'internal class CrossfadeMediaSourceFactory(', '\n}\n');
  const load = section(engineSource, 'internal class LoadProgress {', '\n}\n');
  const prepareBody = section(engineSource, 'override suspend fun prepare(', 'override fun play(rate: Float)');
  const hlsTests = read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/CrossfadeEngineHlsTest.kt');
  assert(
    factory.includes('val playlists = newDataSourceFactory().setTransferListener(load.playlistListener)') &&
      factory.includes('val media = newDataSourceFactory().setTransferListener(load.mediaListener)') &&
      factory.includes('(if (dataType == C.DATA_TYPE_MEDIA) media else playlists).createDataSource()') &&
      factory.includes('DefaultMediaSourceFactory(media).createMediaSource(mediaItem)') &&
      load.includes('if (!mediaRequested.get()) bytesLoaded.addAndGet(bytesTransferred.toLong())') &&
      load.includes('override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {\n            mediaRequested.set(true)') &&
      prepareBody.includes('val load = LoadProgress()\n        currentLoad = load\n        player.setMediaSource(mediaSourceFactory.createMediaSource(buildMediaItem(item), load))') &&
      engineSource.includes('longArrayOf(currentLoad.bytesLoaded.get(), player.bufferedPosition, player.totalBufferedDuration)') &&
      !/\.setMediaSourceFactory\(/.test(engineSource) &&
      hlsTests.includes('fun slowPlaylistsBeforeTheFirstSegmentDoNotMakeAHealthyTrackGiveUp()') &&
      hlsTests.includes('fun aStaleSegmentRequestOfThePreviousTrackDoesNotStopTheNextTracksPlaylistsCounting()'),
    'Android engine waits must count each load\'s own progress: media always, playlists and keys until its first segment.'
  );
}

// A track that ends while the next one preloads advances (iOS acts in preloadingNext too).
assert(
  section(orchestrator, 'private suspend fun monitorActiveEngine() {', 'val endedIndex = currentIndex')
    .includes('state != AndroidPlaybackOrchestratorState.PRELOADING_NEXT'),
  'The Android end monitor must also act while the next track preloads, as iOS.'
);

// The standard player's loads follow the stall rule: a load that makes no progress for
// stallTimeoutMs (media bytes and buffered media; playlists and keys are not progress) or exceeds
// prepareTimeoutMs stops loading and reports crossfade_prepare_timeout with the error state, as a
// crossfade advance (a skip or load waiting for it rejects with it instead). A stalled standard seek stops loading and leaves
// the player in error (its rejection is the report). Pinned behaviour: robolectric-tests
// StandardPlayerHlsTest (real ExoPlayer).
{
  const watchSource = read('android/src/main/java/com/doublesymmetry/trackplayer/service/StandardLoadWatch.kt');
  const vendored = read('android/src/vendor/kotlinaudio/java/com/doublesymmetry/kotlinaudio/players/BaseAudioPlayer.kt');
  const hlsTest = read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/StandardPlayerHlsTest.kt');
  const supervise = section(standardBackend, 'private fun observeLoad(): StandardLoadObservation {', 'private fun followLoad(');
  const driver = section(watchSource, 'internal class StandardLoadDriver(', '\n}\n');
  const giveUp = section(standardBackend, 'private fun giveUpLoad(', '\n    }\n');
  const failLoad = section(vendored, 'fun failLoad(error: PlaybackError, report: Boolean) {', '\n    }\n');
  assert(
    watchSource.includes('internal const val PREPARE_TIMEOUT_CODE = "crossfade_prepare_timeout"') &&
      supervise.includes('if (!isAuthoritative || disposed || playerReleased || logicalItem == null) {') &&
      supervise.includes('standardLoadObservation(exo, logicalItem, analytics()?.loadedBytes, ownedElsewhere = seekGate.isWaiting)') &&
      // Event-driven, one timer only while a load is watched, at an interval from the settings.
      driver.includes('watch.nextCheckInMs()?.let {\n            handler.postDelayed(check, it)') &&
      driver.includes('override fun onEvents(player: Player, events: com.google.android.exoplayer2.analytics.AnalyticsListener.Events) {\n                poke()') &&
      watchSource.includes('internal fun standardLoadSampleIntervalMs(stallTimeoutMs: Long): Long = (stallTimeoutMs / 10L).coerceAtLeast(1L)') &&
      !/ENGINE_WAIT_POLL_INTERVAL_MS|delay\(/.test(watchSource) &&
      section(standardBackend, 'fun startLoadWatch(handler: android.os.Handler) {', '\n    }\n').includes('it.listenTo(collector)') &&
      section(standardBackend, 'override suspend fun seekTo(positionMs: Long) {', '\n    }\n').includes('loadDriver?.poke()') &&
      giveUp.includes('androidXfadeLog("standard load abandoned (load $reason) positionMs=${player.position}")') &&
      giveUp.includes('val message = standardLoadGiveUpMessage(verdict, stallMs, totalMs)') &&
      // Reported as a playback error only when no command waits for the load (its rejection reports it).
      giveUp.includes('PlaybackError(PREPARE_TIMEOUT_CODE, message, fromHost = true),\n            report = !commandLoads.waitsFor(item)') &&
      failLoad.includes('exoPlayer.stop()') && failLoad.includes('playerState = AudioPlayerState.ERROR') &&
      failLoad.includes('if (report) playerEventHolder.updatePlaybackError(error)') &&
      vendored.includes('(if (dataType == C.DATA_TYPE_MEDIA) mediaFactory else factory).createDataSource()') &&
      // Each item's own listeners: progress belongs to the load of the item that loads.
      standardHooks.includes('mediaTransferListener = { item -> analytics.loadedBytes.media(item) },') &&
      standardHooks.includes('playlistTransferListener = { item -> analytics.loadedBytes.playlists(item) },') &&
      vendored.includes('val mediaFactory: DataSource.Factory = hooks.mediaTransferListener?.invoke(mediaItem)?.let { listener ->') &&
      vendored.includes('val playlistFactory: DataSource.Factory = hooks.playlistTransferListener?.invoke(mediaItem)?.let { listener ->') &&
      // The item ExoPlayer loads (its sources' MediaItem), not KotlinAudio's queue entry (replaceItem).
      read('android/src/main/java/com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt').includes('player?.currentMediaItem?.let(loadedBytes::startLoad)') &&
      watchSource.includes('private fun loadOf(item: Any): Load? = current.get()?.takeIf { it.item === item }') &&
      ['thePreviousTracksSegmentRequestDoesNotEndTheNextLoadsPlaylistProgress', 'thePreviousTracksBytesAreNotTheNextLoadsProgress']
        .every((t) => read('android/src/test/java/com/doublesymmetry/trackplayer/service/LoadedBytesTest.kt').includes(`fun ${t}()`)) &&
      // A give-up's error stays until the next command (iOS: hostFailure): the play-when-ready
      // change that follows the stop does not turn it into PAUSED; a seek loads the track again.
      vendored.includes('if (!player.playWhenReady && playerState != AudioPlayerState.STOPPED && !isHostFailure()) {') &&
      vendored.includes('playerState == AudioPlayerState.ERROR && playbackError?.fromHost == true') &&
      standardBackend.includes('it == AudioPlayerState.ERROR && player.playbackError?.fromHost == true -> AudioPlayerState.STOPPED') &&
      vendored.includes('exoPlayer.clearMediaItems()\n        // Fork: a host give-up\'s error ends with the queue (no item, no error).\n        if (isHostFailure()) playerState = AudioPlayerState.IDLE') &&
      // The real vendored player and backend against a stalled server.
      read('android/robolectric-tests/build.gradle.kts').includes('from("${rootProject.projectDir}/../src/vendor/kotlinaudio/java")') &&
      read('android/robolectric-tests/build.gradle.kts').includes('"com/doublesymmetry/trackplayer/service/KotlinAudioPlaybackBackend.kt",') &&
      ['aStalledTrackTappedWhileAnotherPlaysEndsInErrorWithThePreviousTrackActive', 'aStalledFirstTrackEndsInErrorWithNoActiveTrack',
        'aStalledSeekWhilePlayingEndsInErrorAtItsTarget', 'theNextCommandEndsTheErrorASeekLoadsTheTrackAgainAtItsTarget',
        'failingSegmentsGiveUpAtTheStallTimeoutThoughThePlayerFallsBackToOtherRenditions', 'clearingTheQueueAfterAGiveUpEndsTheError',
        'aTrackWhoseMetadataWasReplacedStillCountsItsSlowPlaylists']
        .every((t) => read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/StandardBackendHlsTest.kt').includes(`fun ${t}()`)) &&
      hlsTest.includes('fun failingSegmentsGiveUpAtTheStallTimeoutThoughThePlayerFallsBackToOtherRenditions()') &&
      vendored.includes('MediaType.HLS -> createHlsSource(mediaItem, playlistFactory, mediaFactory)') &&
      musicService.includes('onLoadStart = { standardAnalytics[binding.player]?.startLoad() }') &&
      ['slowPlaylistsBeforeTheFirstSegmentDoNotMakeAHealthyStandardTrackGiveUp', 'slowPlaylistsCountAgainForTheNextStandardTrack']
        .every((t) => hlsTest.includes(`fun ${t}()`)) &&
      musicService.includes('totalTimeoutMs = { prepareTimeout.milliseconds }') &&
      musicService.includes('.also { backend -> backend.startLoadWatch(android.os.Handler(android.os.Looper.getMainLooper())) }') &&
      section(standardBackend, 'override suspend fun seekTo(positionMs: Long) {', '\n    }\n').includes('player.failLoad(PlaybackError(error.code, error.message, fromHost = true), report = false)') &&
      read('android/robolectric-tests/build.gradle.kts').includes('"com/doublesymmetry/trackplayer/service/StandardLoadWatch.kt",') &&
      ['aStalledStandardLoadGivesUpAtTheStallTimeoutAndStopsLoading', 'aStalledStandardLoadWhileATrackPlaysGivesUpAtTheStallTimeout',
        'aStalledNaturalAdvanceGivesUpAtTheStallTimeout', 'aRetryAfterAGiveUpThatStallsAgainGivesUpAgain']
        .every((t) => hlsTest.includes(`fun ${t}()`)) &&
      hlsTest.includes('gaveUpAt - loadAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS'),
    'The Android standard player must give up a load with no progress at stallTimeoutMs, as crossfade.'
  );
}

// The standard player follows the same failed-load rule (FailedLoadRule, shared scenarios in
// scripts/fixtures/failed-load-scenarios.json, run by the JVM tests and the XCTests): after a
// failed load (a give-up or a player error) the previous track is active again and reported, and
// play or retry reloads it.
{
  const fixture = JSON.parse(read('scripts/fixtures/failed-load-scenarios.json'));
  assert(
    fixture.scenarios.length === 17 &&
      // One explicit state (FailedLoadRule.Phase and PlayerError): the backend keeps no flag of its own.
      read('android/src/main/java/com/doublesymmetry/trackplayer/service/FailedLoadRule.kt').includes('sealed class Phase {') &&
      !standardBackend.includes('sawPlayerError') &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('if (failedLoads.playerErrorSeen()) {\n                failLoadedTrack()') &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('if (failedLoads.playerErrorGone()) commandLoads.failureCleared()') &&
      section(standardBackend, 'override fun remove(indexes: List<Int>) {', '\n    }\n').includes('reportRemovedTrack(before)') &&
      read('android/src/test/java/com/doublesymmetry/trackplayer/service/FailedLoadRuleTest.kt').includes('readSharedFixture("scripts/fixtures/failed-load-scenarios.json")') &&
      standardBackend.includes('get() = if (failedLoads.isPending(player.currentItem)) reportedIndex() else logicalPlaybackState.currentIndex(player.currentIndex)') &&
      section(standardBackend, 'private fun giveUpLoad(', '\n    }\n').includes('failLoadedTrack()') &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('failLoadedTrack()') &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('if (failedLoads.moved(item)) report(FailedLoadRule.Report(item, from))') &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('failedLoads.ready()?.let(::report)') &&
      section(standardBackend, 'override suspend fun play() {', '\n    }\n').includes('loadActiveTrackAfterFailedLoad()\n            player.play()') &&
      section(standardBackend, 'override suspend fun retry() {', '\n    }\n').includes('loadActiveTrackAfterFailedLoad()\n            player.prepare()') &&
      musicService.includes('emitPlaybackTrackChangedEvents(index, lastIndex, lastPositionMs.toSeconds(), lastItem?.track)\n                            index?.let(::updateNotificationMetadataForIndex)') &&
      musicService.includes('activeIndex?.let(::updateNotificationMetadataForIndex)') &&
      // KotlinAudio's own item transition no longer reports the active track (the backend does).
      !section(musicService, 'ownerScope.collectWithAdmission(source.event.audioItemTransition, admission) {', 'ownerScope.collectWithAdmission(source.event.onTimedMetadata').includes('emitPlaybackTrackChangedEvents') &&
      section(orchestrator, 'private suspend fun playFromStill() = withPlaybackOperation', 'private suspend fun awaitPlaybackStart(').includes('indexToPlayAfterFailedLoad(currentIndex, queue.indexOfFirst { it === failedLoadItem }.takeIf { it >= 0 }, queue.size)') &&
      read('android/src/test/java/com/doublesymmetry/trackplayer/service/AndroidPlaybackOrchestratorCancellationTest.kt').includes('fun aPlayAfterAFailedFirstLoadRetriesTheTrackThatFailedAsOnIos()'),
    'The Android standard player must keep the previous track active after a failed load, as iOS.'
  );
}

// A give-up says the same as on iOS, with no engine names; both platforms' tests pin the text.
{
  const androidTest = read('android/src/test/java/com/doublesymmetry/trackplayer/service/StallWatchTest.kt');
  const iosTest = read('ios/RNTrackPlayerTests/PlaybackBackendTransactionTests.swift');
  for (const text of [
    'Crossfade engine did not become ready (no progress for 10000 ms).',
    'Crossfade engine did not become ready (over the 60000 ms limit).',
    'Crossfade engine seek did not finish (no progress for 10000 ms).'
  ]) {
    assert(androidTest.includes(`"${text}"`) && iosTest.includes(`"${text}"`), `Both platforms must pin the give-up text: ${text}`);
  }
  assert(
    !/RejectionException\("\$name/.test(engineSource),
    'Android engine errors must not name the engine (engineA/engineB) in their message.'
  );
}

// Standard skip, next, previous and load end as crossfade's (smart-music-player reads the active
// index right after them): once the track loaded and is the active one, or rejected with the
// load's failure (crossfade_prepare_timeout, crossfade_engine_error) or `cancelled`; a failure a
// command waits for is not also a playback error. Pinned behaviour: StandardCommandLoadTest and
// robolectric-tests StandardBackendHlsTest; MusicService's event filter has no test.
{
  const commandLoad = read('android/src/main/java/com/doublesymmetry/trackplayer/service/StandardCommandLoad.kt');
  const hls = read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/StandardBackendHlsTest.kt');
  const playbackErrors = section(musicService, 'ownerScope.collectWithAdmission(source.event.playbackError, admission) {', '\n        }\n');
  assert(
    commandLoad.includes('internal const val STANDARD_LOAD_ERROR_CODE = "crossfade_engine_error"') &&
      ['override suspend fun load(item: TrackAudioItem) {', 'override suspend fun skip(index: Int) {',
        'override suspend fun skipToNext() {', 'override suspend fun skipToPrevious() {'].every((start) =>
        section(standardBackend, start, '\n    }\n').includes('awaitCommandLoad()')) &&
      section(standardBackend, 'private suspend fun awaitCommandLoad() {', '\n    }\n').includes('throw RejectionException(STANDARD_COMMAND_LOAD_CANCELLED_MESSAGE, "cancelled")') &&
      section(standardBackend, 'private suspend fun awaitCommandLoad() {', '\n    }\n').includes('if (standardCommandLoadMustStart(targetLoaded = false, exoState = analytics()?.player?.playbackState ?: com.google.android.exoplayer2.Player.STATE_IDLE)) {\n            player.prepare()') &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('reportedByPlayer = true') &&
      ['override suspend fun play() {', 'override suspend fun retry() {'].every((start) => section(standardBackend, start, '\n    }\n').includes('commandLoads.failureCleared()')) &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('commandLoads.ruleSettled(failedLoads.active, failedLoads.reported)') &&
      section(standardBackend, 'private fun followLoad(', '\n    }\n').includes('STANDARD_LOAD_ERROR_CODE,') &&
      section(standardBackend, 'private fun giveUpLoad(', '\n    }\n').includes('commandLoads.failed(item, PREPARE_TIMEOUT_CODE, message, reportedByPlayer = false)') &&
      ['override fun stop() {\n        val cancelledWait = commandLoads.cancel()', 'override fun replaceQueue(items: List<TrackAudioItem>) {\n        commandLoads.cancel()',
        'override fun clearQueue() {\n        commandLoads.cancel()', 'disposed = true\n        commandLoads.cancel()'].every((pin) => standardBackend.includes(pin)) &&
      playbackErrors.includes('if (standard?.identity === identity && standard.reportsPlayerErrorThroughCommand()) return@collectWithAdmission') &&
      read('android/robolectric-tests/build.gradle.kts').includes('"com/doublesymmetry/trackplayer/service/StandardCommandLoad.kt",') &&
      ['aSkipAfterSettingTheQueueResolvesOnceTheTargetLoadedAndIsTheActiveTrack', 'aSkipToTheFirstTrackOfANewQueueResolvesOnceItLoaded',
        'aLoadIntoAnEmptyQueueResolvesOnceTheTrackLoaded', 'aSkipToATrackThatFailsToLoadRejectsWithTheEngineErrorAndThePreviousTrackStaysActive',
        'aNewerSkipCancelsTheWaitOfTheOlderOne', 'aStopOrANewQueueEndsAWaitingSkipCancelled',
        'aGiveUpThatNoCommandWaitsForIsReportedAfterARejectedSkip',
        'aSeekAfterASkipThatGaveUpActsOnThePreviousTrackAndThePlayPlaysIt',
        'aStopAfterASkipThatGaveUpStopsOnThePreviousTrackAndThePlayReloadsIt',
        'aSeekAfterASkipThatFailedWithAPlayerErrorActsOnThePreviousTrack',
        'aNextToTheTrackThatFailedLoadsItAgainAndReportsIt',
        'aSeekOnATrackWhosePlaylistsNeverAnswerGivesUpAtTheStallTimeoutAndLeavesThePlayToRetryIt',
        'aSeekDuringASkipsLoadCancelsTheSkipAndActsOnTheActiveTrack',
        'aPauseDuringASkipsLoadCancelsTheSkipAndThePlayResumesTheActiveTrack',
        'aStopDuringASkipsLoadCancelsTheSkipAndThePlayResumesTheActiveTrack',
        'afterAGiveUpAPauseKeepsTheErrorAndAStopEndsItStopped',
        'aGiveUpEmitsTheErrorStateThenThePlaybackError'].every((t) => hls.includes(`fun ${t}()`)),
    'Android standard skip, next, previous and load must end once their track loaded, as crossfade.'
  );
}

// Rule 13: while a standard track loads, every reader agrees with the reported active track
// (ReportedTrackProgress, ReportedNowPlaying: ReportedTrackTest; the backend's wiring:
// StandardBackendHlsTest.whileATrackLoadsEveryReaderAgreesWithTheReportedTrack). MusicService's
// wiring and the progress event read the backend.
{
  assert(
    section(musicService, 'onNowPlaying = { index, _ ->', '},').includes('if (index != null) updateNotificationMetadataForIndex(index)\n                            else binding.player.notificationManager.overrideAudioItem = null') &&
      section(musicService, 'private suspend fun progressUpdateEvent(): Bundle? {', '\n    }\n').includes('putDouble(POSITION_KEY, backend.positionMs.toSeconds())') &&
      section(musicService, 'private suspend fun progressUpdateEvent(): Bundle? {', '\n    }\n').includes('putInt(TRACK_KEY, backend.currentIndex)') &&
      standardBackend.includes('override val positionMs: Long\n        get() = reportedProgress().positionMs') &&
      standardBackend.includes('progress.left(player.items.getOrNull(oldPosition.mediaItemIndex), oldPosition.positionMs)') &&
      // A backend switch's snapshot pairs the player's own index with its own position.
      standardBackend.includes('positionMs = liveProgress().positionMs.coerceAtLeast(0L),'),
    'Android standard readers (progress, events, notification) must agree with the reported active track while another loads, as iOS.'
  );
}

// Rule 13 (N1, as iOS's lock screen): while a standard track loads, the media session and the
// notification read the reported track's position, duration and buffered position, not playing
// (ReportedSessionPlayer, held by the backend; StandardBackendHlsTest.whileATrackLoadsTheMedia
// SessionAndTheNotificationReadTheReportedTrack on the real player, with the instance both read).
// What the tests cannot reach: the real MediaSessionConnector (a stub in the Robolectric build)
// invalidates its playback state, and PlayerNotificationManager re-posts, at these two events
// (ExoPlayer 2.19.0's MediaSessionConnector.ComponentListener.onEvents, read with javap).
{
  const sessionPlayer = read('android/src/main/java/com/doublesymmetry/trackplayer/service/ReportedSessionPlayer.kt');
  const vendored = read('android/src/vendor/kotlinaudio/java/com/doublesymmetry/kotlinaudio/players/BaseAudioPlayer.kt');
  assert(
    sessionPlayer.includes('FlagSet.Builder().addAll(Player.EVENT_PLAY_WHEN_READY_CHANGED, Player.EVENT_IS_PLAYING_CHANGED).build()') &&
      sessionPlayer.includes('listeners.toList().forEach { it.onEvents(this, events) }') &&
      standardHooks.includes('sessionPlayer = { player -> ReportedSessionPlayer(player).also { analytics.sessionPlayer = it } }') &&
      musicService.includes('standardPlayerHooks(this@MusicService, analytics, { initialBitrateEstimate.bitsPerSecond }, { stallTimeout.milliseconds })') &&
      vendored.includes('sessionPlayer = hooks.sessionPlayer(playerToUse)\n\n        notificationManager = NotificationManager(\n            context,\n            sessionPlayer,') &&
      vendored.includes('mediaSessionConnector.setPlayer(sessionPlayer)') &&
      vendored.includes('notificationManager.getMediaMetadataCompat()') &&
      section(standardBackend, 'private fun followNowPlaying() {', '\n    }\n').includes('analytics()?.sessionPlayer?.hold(if (nowPlaying.isHeld) reportedProgress() else null)\n        change?.let { onNowPlaying(indexOfItem(it.item), it.held) }') &&
      read('android/robolectric-tests/build.gradle.kts').includes('"com/doublesymmetry/trackplayer/service/ReportedSessionPlayer.kt",') &&
      ['whileATrackLoadsTheMediaSessionAndTheNotificationReadTheReportedTrack', 'theSessionPlayerTellsItsListenersAtOnceWhenItHoldsAndReleases']
        .every((t) => read('android/robolectric-tests/src/test/java/com/doublesymmetry/trackplayer/service/StandardBackendHlsTest.kt').includes(`fun ${t}()`)),
    'The Android media session and notification must read the reported track while another loads, as iOS\'s lock screen.'
  );
}

// The engine gives ExoPlayer each load's own media source; a media item would go through
// ExoPlayer's default factory (no progress listener, no per-request HTTP timeouts).
assert(
  !/\.(setMediaItem|setMediaItems|addMediaItem|addMediaItems)\(/.test(engineSource) &&
    (engineSource.match(/player\.setMediaSource\(/g) || []).length === 1,
  'The Android crossfade engine must load tracks only with setMediaSource(its per-load source), never a media item.'
);

console.log('Android crossfade contracts OK');
