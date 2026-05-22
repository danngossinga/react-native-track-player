package com.doublesymmetry.trackplayer.service

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.RatingCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.PRIORITY_LOW
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media.session.MediaButtonReceiver
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.Capability
import com.doublesymmetry.trackplayer.R as TrackPlayerR
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.google.android.exoplayer2.ui.R as ExoPlayerR
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import timber.log.Timber
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.roundToInt

internal data class AndroidArtworkRequestOptions(
    val headers: Map<String, String> = emptyMap(),
    val userAgent: String? = null
)

internal data class AndroidOrchestratedMediaSurfaceConfig(
    val notificationCapabilities: List<Capability> = emptyList(),
    val compactCapabilities: List<Capability> = emptyList(),
    val accentColor: Int? = null,
    val smallIcon: Int? = null,
    val playIcon: Int? = null,
    val pauseIcon: Int? = null,
    val stopIcon: Int? = null,
    val nextIcon: Int? = null,
    val previousIcon: Int? = null,
    val forwardIcon: Int? = null,
    val rewindIcon: Int? = null,
    val contentIntent: PendingIntent? = null,
    val forwardJumpInterval: Int,
    val backwardJumpInterval: Int
)

internal interface AndroidOrchestratedMediaSurfaceDelegate {
    fun onRemotePlay()
    fun onRemotePause()
    fun onRemoteStop()
    fun onRemoteNext()
    fun onRemotePrevious()
    fun onRemoteSeekTo(positionMs: Long)
    fun onRemoteJumpForward(interval: Int)
    fun onRemoteJumpBackward(interval: Int)
    fun onRemoteSetRating(rating: RatingCompat)
    fun onForegroundServiceStartError(error: Exception)
}

internal class AndroidOrchestratedMediaSurface(
    private val service: MusicService,
    private val scope: CoroutineScope,
    private val delegate: AndroidOrchestratedMediaSurfaceDelegate
) {
    private val notificationManager =
        service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val artworkBitmapCache = linkedMapOf<String, Bitmap>()
    private var artworkJob: Job? = null
    private var loadingArtworkKey: String? = null
    private var lastSnapshot: AndroidPlaybackSnapshot? = null
    private var config = AndroidOrchestratedMediaSurfaceConfig(
        forwardJumpInterval = DEFAULT_JUMP_INTERVAL,
        backwardJumpInterval = DEFAULT_JUMP_INTERVAL
    )

    val mediaSession: MediaSessionCompat = MediaSessionCompat(service, MEDIA_SESSION_TAG).apply {
        setFlags(MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS)
        setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() = delegate.onRemotePlay()
            override fun onPause() = delegate.onRemotePause()
            override fun onStop() = delegate.onRemoteStop()
            override fun onSkipToNext() = delegate.onRemoteNext()
            override fun onSkipToPrevious() = delegate.onRemotePrevious()
            override fun onSeekTo(pos: Long) = delegate.onRemoteSeekTo(pos)
            override fun onFastForward() = delegate.onRemoteJumpForward(config.forwardJumpInterval)
            override fun onRewind() = delegate.onRemoteJumpBackward(config.backwardJumpInterval)
            override fun onSetRating(rating: RatingCompat) = delegate.onRemoteSetRating(rating)
        })
        isActive = true
    }

    fun updateConfig(value: AndroidOrchestratedMediaSurfaceConfig) {
        config = value
        lastSnapshot?.let { publish(it, "config") }
    }

    fun handleIntent(intent: Intent?): Boolean {
        val action = intent?.action ?: return false
        return when (action) {
            Intent.ACTION_MEDIA_BUTTON -> {
                MediaButtonReceiver.handleIntent(mediaSession, intent)
                true
            }
            ACTION_PLAY -> {
                delegate.onRemotePlay()
                true
            }
            ACTION_PAUSE -> {
                delegate.onRemotePause()
                true
            }
            ACTION_STOP -> {
                delegate.onRemoteStop()
                true
            }
            ACTION_NEXT -> {
                delegate.onRemoteNext()
                true
            }
            ACTION_PREVIOUS -> {
                delegate.onRemotePrevious()
                true
            }
            ACTION_FORWARD -> {
                delegate.onRemoteJumpForward(config.forwardJumpInterval)
                true
            }
            ACTION_REWIND -> {
                delegate.onRemoteJumpBackward(config.backwardJumpInterval)
                true
            }
            else -> false
        }
    }

    fun publish(snapshot: AndroidPlaybackSnapshot, reason: String) {
        lastSnapshot = snapshot
        ensureNotificationChannel()
        mediaSession.isActive = true
        mediaSession.setMetadata(buildMetadata(snapshot.currentItem, artworkFor(snapshot.currentItem)))
        mediaSession.setPlaybackState(buildPlaybackState(snapshot))

        val notification = buildNotification(snapshot)
        if (shouldBeForeground(snapshot)) {
            startForeground(notification)
        } else {
            stopForegroundButKeepNotification()
            notificationManager.notify(NOTIFICATION_ID, notification)
        }
        maybeLoadArtwork(snapshot.currentItem)
        androidXfadeLog(
            "media surface publish reason=$reason index=${snapshot.currentIndex} " +
                "state=${snapshot.playbackState} hasBitmap=${artworkFor(snapshot.currentItem) != null}"
        )
    }

    fun hide() {
        artworkJob?.cancel()
        loadingArtworkKey = null
        lastSnapshot = null
        mediaSession.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setState(PlaybackStateCompat.STATE_STOPPED, 0L, 0f)
                .build()
        )
        mediaSession.setMetadata(MediaMetadataCompat.Builder().build())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
        notificationManager.cancel(NOTIFICATION_ID)
    }

    fun release() {
        hide()
        mediaSession.release()
    }

    private fun buildNotification(snapshot: AndroidPlaybackSnapshot): Notification {
        val actions = mutableListOf<Pair<Capability, NotificationCompat.Action>>()
        normalizedNotificationCapabilities(snapshot).forEach { capability ->
            buildAction(capability, snapshot)?.let { action ->
                val key = if (capability == Capability.PLAY || capability == Capability.PAUSE) {
                    if (snapshot.playWhenReady) Capability.PAUSE else Capability.PLAY
                } else {
                    capability
                }
                actions.add(key to action)
            }
        }

        val compactIndexes = actions.mapIndexedNotNull { index, pair ->
            if (config.compactCapabilities.contains(pair.first)) index else null
        }.toIntArray()

        val item = snapshot.currentItem
        val builder = NotificationCompat.Builder(service, CHANNEL_ID)
            .setPriority(PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setSmallIcon(config.smallIcon ?: ExoPlayerR.drawable.exo_notification_small_icon)
            .setContentTitle(item?.title ?: "")
            .setContentText(item?.artist ?: "")
            .setSubText(item?.albumTitle)
            .setContentIntent(config.contentIntent)
            .setDeleteIntent(actionIntent(ACTION_STOP))
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(shouldBeForeground(snapshot))
            .setLargeIcon(artworkFor(item))
            .setStyle(
                MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(*compactIndexes)
            )

        config.accentColor?.let { builder.color = it }
        actions.forEach { builder.addAction(it.second) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.foregroundServiceBehavior = NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE
        }
        return builder.build()
    }

    private fun buildAction(
        capability: Capability,
        snapshot: AndroidPlaybackSnapshot
    ): NotificationCompat.Action? {
        return when (capability) {
            Capability.PLAY, Capability.PAUSE -> {
                if (snapshot.playWhenReady) {
                    NotificationCompat.Action(
                        config.pauseIcon ?: ExoPlayerR.drawable.exo_icon_pause,
                        "Pause",
                        actionIntent(ACTION_PAUSE)
                    )
                } else {
                    NotificationCompat.Action(
                        config.playIcon ?: ExoPlayerR.drawable.exo_icon_play,
                        "Play",
                        actionIntent(ACTION_PLAY)
                    )
                }
            }
            Capability.STOP -> NotificationCompat.Action(
                config.stopIcon ?: ExoPlayerR.drawable.exo_icon_stop,
                "Stop",
                actionIntent(ACTION_STOP)
            )
            Capability.SKIP_TO_NEXT -> if (snapshot.hasNext) {
                NotificationCompat.Action(
                    config.nextIcon ?: ExoPlayerR.drawable.exo_icon_next,
                    "Next",
                    actionIntent(ACTION_NEXT)
                )
            } else {
                null
            }
            Capability.SKIP_TO_PREVIOUS -> if (snapshot.hasPrevious) {
                NotificationCompat.Action(
                    config.previousIcon ?: ExoPlayerR.drawable.exo_icon_previous,
                    "Previous",
                    actionIntent(ACTION_PREVIOUS)
                )
            } else {
                null
            }
            Capability.JUMP_FORWARD -> NotificationCompat.Action(
                config.forwardIcon ?: ExoPlayerR.drawable.exo_icon_fastforward,
                "Forward",
                actionIntent(ACTION_FORWARD)
            )
            Capability.JUMP_BACKWARD -> NotificationCompat.Action(
                config.rewindIcon ?: ExoPlayerR.drawable.exo_icon_rewind,
                "Rewind",
                actionIntent(ACTION_REWIND)
            )
            else -> null
        }
    }

    private fun buildMetadata(item: TrackAudioItem?, artworkBitmap: Bitmap?): MediaMetadataCompat {
        return MediaMetadataCompat.Builder().apply {
            item?.title?.let {
                putString(MediaMetadataCompat.METADATA_KEY_TITLE, it)
                putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, it)
            }
            item?.artist?.let {
                putString(MediaMetadataCompat.METADATA_KEY_ARTIST, it)
                putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, it)
            }
            item?.albumTitle?.let {
                putString(MediaMetadataCompat.METADATA_KEY_ALBUM, it)
                putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_DESCRIPTION, it)
            }
            item?.duration?.let { putLong(MediaMetadataCompat.METADATA_KEY_DURATION, it) }
            item?.artwork?.takeIf { it.isNotBlank() && it != "null" }?.let {
                putString(MediaMetadataCompat.METADATA_KEY_ART_URI, it)
                putString(MediaMetadataCompat.METADATA_KEY_ALBUM_ART_URI, it)
                putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI, it)
            }
            artworkBitmap?.let {
                putBitmap(MediaMetadataCompat.METADATA_KEY_ART, it)
                putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, it)
                putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, it)
            }
        }.build()
    }

    private fun buildPlaybackState(snapshot: AndroidPlaybackSnapshot): PlaybackStateCompat {
        val actions = mediaSessionActions(snapshot)
        val state = when (snapshot.playbackState) {
            AudioPlayerState.PLAYING -> PlaybackStateCompat.STATE_PLAYING
            AudioPlayerState.PAUSED -> PlaybackStateCompat.STATE_PAUSED
            AudioPlayerState.BUFFERING,
            AudioPlayerState.LOADING,
            AudioPlayerState.READY -> PlaybackStateCompat.STATE_BUFFERING
            AudioPlayerState.ENDED -> PlaybackStateCompat.STATE_STOPPED
            AudioPlayerState.STOPPED -> PlaybackStateCompat.STATE_STOPPED
            AudioPlayerState.ERROR -> PlaybackStateCompat.STATE_ERROR
            else -> PlaybackStateCompat.STATE_NONE
        }
        val playbackSpeed = if (snapshot.playWhenReady && state == PlaybackStateCompat.STATE_PLAYING) {
            snapshot.rate
        } else {
            0f
        }
        return PlaybackStateCompat.Builder()
            .setActions(actions)
            .setState(state, snapshot.positionMs, playbackSpeed)
            .setBufferedPosition(snapshot.bufferedMs)
            .build()
    }

    private fun mediaSessionActions(snapshot: AndroidPlaybackSnapshot): Long {
        var actions = 0L
        val capabilities = normalizedNotificationCapabilities(snapshot)
        if (capabilities.contains(Capability.PLAY)) {
            actions = actions or PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PLAY_PAUSE
        }
        if (capabilities.contains(Capability.PAUSE)) {
            actions = actions or PlaybackStateCompat.ACTION_PAUSE or PlaybackStateCompat.ACTION_PLAY_PAUSE
        }
        if (capabilities.contains(Capability.STOP)) {
            actions = actions or PlaybackStateCompat.ACTION_STOP
        }
        if (capabilities.contains(Capability.SKIP_TO_NEXT)) {
            actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        }
        if (capabilities.contains(Capability.SKIP_TO_PREVIOUS)) {
            actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        }
        if (capabilities.contains(Capability.SEEK_TO)) {
            actions = actions or PlaybackStateCompat.ACTION_SEEK_TO
        }
        if (capabilities.contains(Capability.JUMP_FORWARD)) {
            actions = actions or PlaybackStateCompat.ACTION_FAST_FORWARD
        }
        if (capabilities.contains(Capability.JUMP_BACKWARD)) {
            actions = actions or PlaybackStateCompat.ACTION_REWIND
        }
        return actions
    }

    private fun normalizedNotificationCapabilities(snapshot: AndroidPlaybackSnapshot): List<Capability> {
        val output = mutableListOf<Capability>()
        var addedTransportToggle = false
        config.notificationCapabilities.forEach { capability ->
            when (capability) {
                Capability.PLAY, Capability.PAUSE -> {
                    if (!addedTransportToggle) {
                        output.add(if (snapshot.playWhenReady) Capability.PAUSE else Capability.PLAY)
                        addedTransportToggle = true
                    }
                }
                Capability.SKIP_TO_NEXT -> if (snapshot.hasNext) output.add(capability)
                Capability.SKIP_TO_PREVIOUS -> if (snapshot.hasPrevious) output.add(capability)
                else -> output.add(capability)
            }
        }
        return output
    }

    private fun shouldBeForeground(snapshot: AndroidPlaybackSnapshot): Boolean {
        return snapshot.playWhenReady &&
            snapshot.playbackState != AudioPlayerState.PAUSED &&
            snapshot.playbackState != AudioPlayerState.STOPPED &&
            snapshot.playbackState != AudioPlayerState.ENDED &&
            snapshot.playbackState != AudioPlayerState.IDLE &&
            snapshot.playbackState != AudioPlayerState.ERROR
    }

    private fun startForeground(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                service.startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                service.startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                error is ForegroundServiceStartNotAllowedException
            ) {
                delegate.onForegroundServiceStartError(error)
            } else {
                Timber.tag("RNTP-Crossfade").e(error, "orchestrated startForeground failed")
            }
        }
    }

    private fun stopForegroundButKeepNotification() {
        if (!service.isForegroundService()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(false)
        }
    }

    private fun maybeLoadArtwork(item: TrackAudioItem?) {
        val artwork = normalizedArtworkKey(item) ?: return
        if (artworkBitmapCache.containsKey(artwork)) return
        if (loadingArtworkKey == artwork) return
        loadingArtworkKey = artwork
        artworkJob?.cancel()
        artworkJob = scope.launch {
            val options = artworkRequestOptions(item, artwork)
            val bitmap = withContext(Dispatchers.IO) { loadArtworkBitmap(artwork, options) }
            if (loadingArtworkKey == artwork) {
                loadingArtworkKey = null
            }
            if (bitmap == null) {
                androidXfadeLog("media surface artwork unavailable")
                return@launch
            }
            cacheArtworkBitmap(artwork, bitmap)
            val snapshot = lastSnapshot ?: return@launch
            if (normalizedArtworkKey(snapshot.currentItem) == artwork) {
                publish(snapshot, "artwork-bitmap")
            }
        }
    }

    private fun artworkFor(item: TrackAudioItem?): Bitmap? {
        return normalizedArtworkKey(item)?.let { artworkBitmapCache[it] }
    }

    private fun normalizedArtworkKey(item: TrackAudioItem?): String? {
        return item?.artwork?.takeIf { it.isNotBlank() && it != "null" }
    }

    private fun artworkRequestOptions(
        item: TrackAudioItem?,
        artwork: String
    ): AndroidArtworkRequestOptions {
        val audioUri = Uri.parse(item?.audioUrl ?: return AndroidArtworkRequestOptions())
        val artworkUri = Uri.parse(artwork)
        val sameOrigin = audioUri.scheme.equals(artworkUri.scheme, ignoreCase = true) &&
            audioUri.host.equals(artworkUri.host, ignoreCase = true) &&
            normalizedPort(audioUri) == normalizedPort(artworkUri)
        if (!sameOrigin) return AndroidArtworkRequestOptions()
        return AndroidArtworkRequestOptions(
            headers = item.options?.headers ?: emptyMap(),
            userAgent = item.options?.userAgent
        )
    }

    private fun normalizedPort(uri: Uri): Int {
        if (uri.port != -1) return uri.port
        return when (uri.scheme?.lowercase()) {
            "http" -> 80
            "https" -> 443
            else -> -1
        }
    }

    private fun cacheArtworkBitmap(key: String, bitmap: Bitmap) {
        artworkBitmapCache[key] = bitmap
        while (artworkBitmapCache.size > MAX_ARTWORK_BITMAP_CACHE_SIZE) {
            val firstKey = artworkBitmapCache.keys.firstOrNull() ?: return
            artworkBitmapCache.remove(firstKey)
        }
    }

    private fun loadArtworkBitmap(artwork: String, options: AndroidArtworkRequestOptions): Bitmap? {
        return try {
            val uri = Uri.parse(artwork)
            val rawBitmap = when (uri.scheme?.lowercase()) {
                "http", "https" -> {
                    val connection = (URL(artwork).openConnection() as HttpURLConnection).apply {
                        connectTimeout = ARTWORK_CONNECT_TIMEOUT_MS
                        readTimeout = ARTWORK_READ_TIMEOUT_MS
                        instanceFollowRedirects = true
                        options.userAgent?.takeIf { it.isNotBlank() }?.let {
                            setRequestProperty("User-Agent", it)
                        }
                        options.headers.forEach { (name, value) ->
                            setRequestProperty(name, value)
                        }
                    }
                    connection.inputStream.use { BitmapFactory.decodeStream(it) }
                }
                "content", "file", "android.resource" -> {
                    service.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
                }
                else -> null
            }
            rawBitmap?.let { constrainArtworkBitmap(it) }
        } catch (error: Exception) {
            androidXfadeLog("media surface artwork load failed error=${error.javaClass.simpleName}")
            null
        }
    }

    private fun constrainArtworkBitmap(bitmap: Bitmap): Bitmap {
        val largestSide = maxOf(bitmap.width, bitmap.height)
        if (largestSide <= MAX_ARTWORK_BITMAP_SIZE_PX) return bitmap

        val scale = MAX_ARTWORK_BITMAP_SIZE_PX.toFloat() / largestSide.toFloat()
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).roundToInt().coerceAtLeast(1),
            (bitmap.height * scale).roundToInt().coerceAtLeast(1),
            true
        )
    }

    private fun actionIntent(action: String): PendingIntent {
        val intent = Intent(service, MusicService::class.java).setAction(action)
        return PendingIntent.getService(service, action.hashCode(), intent, pendingIntentFlags())
    }

    private fun pendingIntentFlags(): Int {
        val base = PendingIntent.FLAG_UPDATE_CURRENT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            base or PendingIntent.FLAG_IMMUTABLE
        } else {
            base
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            service.getString(TrackPlayerR.string.rntp_orchestrated_channel_name),
            NotificationManager.IMPORTANCE_LOW
        )
        notificationManager.createNotificationChannel(channel)
    }

    private companion object {
        const val MEDIA_SESSION_TAG = "RNTP-OrchestratedCrossfade"
        const val CHANNEL_ID = "rntp_orchestrated_media"
        const val NOTIFICATION_ID = 2
        const val ACTION_PLAY = "com.doublesymmetry.trackplayer.ORCH_PLAY"
        const val ACTION_PAUSE = "com.doublesymmetry.trackplayer.ORCH_PAUSE"
        const val ACTION_STOP = "com.doublesymmetry.trackplayer.ORCH_STOP"
        const val ACTION_NEXT = "com.doublesymmetry.trackplayer.ORCH_NEXT"
        const val ACTION_PREVIOUS = "com.doublesymmetry.trackplayer.ORCH_PREVIOUS"
        const val ACTION_FORWARD = "com.doublesymmetry.trackplayer.ORCH_FORWARD"
        const val ACTION_REWIND = "com.doublesymmetry.trackplayer.ORCH_REWIND"
        const val ARTWORK_CONNECT_TIMEOUT_MS = 2500
        const val ARTWORK_READ_TIMEOUT_MS = 2500
        const val MAX_ARTWORK_BITMAP_CACHE_SIZE = 8
        const val MAX_ARTWORK_BITMAP_SIZE_PX = 512
        const val DEFAULT_JUMP_INTERVAL = 15
    }
}
