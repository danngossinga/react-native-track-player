package com.doublesymmetry.trackplayer.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.support.v4.media.RatingCompat
import androidx.annotation.MainThread
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.PRIORITY_LOW
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.doublesymmetry.kotlinaudio.models.*
import com.doublesymmetry.kotlinaudio.models.NotificationButton.*
import com.doublesymmetry.kotlinaudio.players.QueuedAudioPlayer
import com.doublesymmetry.trackplayer.R as TrackPlayerR
import com.doublesymmetry.trackplayer.extensions.NumberExt.Companion.toMilliseconds
import com.doublesymmetry.trackplayer.extensions.NumberExt.Companion.toSeconds
import com.doublesymmetry.trackplayer.extensions.asLibState
import com.doublesymmetry.trackplayer.extensions.find
import com.doublesymmetry.trackplayer.model.MetadataAdapter
import com.doublesymmetry.trackplayer.model.PlaybackMetadata
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.module.MusicEvents
import com.doublesymmetry.trackplayer.module.MusicEvents.Companion.METADATA_PAYLOAD_KEY
import com.doublesymmetry.trackplayer.utils.BundleUtils
import com.doublesymmetry.trackplayer.utils.BundleUtils.setRating
import com.facebook.react.HeadlessJsTaskService
import com.facebook.react.bridge.Arguments
import com.facebook.react.jstasks.HeadlessJsTaskConfig
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.ui.R as ExoPlayerR
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.flow
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess
import timber.log.Timber

@MainThread
class MusicService : HeadlessJsTaskService() {
    private var player: QueuedAudioPlayer? = null
    private val crossfadeQueue = AndroidTrackQueue()
    private var playbackOrchestrator: AndroidPlaybackOrchestrator? = null
    private var orchestratedMediaSurface: AndroidOrchestratedMediaSurface? = null
    private val binder = MusicBinder()
    private val scope = MainScope()
    private var progressUpdateJob: Job? = null
    private var crossfadeEnabled = false
    private var latestNotificationConfig: NotificationConfig? = null
    private var automaticallyUpdateNotificationMetadata = true
    private var configuredRatingType: Int = RatingCompat.RATING_NONE
    private var configuredRepeatMode: RepeatMode = RepeatMode.OFF

    private fun isPrimaryPlayerInitialized(): Boolean = player != null || playbackOrchestrator != null

    private fun useOrchestratedCrossfade(): Boolean = crossfadeEnabled && playbackOrchestrator != null

    private fun requireKotlinAudioPlayer(): QueuedAudioPlayer {
        return player ?: throw IllegalStateException("KotlinAudio player is not initialized for this playback mode.")
    }

    private fun allPlayers(): List<QueuedAudioPlayer> = player?.let { listOf(it) } ?: emptyList()

    private fun isActivePlayer(source: QueuedAudioPlayer): Boolean =
        player === source

    /**
     * Use [appKilledPlaybackBehavior] instead.
     */
    @Deprecated("This will be removed soon")
    var stoppingAppPausesPlayback = true
        private set

    enum class AppKilledPlaybackBehavior(val string: String) {
        CONTINUE_PLAYBACK("continue-playback"), PAUSE_PLAYBACK("pause-playback"), STOP_PLAYBACK_AND_REMOVE_NOTIFICATION("stop-playback-and-remove-notification")
    }

    private var appKilledPlaybackBehavior = AppKilledPlaybackBehavior.CONTINUE_PLAYBACK
    private var stopForegroundGracePeriod: Int = DEFAULT_STOP_FOREGROUND_GRACE_PERIOD

    val tracks: List<Track>
        get() = playerItems().map { it.track }

    val currentTrack
        get() = playbackOrchestrator?.currentTrack?.track ?: (requireKotlinAudioPlayer().currentItem as TrackAudioItem).track

    val state
        get() = playbackOrchestrator?.playbackState ?: requireKotlinAudioPlayer().playerState

    var ratingType: Int
        get() = configuredRatingType
        set(value) {
            configuredRatingType = value
            allPlayers().forEach { it.ratingType = value }
        }

    val playbackError
        get() = player?.playbackError

    val event
        get() = requireKotlinAudioPlayer().event

    var playWhenReady: Boolean
        get() = playbackOrchestrator?.playWhenReady ?: requireKotlinAudioPlayer().playWhenReady
        set(value) {
            val orchestrator = playbackOrchestrator
            if (orchestrator != null) {
                if (value) {
                    scope.launch {
                        orchestrator.play()
                        refreshOrchestratedMediaSurface(reason = "play-when-ready")
                    }
                } else {
                    orchestrator.pause()
                    refreshOrchestratedMediaSurface(reason = "play-when-ready")
                }
            } else {
                requireKotlinAudioPlayer().playWhenReady = value
            }
        }

    private var latestOptions: Bundle? = null
    private var capabilities: List<Capability> = emptyList()
    private var notificationCapabilities: List<Capability> = emptyList()
    private var compactCapabilities: List<Capability> = emptyList()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (useOrchestratedCrossfade() && orchestratedMediaSurface?.handleIntent(intent) == true) {
            return START_STICKY
        }
        startTask(getTaskConfig(intent))
        startAndStopEmptyNotificationToAvoidANR()
        return START_STICKY
    }

    /**
     * Workaround for the "Context.startForegroundService() did not then call Service.startForeground()"
     * within 5s" ANR and crash by creating an empty notification and stopping it right after. For more
     * information see https://github.com/doublesymmetry/react-native-track-player/issues/1666
     */
    private fun startAndStopEmptyNotificationToAvoidANR() {
        val notificationManager = this.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notificationManager.createNotificationChannel(
                NotificationChannel(getString(TrackPlayerR.string.rntp_temporary_channel_id), getString(TrackPlayerR.string.rntp_temporary_channel_name), NotificationManager.IMPORTANCE_LOW)
            )
        }

        val notificationBuilder = NotificationCompat.Builder(this, getString(TrackPlayerR.string.rntp_temporary_channel_id))
            .setPriority(PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setSmallIcon(ExoPlayerR.drawable.exo_notification_small_icon)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            notificationBuilder.foregroundServiceBehavior = NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE
        }
        val notification = notificationBuilder.build()
        startForeground(EMPTY_NOTIFICATION_ID, notification)
        @Suppress("DEPRECATION")
        stopForeground(true)
    }

    @MainThread
    fun setupPlayer(playerOptions: Bundle?) {
        if (isPrimaryPlayerInitialized()) {
            print("Player was initialized. Prevent re-initializing again")
            return
        }

        val bufferConfig = BufferConfig(
            playerOptions?.getDouble(MIN_BUFFER_KEY)?.toMilliseconds()?.toInt(),
            playerOptions?.getDouble(MAX_BUFFER_KEY)?.toMilliseconds()?.toInt(),
            playerOptions?.getDouble(PLAY_BUFFER_KEY)?.toMilliseconds()?.toInt(),
            playerOptions?.getDouble(BACK_BUFFER_KEY)?.toMilliseconds()?.toInt(),
        )

        val cacheConfig = CacheConfig(playerOptions?.getDouble(MAX_CACHE_SIZE_KEY)?.toLong())
        val handleAudioFocus = playerOptions?.getBoolean(AUTO_HANDLE_INTERRUPTIONS) ?: false
        val audioContentType = when(playerOptions?.getString(ANDROID_AUDIO_CONTENT_TYPE)) {
            "music" -> AudioContentType.MUSIC
            "speech" -> AudioContentType.SPEECH
            "sonification" -> AudioContentType.SONIFICATION
            "movie" -> AudioContentType.MOVIE
            "unknown" -> AudioContentType.UNKNOWN
            else -> AudioContentType.MUSIC
        }
        val playerConfig = PlayerConfig(
            interceptPlayerActionsTriggeredExternally = true,
            handleAudioBecomingNoisy = true,
            handleAudioFocus = handleAudioFocus,
            audioContentType = audioContentType
        )

        crossfadeEnabled = playerOptions?.getBoolean(CROSSFADE_KEY, false) ?: false
        automaticallyUpdateNotificationMetadata = playerOptions?.getBoolean(AUTO_UPDATE_METADATA, true) ?: true

        if (crossfadeEnabled) {
            orchestratedMediaSurface = AndroidOrchestratedMediaSurface(
                service = this@MusicService,
                scope = scope,
                delegate = object : AndroidOrchestratedMediaSurfaceDelegate {
                    override fun onRemotePlay() =
                        runOrchestratedRemoteCommand("play", MusicEvents.BUTTON_PLAY) { it.play() }
                    override fun onRemotePause() =
                        runOrchestratedRemoteCommand("pause", MusicEvents.BUTTON_PAUSE) { it.pause() }
                    override fun onRemoteStop() = runOrchestratedRemoteCommand(
                        "stop",
                        MusicEvents.BUTTON_STOP,
                        refreshAfter = false
                    ) {
                        it.stop()
                        orchestratedMediaSurface?.hide()
                    }
                    override fun onRemoteNext() =
                        runOrchestratedRemoteCommand("next", MusicEvents.BUTTON_SKIP_NEXT) { it.skipToNext() }
                    override fun onRemotePrevious() =
                        runOrchestratedRemoteCommand("previous", MusicEvents.BUTTON_SKIP_PREVIOUS) { it.skipToPrevious() }
                    override fun onRemoteSeekTo(positionMs: Long) =
                        runOrchestratedRemoteCommand(
                            "seek",
                            MusicEvents.BUTTON_SEEK_TO,
                            Bundle().apply { putDouble("position", positionMs.toSeconds()) }
                        ) { it.seekTo(positionMs) }
                    override fun onRemoteJumpForward(interval: Int) =
                        runOrchestratedRemoteCommand(
                            "jump-forward",
                            MusicEvents.BUTTON_JUMP_FORWARD,
                            Bundle().apply { putInt("interval", interval) }
                        ) { it.seekBy(interval * 1000L) }
                    override fun onRemoteJumpBackward(interval: Int) =
                        runOrchestratedRemoteCommand(
                            "jump-backward",
                            MusicEvents.BUTTON_JUMP_BACKWARD,
                            Bundle().apply { putInt("interval", interval) }
                        ) { it.seekBy(-interval * 1000L) }
                    override fun onRemoteSetRating(rating: RatingCompat) {
                        Bundle().apply {
                            setRating(this, "rating", rating)
                            putBoolean("handledByNative", true)
                            emit(MusicEvents.BUTTON_SET_RATING, this)
                        }
                    }
                    override fun onForegroundServiceStartError(error: Exception) {
                        Timber.e(
                            "ForegroundServiceStartNotAllowedException: App tried to start a foreground Service when it was not allowed to do so.",
                            error
                        )
                        emit(MusicEvents.PLAYER_ERROR, Bundle().apply {
                            putString("message", error.message)
                            putString("code", "android-foreground-service-start-not-allowed")
                        })
                    }
                }
            )
            playbackOrchestrator = AndroidPlaybackOrchestrator(
                context = this@MusicService,
                scope = scope,
                audioContentType = playerConfig.audioContentType.toExoAudioContentType(),
                handleAudioFocus = handleAudioFocus,
                delegate = object : AndroidPlaybackOrchestratorDelegate {
                    override fun onPlaybackStateChanged(state: AudioPlayerState) {
                        emit(MusicEvents.PLAYBACK_STATE, getPlayerStateBundle(state))
                    }

                    override fun onActiveTrackChanged(index: Int?, previousIndex: Int?, oldPositionMs: Long) {
                        emitPlaybackTrackChangedEvents(index, previousIndex, oldPositionMs.toSeconds())
                    }

                    override fun onQueueEnded(index: Int, positionMs: Long) {
                        emitQueueEndedEvent(index, positionMs)
                    }

                    override fun onCrossfadeState(
                        state: String,
                        fromIndex: Int,
                        toIndex: Int,
                        elapsedMs: Int?,
                        fromVolume: Float?,
                        toVolume: Float?,
                        errorCode: String?
                    ) {
                        emitCrossfadeState(state, fromIndex, toIndex, elapsedMs, fromVolume, toVolume, errorCode)
                        refreshOrchestratedMediaSurface(reason = "crossfade-$state")
                    }

                    override fun onNowPlayingChanged(index: Int) {
                        updateNotificationMetadataForIndex(index)
                    }

                    override fun onPlaybackError(code: String, message: String?) {
                        emit(MusicEvents.PLAYBACK_ERROR, Bundle().apply {
                            putString("code", code)
                            putString("message", message)
                        })
                    }

                    override fun onSnapshotChanged(snapshot: AndroidPlaybackSnapshot) {
                        orchestratedMediaSurface?.publish(snapshot, "orchestrator")
                    }
                }
            )
            Timber.tag("RNTP-Crossfade").d("[XF-ORCH] engine=android-ping-pong")
        } else {
            player = QueuedAudioPlayer(this@MusicService, playerConfig, bufferConfig, cacheConfig).apply {
                automaticallyUpdateNotificationMetadata = this@MusicService.automaticallyUpdateNotificationMetadata
                ratingType = configuredRatingType
                (playerOptions as? QueuedPlayerOptions)?.repeatMode = configuredRepeatMode
            }
        }
        observeEvents()
        setupForegrounding()
    }

    @MainThread
    fun updateOptions(options: Bundle) {
        latestOptions = options
        val androidOptions = options.getBundle(ANDROID_OPTIONS_KEY)

        appKilledPlaybackBehavior = AppKilledPlaybackBehavior::string.find(androidOptions?.getString(APP_KILLED_PLAYBACK_BEHAVIOR_KEY)) ?: AppKilledPlaybackBehavior.CONTINUE_PLAYBACK

        BundleUtils.getIntOrNull(androidOptions, STOP_FOREGROUND_GRACE_PERIOD_KEY)?.let { stopForegroundGracePeriod = it }

        // TODO: This handles a deprecated flag. Should be removed soon.
        options.getBoolean(STOPPING_APP_PAUSES_PLAYBACK_KEY).let {
            stoppingAppPausesPlayback = options.getBoolean(STOPPING_APP_PAUSES_PLAYBACK_KEY)
            if (stoppingAppPausesPlayback) {
                appKilledPlaybackBehavior = AppKilledPlaybackBehavior.PAUSE_PLAYBACK
            }
        }

        ratingType = BundleUtils.getInt(options, "ratingType", RatingCompat.RATING_NONE)

        val alwaysPauseOnInterruption = androidOptions?.getBoolean(PAUSE_ON_INTERRUPTION_KEY) ?: false
        allPlayers().forEach {
            it.playerOptions.alwaysPauseOnInterruption = alwaysPauseOnInterruption
        }

        capabilities = options.getIntegerArrayList("capabilities")?.map { Capability.values()[it] } ?: emptyList()
        notificationCapabilities = options.getIntegerArrayList("notificationCapabilities")?.map { Capability.values()[it] } ?: emptyList()
        compactCapabilities = options.getIntegerArrayList("compactCapabilities")?.map { Capability.values()[it] } ?: emptyList()

        if (notificationCapabilities.isEmpty()) notificationCapabilities = capabilities

        val buttonsList = notificationCapabilities.mapNotNull {
            when (it) {
                Capability.PLAY, Capability.PAUSE -> {
                    val playIcon = BundleUtils.getIconOrNull(this, options, "playIcon")
                    val pauseIcon = BundleUtils.getIconOrNull(this, options, "pauseIcon")
                    PLAY_PAUSE(playIcon = playIcon, pauseIcon = pauseIcon)
                }
                Capability.STOP -> {
                    val stopIcon = BundleUtils.getIconOrNull(this, options, "stopIcon")
                    STOP(icon = stopIcon)
                }
                Capability.SKIP_TO_NEXT -> {
                    val nextIcon = BundleUtils.getIconOrNull(this, options, "nextIcon")
                    NEXT(icon = nextIcon, isCompact = isCompact(it))
                }
                Capability.SKIP_TO_PREVIOUS -> {
                    val previousIcon = BundleUtils.getIconOrNull(this, options, "previousIcon")
                    PREVIOUS(icon = previousIcon, isCompact = isCompact(it))
                }
                Capability.JUMP_FORWARD -> {
                    val forwardIcon = BundleUtils.getIcon(this, options, "forwardIcon", TrackPlayerR.drawable.forward)
                    FORWARD(icon = forwardIcon, isCompact = isCompact(it))
                }
                Capability.JUMP_BACKWARD -> {
                    val backwardIcon = BundleUtils.getIcon(this, options, "rewindIcon", TrackPlayerR.drawable.rewind)
                    BACKWARD(icon = backwardIcon, isCompact = isCompact(it))
                }
                Capability.SEEK_TO -> {
                    SEEK_TO
                }
                else -> { null }
            }
        }

        val openAppIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            // Add the Uri data so apps can identify that it was a notification click
            data = Uri.parse("trackplayer://notification.click")
            action = Intent.ACTION_VIEW
        }

        val accentColor = BundleUtils.getIntOrNull(options, "color")
        val smallIcon = BundleUtils.getIconOrNull(this, options, "icon")
        val pendingIntent = PendingIntent.getActivity(this, 0, openAppIntent, getPendingIntentFlags())
        val notificationConfig = NotificationConfig(buttonsList, accentColor, smallIcon, pendingIntent)

        latestNotificationConfig = notificationConfig
        if (useOrchestratedCrossfade()) {
            orchestratedMediaSurface?.updateConfig(
                AndroidOrchestratedMediaSurfaceConfig(
                    notificationCapabilities = notificationCapabilities,
                    compactCapabilities = compactCapabilities,
                    accentColor = accentColor,
                    smallIcon = smallIcon,
                    playIcon = BundleUtils.getIconOrNull(this, options, "playIcon"),
                    pauseIcon = BundleUtils.getIconOrNull(this, options, "pauseIcon"),
                    stopIcon = BundleUtils.getIconOrNull(this, options, "stopIcon"),
                    nextIcon = BundleUtils.getIconOrNull(this, options, "nextIcon"),
                    previousIcon = BundleUtils.getIconOrNull(this, options, "previousIcon"),
                    forwardIcon = BundleUtils.getIcon(this, options, "forwardIcon", TrackPlayerR.drawable.forward),
                    rewindIcon = BundleUtils.getIcon(this, options, "rewindIcon", TrackPlayerR.drawable.rewind),
                    contentIntent = pendingIntent,
                    forwardJumpInterval = (latestOptions?.getDouble(FORWARD_JUMP_INTERVAL_KEY, DEFAULT_JUMP_INTERVAL)
                        ?: DEFAULT_JUMP_INTERVAL).toInt(),
                    backwardJumpInterval = (latestOptions?.getDouble(BACKWARD_JUMP_INTERVAL_KEY, DEFAULT_JUMP_INTERVAL)
                        ?: DEFAULT_JUMP_INTERVAL).toInt()
                )
            )
            refreshOrchestratedMediaSurface(reason = "options")
        } else {
            requireKotlinAudioPlayer().notificationManager.createNotification(notificationConfig)
        }

        // setup progress update events if configured
        progressUpdateJob?.cancel()
        val updateInterval = BundleUtils.getDoubleOrNull(options, PROGRESS_UPDATE_EVENT_INTERVAL_KEY)
        if (updateInterval != null && updateInterval > 0) {
            progressUpdateJob = scope.launch {
                progressUpdateEventFlow(updateInterval).collect { emit(MusicEvents.PLAYBACK_PROGRESS_UPDATED, it) }
            }
        }
    }

    @MainThread
    private fun progressUpdateEventFlow(interval: Double) = flow {
        while (true) {
            val shouldEmit = playbackOrchestrator?.playbackState == AudioPlayerState.PLAYING || player?.isPlaying == true
            if (shouldEmit) {
                val bundle = progressUpdateEvent()
                emit(bundle)
            }

            delay((interval * 1000).toLong())
        }
    }

    @MainThread
    private suspend fun progressUpdateEvent(): Bundle {
        return withContext(Dispatchers.Main) {
            Bundle().apply {
                putDouble(POSITION_KEY, getPositionInSeconds())
                putDouble(DURATION_KEY, getDurationInSeconds())
                putDouble(BUFFERED_POSITION_KEY, getBufferedPositionInSeconds())
                putInt(TRACK_KEY, getCurrentTrackIndex())
            }
        }
    }

    private fun getPendingIntentFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT
        } else {
            PendingIntent.FLAG_CANCEL_CURRENT
        }
    }

    private fun isCompact(capability: Capability): Boolean {
        return compactCapabilities.contains(capability)
    }

    @MainThread
    fun add(track: Track) {
        add(listOf(track))
    }

    private fun AudioContentType.toExoAudioContentType(): Int {
        return when (this) {
            AudioContentType.MUSIC -> C.AUDIO_CONTENT_TYPE_MUSIC
            AudioContentType.SPEECH -> C.AUDIO_CONTENT_TYPE_SPEECH
            AudioContentType.SONIFICATION -> C.AUDIO_CONTENT_TYPE_SONIFICATION
            AudioContentType.MOVIE -> C.AUDIO_CONTENT_TYPE_MOVIE
            AudioContentType.UNKNOWN -> C.AUDIO_CONTENT_TYPE_UNKNOWN
        }
    }

    private fun playerItems(): List<TrackAudioItem> {
        return if (useOrchestratedCrossfade()) {
            crossfadeQueue.snapshot()
        } else {
            requireKotlinAudioPlayer().items.map { it as TrackAudioItem }
        }
    }

    private fun syncOrchestratorQueue() {
        playbackOrchestrator?.setQueue(playerItems())
    }

    private fun updateNotificationMetadataForIndex(index: Int) {
        val item = playerItems().getOrNull(index) ?: return
        if (useOrchestratedCrossfade()) {
            refreshOrchestratedMediaSurface(reason = "current-track", itemOverride = item)
        } else {
            val player = requireKotlinAudioPlayer()
            player.notificationManager.overrideMetadata(item)
            player.notificationManager.invalidate()
        }
    }

    private fun refreshOrchestratedMediaSurface(
        reason: String,
        itemOverride: TrackAudioItem? = null
    ) {
        val orchestrator = playbackOrchestrator ?: return
        val snapshot = orchestrator.snapshot()
        val surface = orchestratedMediaSurface ?: return
        if (itemOverride != null) {
            surface.publish(snapshot.copy(currentItem = itemOverride), reason)
        } else {
            surface.publish(snapshot, reason)
        }
    }

    private fun runOrchestratedRemoteCommand(
        reason: String,
        event: String,
        eventData: Bundle? = null,
        refreshAfter: Boolean = true,
        command: suspend (AndroidPlaybackOrchestrator) -> Unit
    ) {
        val orchestrator = playbackOrchestrator ?: return
        scope.launch {
            try {
                command(orchestrator)
                if (refreshAfter) {
                    refreshOrchestratedMediaSurface(reason = "remote-$reason")
                }
                emitHandledByNativeRemoteEvent(event, eventData)
            } catch (error: Exception) {
                androidXfadeLog("remote command failed reason=$reason error=${error.message}")
            }
        }
    }

    @MainThread
    private fun emitHandledByNativeRemoteEvent(event: String, eventData: Bundle? = null) {
        val payload = eventData ?: Bundle()
        payload.putBoolean("handledByNative", true)
        emit(event, payload)
    }

    @MainThread
    fun add(tracks: List<Track>) {
        val items = tracks.map { it.toAudioItem() }
        if (useOrchestratedCrossfade()) {
            crossfadeQueue.add(items)
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().add(items)
        }
    }

    @MainThread
    fun add(tracks: List<Track>, atIndex: Int) {
        val items = tracks.map { it.toAudioItem() }
        if (useOrchestratedCrossfade()) {
            crossfadeQueue.add(items, atIndex)
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().add(items, atIndex)
        }
    }

    @MainThread
    suspend fun load(track: Track) {
        val item = track.toAudioItem()
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            val existingIndex = crossfadeQueue.indexOfQueueId(item.track.queueId)
            if (existingIndex < 0) {
                crossfadeQueue.replaceWith(listOf(item))
            }
            syncOrchestratorQueue()
            orchestrator.load(item)
            refreshOrchestratedMediaSurface(reason = "load")
        } else {
            requireKotlinAudioPlayer().load(item)
        }
    }

    @MainThread
    fun move(fromIndex: Int, toIndex: Int) {
        if (useOrchestratedCrossfade()) {
            crossfadeQueue.move(fromIndex, toIndex)
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().move(fromIndex, toIndex)
        }
    }

    @MainThread
    fun remove(index: Int) {
        remove(listOf(index))
    }

    @MainThread
    fun remove(indexes: List<Int>) {
        if (useOrchestratedCrossfade()) {
            crossfadeQueue.remove(indexes)
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().remove(indexes)
        }
    }

    @MainThread
    fun clear() {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            crossfadeQueue.clear()
            orchestrator.stop()
            orchestratedMediaSurface?.hide()
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().clear()
        }
    }

    @MainThread
    suspend fun play() {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            syncOrchestratorQueue()
            orchestrator.play()
            refreshOrchestratedMediaSurface(reason = "play")
        } else {
            requireKotlinAudioPlayer().play()
        }
    }

    @MainThread
    fun pause() {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            orchestrator.pause()
            refreshOrchestratedMediaSurface(reason = "pause")
        } else {
            allPlayers().forEach { it.pause() }
        }
    }

    @MainThread
    fun stop() {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            orchestrator.stop()
            orchestratedMediaSurface?.hide()
        } else {
            val player = requireKotlinAudioPlayer()
            player.stop()
            player.volume = 1f
        }
    }

    @MainThread
    fun removeUpcomingTracks() {
        if (useOrchestratedCrossfade()) {
            crossfadeQueue.removeUpcoming(getCurrentTrackIndex())
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().removeUpcomingItems()
        }
    }

    @MainThread
    fun removePreviousTracks() {
        if (useOrchestratedCrossfade()) {
            crossfadeQueue.removePrevious(getCurrentTrackIndex())
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().removePreviousItems()
        }
    }

    @MainThread
    suspend fun skip(index: Int) {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            syncOrchestratorQueue()
            orchestrator.skip(index)
            refreshOrchestratedMediaSurface(reason = "skip")
        } else {
            requireKotlinAudioPlayer().jumpToItem(index)
        }
    }

    @MainThread
    suspend fun skipToNext() {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            syncOrchestratorQueue()
            orchestrator.skipToNext()
            refreshOrchestratedMediaSurface(reason = "skip-next")
        } else {
            requireKotlinAudioPlayer().next()
        }
    }

    @MainThread
    suspend fun skipToPrevious() {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            syncOrchestratorQueue()
            orchestrator.skipToPrevious()
            refreshOrchestratedMediaSurface(reason = "skip-previous")
        } else {
            requireKotlinAudioPlayer().previous()
        }
    }

    @MainThread
    suspend fun seekTo(seconds: Float) {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            orchestrator.seekTo((seconds * 1000).toLong())
            refreshOrchestratedMediaSurface(reason = "seek-to")
        } else {
            requireKotlinAudioPlayer().seek((seconds * 1000).toLong(), TimeUnit.MILLISECONDS)
        }
    }

    @MainThread
    suspend fun seekBy(offset: Float) {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            orchestrator.seekBy((offset * 1000).toLong())
            refreshOrchestratedMediaSurface(reason = "seek-by")
        } else {
            requireKotlinAudioPlayer().seekBy((offset.toLong()), TimeUnit.SECONDS)
        }
    }

    @MainThread
    suspend fun retry() {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            orchestrator.play()
            refreshOrchestratedMediaSurface(reason = "retry")
        } else {
            requireKotlinAudioPlayer().prepare()
        }
    }

    @MainThread
    fun getCurrentTrackIndex(): Int = playbackOrchestrator?.currentIndex ?: requireKotlinAudioPlayer().currentIndex

    @MainThread
    fun getRate(): Float = playbackOrchestrator?.rate ?: requireKotlinAudioPlayer().playbackSpeed

    @MainThread
    fun setRate(value: Float) {
        playbackOrchestrator?.setRate(value) ?: run {
            requireKotlinAudioPlayer().playbackSpeed = value
        }
    }

    @MainThread
    fun getRepeatMode(): RepeatMode = configuredRepeatMode

    @MainThread
    fun setRepeatMode(value: RepeatMode) {
        configuredRepeatMode = value
        (player?.playerOptions as? QueuedPlayerOptions)?.repeatMode = value
        playbackOrchestrator?.setRepeatMode(value)
    }

    @MainThread
    fun getVolume(): Float = playbackOrchestrator?.volume ?: requireKotlinAudioPlayer().volume

    @MainThread
    fun setVolume(value: Float) {
        val orchestrator = playbackOrchestrator
        if (orchestrator != null) {
            orchestrator.setVolume(value)
        } else {
            requireKotlinAudioPlayer().volume = value
        }
    }

    @MainThread
    suspend fun crossFadePrepare(previous: Boolean = false, seekTo: Double = 0.0) {
        val orchestrator = playbackOrchestrator ?: return
        syncOrchestratorQueue()
        orchestrator.crossFadePrepare(previous, seekTo)
    }

    @MainThread
    suspend fun crossFade(
        fadeDuration: Double = 5000.0,
        fadeInterval: Double = 20.0,
        fadeToVolume: Double = 1.0,
        waitUntil: Double = 0.0
    ) {
        val orchestrator = playbackOrchestrator ?: return
        syncOrchestratorQueue()
        orchestrator.crossFade(fadeDuration, fadeInterval, fadeToVolume, waitUntil)
    }

    private fun emitCrossfadeState(
        state: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int? = null,
        fromVolume: Float? = null,
        toVolume: Float? = null,
        errorCode: String? = null
    ) {
        val bundle = Bundle().apply {
            putString("state", state)
            putInt("fromIndex", fromIndex)
            putInt("toIndex", toIndex)
            elapsedMs?.let { putInt("elapsedMs", it) }
            fromVolume?.let { putDouble("fromVolume", it.toDouble()) }
            toVolume?.let { putDouble("toVolume", it.toDouble()) }
            errorCode?.let { putString("errorCode", it) }
        }
        Timber.tag("RNTP-Crossfade").d(
            "state=%s fromIndex=%s toIndex=%s elapsedMs=%s fromVolume=%s toVolume=%s error=%s",
            state,
            fromIndex,
            toIndex,
            elapsedMs,
            fromVolume,
            toVolume,
            errorCode ?: "none"
        )
        emit(MusicEvents.PLAYBACK_CROSSFADE_STATE, bundle)
    }

    @MainThread
    fun getDurationInSeconds(): Double = playbackOrchestrator?.durationMs?.toSeconds() ?: requireKotlinAudioPlayer().duration.toSeconds()

    @MainThread
    fun getPositionInSeconds(): Double = playbackOrchestrator?.positionMs?.toSeconds() ?: requireKotlinAudioPlayer().position.toSeconds()

    @MainThread
    fun getBufferedPositionInSeconds(): Double = playbackOrchestrator?.bufferedMs?.toSeconds() ?: requireKotlinAudioPlayer().bufferedPosition.toSeconds()

    @MainThread
    fun getPlayerStateBundle(state: AudioPlayerState): Bundle {
        val bundle = Bundle()
        bundle.putString(STATE_KEY, state.asLibState.state)
        if (state == AudioPlayerState.ERROR) {
            bundle.putBundle(ERROR_KEY, getPlaybackErrorBundle())
        }
        return bundle
    }

    @MainThread
    fun getPlayerLifecycleBundle(
        serviceBound: Boolean,
        playerInitialized: Boolean,
        setupInProgress: Boolean
    ): Bundle {
        val items = playerItems()
        val activeIndex = getCurrentTrackIndex()
        return Bundle().apply {
            putString("phase", if (setupInProgress) "settingUp" else "ready")
            putBoolean("serviceBound", serviceBound)
            putBoolean("playerInitialized", playerInitialized)
            putBoolean("setupInProgress", setupInProgress)
            putBoolean("canAcceptCommands", serviceBound && playerInitialized && !setupInProgress)
            putString("playbackState", state.asLibState.state)
            putBoolean("playWhenReady", playWhenReady)
            putString("backend", if (useOrchestratedCrossfade()) "crossfade" else "standard")
            putInt("queueSize", items.size)
            if (activeIndex in items.indices) {
                putInt("activeTrackIndex", activeIndex)
            } else {
                putString("activeTrackIndex", null)
            }
        }
    }

    @MainThread
    fun updateMetadataForTrack(index: Int, track: Track) {
        if (useOrchestratedCrossfade()) {
            crossfadeQueue.replace(index, track.toAudioItem())
            syncOrchestratorQueue()
        } else {
            requireKotlinAudioPlayer().replaceItem(index, track.toAudioItem())
        }
        if (playbackOrchestrator?.currentIndex == index) {
            updateNotificationMetadataForIndex(index)
        }
    }

    @MainThread
    fun updateNowPlayingMetadata(track: Track) {
        val item = track.toAudioItem()
        if (useOrchestratedCrossfade()) {
            playbackOrchestrator?.setNowPlayingOverride(item)
        } else {
            requireKotlinAudioPlayer().notificationManager.overrideMetadata(item)
        }
    }

    @MainThread
    fun clearNotificationMetadata() {
        if (useOrchestratedCrossfade()) {
            playbackOrchestrator?.setNowPlayingOverride(null)
            refreshOrchestratedMediaSurface(reason = "clear-metadata")
        } else {
            requireKotlinAudioPlayer().notificationManager.hideNotification()
        }
    }

    private fun emitPlaybackTrackChangedEvents(
        index: Int?,
        previousIndex: Int?,
        oldPosition: Double
    ) {
        val a = Bundle()
        a.putDouble(POSITION_KEY, oldPosition)
        if (index != null) {
            a.putInt(NEXT_TRACK_KEY, index)
        }

        if (previousIndex != null) {
            a.putInt(TRACK_KEY, previousIndex)
        }

        emit(MusicEvents.PLAYBACK_TRACK_CHANGED, a)

        val b = Bundle()
        b.putDouble("lastPosition", oldPosition)
        val activeIndex = index ?: getCurrentTrackIndex()
        if (tracks.isNotEmpty() && activeIndex in tracks.indices) {
            b.putInt("index", activeIndex)
            b.putBundle("track", tracks[activeIndex].originalItem)
            if (previousIndex != null && previousIndex in tracks.indices) {
                b.putInt("lastIndex", previousIndex)
                b.putBundle("lastTrack", tracks[previousIndex].originalItem)
            }
        }
        emit(MusicEvents.PLAYBACK_ACTIVE_TRACK_CHANGED, b)
    }

    private fun emitQueueEndedEvent() {
        emitQueueEndedEvent(getCurrentTrackIndex(), getPositionInSeconds().toMilliseconds())
    }

    private fun emitQueueEndedEvent(index: Int, positionMs: Long) {
        val bundle = Bundle()
        bundle.putInt(TRACK_KEY, index)
        bundle.putDouble(POSITION_KEY, positionMs.toSeconds())
        emit(MusicEvents.PLAYBACK_QUEUE_ENDED, bundle)
    }

    @Suppress("DEPRECATION")
    fun isForegroundService(): Boolean {
        val manager = baseContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        for (service in manager.getRunningServices(Int.MAX_VALUE)) {
            if (MusicService::class.java.name == service.service.className) {
                return service.foreground
            }
        }
        Timber.e("isForegroundService found no matching service")
        return false
    }

    @MainThread
    private fun setupForegrounding() {
        if (useOrchestratedCrossfade()) return

        // Implementation based on https://github.com/Automattic/pocket-casts-android/blob/ee8da0c095560ef64a82d3a31464491b8d713104/modules/services/repositories/src/main/java/au/com/shiftyjelly/pocketcasts/repositories/playback/PlaybackService.kt#L218
        var notificationId: Int? = null
        var notification: Notification? = null
        var stopForegroundWhenNotOngoing = false
        var removeNotificationWhenNotOngoing = false

        fun startForegroundIfNecessary() {
            if (isForegroundService()) {
                Timber.d("skipping foregrounding as the service is already foregrounded")
                return
            }
            if (notification == null) {
                Timber.d("can't startForeground as the notification is null")
                return
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        notificationId!!,
                        notification!!,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                    )
                } else {
                    startForeground(notificationId!!, notification)
                }
                Timber.d("notification has been foregrounded")
            } catch (error: Exception) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    error is ForegroundServiceStartNotAllowedException
                ) {
                    Timber.e(
                        "ForegroundServiceStartNotAllowedException: App tried to start a foreground Service when it was not allowed to do so.",
                        error
                    )
                    emit(MusicEvents.PLAYER_ERROR, Bundle().apply {
                        putString("message", error.message)
                        putString("code", "android-foreground-service-start-not-allowed")
                    });
                }
            }
        }

        fun observeForegrounding(source: QueuedAudioPlayer) = scope.launch {
            val BACKGROUNDABLE_STATES = listOf(
                AudioPlayerState.IDLE,
                AudioPlayerState.ENDED,
                AudioPlayerState.STOPPED,
                AudioPlayerState.ERROR,
                AudioPlayerState.PAUSED
            )
            val REMOVABLE_STATES = listOf(
                AudioPlayerState.IDLE,
                AudioPlayerState.STOPPED,
                AudioPlayerState.ERROR
            )
            val LOADING_STATES = listOf(
                AudioPlayerState.LOADING,
                AudioPlayerState.READY,
                AudioPlayerState.BUFFERING
            )
            var stateCount = 0
            source.event.stateChange.collect {
                if (!isActivePlayer(source)) return@collect
                stateCount++
                if (it in LOADING_STATES) return@collect;
                // Skip initial idle state, since we are only interested when
                // state becomes idle after not being idle
                stopForegroundWhenNotOngoing = stateCount > 1 && it in BACKGROUNDABLE_STATES
                removeNotificationWhenNotOngoing = stopForegroundWhenNotOngoing && it in REMOVABLE_STATES
            }
        }

        fun shouldStopForeground(): Boolean {
            return stopForegroundWhenNotOngoing && (removeNotificationWhenNotOngoing || isForegroundService())
        }

        fun observeNotification(source: QueuedAudioPlayer) = scope.launch {
            source.event.notificationStateChange.collect {
                if (!isActivePlayer(source)) return@collect
                when (it) {
                    is NotificationState.POSTED -> {
                        Timber.d("notification posted with id=%s, ongoing=%s", it.notificationId, it.ongoing)
                        notificationId = it.notificationId;
                        notification = it.notification;
                        if (it.ongoing) {
                            if (playWhenReady) {
                                startForegroundIfNecessary()
                            }
                        } else if (shouldStopForeground()) {
                            // Allow the application a grace period to complete any actions
                            // that may necessitate keeping the service in a foreground state.
                            // For instance, queuing new media (e.g., related music) after the
                            // user's queue is complete. This prevents the service from potentially
                            // being immediately destroyed once the player finishes playing media.
                            scope.launch {
                                delay(stopForegroundGracePeriod.toLong() * 1000)
                                if (shouldStopForeground()) {
                                    @Suppress("DEPRECATION")
                                    stopForeground(removeNotificationWhenNotOngoing)
                                    Timber.d("Notification has been stopped")
                                }
                            }
                        }
                    }
                    else -> {}
                }
            }
        }

        allPlayers().forEach {
            observeForegrounding(it)
            observeNotification(it)
        }
    }

    @MainThread
    private fun observeEvents() {
        fun observePlayerEvents(source: QueuedAudioPlayer) {
            scope.launch {
            source.event.stateChange.collect {
                if (!isActivePlayer(source)) return@collect
                if (useOrchestratedCrossfade()) return@collect
                emit(MusicEvents.PLAYBACK_STATE, getPlayerStateBundle(it))

                if (it == AudioPlayerState.ENDED && source.nextItem == null) {
                    emitQueueEndedEvent()
                }
            }
        }

        scope.launch {
            source.event.audioItemTransition.collect {
                if (!isActivePlayer(source)) return@collect
                if (useOrchestratedCrossfade()) return@collect
                if (it !is AudioItemTransitionReason.REPEAT) {
                    emitPlaybackTrackChangedEvents(
                        source.currentIndex,
                        source.previousIndex,
                        (it?.oldPosition ?: 0).toSeconds()
                    )
                }
            }
        }

        scope.launch {
            source.event.onAudioFocusChanged.collect {
                if (!isActivePlayer(source)) return@collect
                Bundle().apply {
                    putBoolean(IS_FOCUS_LOSS_PERMANENT_KEY, it.isFocusLostPermanently)
                    putBoolean(IS_PAUSED_KEY, it.isPaused)
                    emit(MusicEvents.BUTTON_DUCK, this)
                }
            }
        }

        scope.launch {
            source.event.onPlayerActionTriggeredExternally.collect {
                if (!isActivePlayer(source)) return@collect
                if (useOrchestratedCrossfade()) return@collect
                when (it) {
                    is MediaSessionCallback.RATING -> {
                        Bundle().apply {
                            setRating(this, "rating", it.rating)
                            emit(MusicEvents.BUTTON_SET_RATING, this)
                        }
                    }
                    is MediaSessionCallback.SEEK -> {
                        Bundle().apply {
                            putDouble("position", it.positionMs.toSeconds())
                            emit(MusicEvents.BUTTON_SEEK_TO, this)
                        }
                    }
                    MediaSessionCallback.PLAY -> emit(MusicEvents.BUTTON_PLAY)
                    MediaSessionCallback.PAUSE -> emit(MusicEvents.BUTTON_PAUSE)
                    MediaSessionCallback.NEXT -> emit(MusicEvents.BUTTON_SKIP_NEXT)
                    MediaSessionCallback.PREVIOUS -> emit(MusicEvents.BUTTON_SKIP_PREVIOUS)
                    MediaSessionCallback.STOP -> emit(MusicEvents.BUTTON_STOP)
                    MediaSessionCallback.FORWARD -> {
                        Bundle().apply {
                            val interval = latestOptions?.getDouble(FORWARD_JUMP_INTERVAL_KEY, DEFAULT_JUMP_INTERVAL) ?: DEFAULT_JUMP_INTERVAL
                            putInt("interval", interval.toInt())
                            emit(MusicEvents.BUTTON_JUMP_FORWARD, this)
                        }
                    }
                    MediaSessionCallback.REWIND -> {
                        Bundle().apply {
                            val interval = latestOptions?.getDouble(BACKWARD_JUMP_INTERVAL_KEY, DEFAULT_JUMP_INTERVAL) ?: DEFAULT_JUMP_INTERVAL
                            putInt("interval", interval.toInt())
                            emit(MusicEvents.BUTTON_JUMP_BACKWARD, this)
                        }
                    }
                }
            }
        }

        scope.launch {
            source.event.onTimedMetadata.collect {
                if (!isActivePlayer(source)) return@collect
                if (useOrchestratedCrossfade()) return@collect
                val data = MetadataAdapter.fromMetadata(it)
                val bundle = Bundle().apply {
                    putParcelableArrayList(METADATA_PAYLOAD_KEY, ArrayList(data))
                }
                emit(MusicEvents.METADATA_TIMED_RECEIVED, bundle)

                // TODO: Handle the different types of metadata and publish to new events
                val metadata = PlaybackMetadata.fromId3Metadata(it)
                    ?: PlaybackMetadata.fromIcy(it)
                    ?: PlaybackMetadata.fromVorbisComment(it)
                    ?: PlaybackMetadata.fromQuickTime(it)

                if (metadata != null) {
                    Bundle().apply {
                        putString("source", metadata.source)
                        putString("title", metadata.title)
                        putString("url", metadata.url)
                        putString("artist", metadata.artist)
                        putString("album", metadata.album)
                        putString("date", metadata.date)
                        putString("genre", metadata.genre)
                        emit(MusicEvents.PLAYBACK_METADATA, this)
                    }
                }
            }
        }

        scope.launch {
            source.event.onCommonMetadata.collect {
                if (!isActivePlayer(source)) return@collect
                if (useOrchestratedCrossfade()) return@collect
                val data = MetadataAdapter.fromMediaMetadata(it)
                val bundle = Bundle().apply {
                    putBundle(METADATA_PAYLOAD_KEY, data)
                }
                emit(MusicEvents.METADATA_COMMON_RECEIVED, bundle)
            }
        }

        scope.launch {
            source.event.playWhenReadyChange.collect {
                if (!isActivePlayer(source)) return@collect
                if (useOrchestratedCrossfade()) return@collect
                Bundle().apply {
                    putBoolean("playWhenReady", it.playWhenReady)
                    emit(MusicEvents.PLAYBACK_PLAY_WHEN_READY_CHANGED, this)
                }
            }
        }

        scope.launch {
            source.event.playbackError.collect {
                if (!isActivePlayer(source)) return@collect
                if (useOrchestratedCrossfade()) return@collect
                emit(MusicEvents.PLAYBACK_ERROR, getPlaybackErrorBundle())
            }
        }
        }

        allPlayers().forEach { observePlayerEvents(it) }
    }

    private fun getPlaybackErrorBundle(): Bundle {
        val bundle = Bundle()
        val error = playbackError
        if (error?.message != null) {
            bundle.putString("message", error.message)
        }
        if (error?.code != null) {
            bundle.putString("code", "android-" + error.code)
        }
        return bundle
    }

    @MainThread
    private fun emit(event: String, data: Bundle? = null) {
        val intent = Intent(MusicEvents.EVENT_INTENT).apply {
            putExtra("event", event)
            data?.let { putExtra("data", it) }
        }
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    override fun getTaskConfig(intent: Intent?): HeadlessJsTaskConfig {
        return HeadlessJsTaskConfig(TASK_KEY, Arguments.createMap(), 0, true)
    }

    @MainThread
    override fun onBind(intent: Intent): IBinder {
        return binder
    }

    @MainThread
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)

        if (!isPrimaryPlayerInitialized()) return

        when (appKilledPlaybackBehavior) {
            AppKilledPlaybackBehavior.PAUSE_PLAYBACK -> pause()
            AppKilledPlaybackBehavior.STOP_PLAYBACK_AND_REMOVE_NOTIFICATION -> {
                playbackOrchestrator?.stop()
                orchestratedMediaSurface?.hide()
                crossfadeQueue.clear()
                player?.clear()
                player?.stop()

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }

                stopSelf()
                exitProcess(0)
            }
            else -> {}
        }
    }

    @MainThread
    override fun onHeadlessJsTaskFinish(taskId: Int) {
        // This is empty so ReactNative doesn't kill this service
    }

    @MainThread
    override fun onDestroy() {
        super.onDestroy()
        allPlayers().forEach { it.destroy() }
        playbackOrchestrator?.release()
        playbackOrchestrator = null

        progressUpdateJob?.cancel()
        orchestratedMediaSurface?.release()
        orchestratedMediaSurface = null
    }

    @MainThread
    inner class MusicBinder : Binder() {
        val service = this@MusicService
    }

    companion object {
        const val EMPTY_NOTIFICATION_ID = 1
        const val STATE_KEY = "state"
        const val ERROR_KEY  = "error"
        const val EVENT_KEY = "event"
        const val DATA_KEY = "data"
        const val TRACK_KEY = "track"
        const val NEXT_TRACK_KEY = "nextTrack"
        const val POSITION_KEY = "position"
        const val DURATION_KEY = "duration"
        const val BUFFERED_POSITION_KEY = "buffered"

        const val TASK_KEY = "TrackPlayer"

        const val MIN_BUFFER_KEY = "minBuffer"
        const val MAX_BUFFER_KEY = "maxBuffer"
        const val PLAY_BUFFER_KEY = "playBuffer"
        const val BACK_BUFFER_KEY = "backBuffer"

        const val FORWARD_JUMP_INTERVAL_KEY = "forwardJumpInterval"
        const val BACKWARD_JUMP_INTERVAL_KEY = "backwardJumpInterval"
        const val PROGRESS_UPDATE_EVENT_INTERVAL_KEY = "progressUpdateEventInterval"

        const val MAX_CACHE_SIZE_KEY = "maxCacheSize"

        const val ANDROID_OPTIONS_KEY = "android"

        const val STOPPING_APP_PAUSES_PLAYBACK_KEY = "stoppingAppPausesPlayback"
        const val APP_KILLED_PLAYBACK_BEHAVIOR_KEY = "appKilledPlaybackBehavior"
        const val STOP_FOREGROUND_GRACE_PERIOD_KEY = "stopForegroundGracePeriod"
        const val PAUSE_ON_INTERRUPTION_KEY = "alwaysPauseOnInterruption"
        const val AUTO_UPDATE_METADATA = "autoUpdateMetadata"
        const val AUTO_HANDLE_INTERRUPTIONS = "autoHandleInterruptions"
        const val ANDROID_AUDIO_CONTENT_TYPE = "androidAudioContentType"
        const val CROSSFADE_KEY = "crossfade"
        const val IS_FOCUS_LOSS_PERMANENT_KEY = "permanent"
        const val IS_PAUSED_KEY = "paused"

        const val DEFAULT_JUMP_INTERVAL = 15.0
        const val DEFAULT_STOP_FOREGROUND_GRACE_PERIOD = 5
        const val CROSSFADE_PREPARE_TIMEOUT_MS = 2500L
        const val CROSSFADE_RUNNING_EVENT_INTERVAL_MS = 250L
    }
}
