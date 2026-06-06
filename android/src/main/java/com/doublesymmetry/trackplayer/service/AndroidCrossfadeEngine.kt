package com.doublesymmetry.trackplayer.service

import android.content.Context
import android.net.Uri
import android.util.Log
import android.os.SystemClock
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.utils.RejectionException
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.MediaMetadata
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.audio.AudioAttributes
import com.google.android.exoplayer2.source.DefaultMediaSourceFactory
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import kotlinx.coroutines.delay
import timber.log.Timber
import kotlin.math.max

internal enum class AndroidCrossfadeEngineState {
    IDLE,
    LOADING,
    READY,
    PLAYING,
    PAUSED,
    ENDED,
    FAILED
}

internal fun androidXfadeLog(message: String) {
    val formatted = "[XF-ORCH][${SystemClock.elapsedRealtimeNanos()}] $message"
    Log.i("RNTP-Crossfade", formatted)
    Timber.tag("RNTP-Crossfade").d(formatted)
}

internal class AndroidCrossfadeEngine(
    context: Context,
    val name: String,
    audioContentType: Int,
    handleAudioFocus: Boolean
) {
    private val httpDataSourceFactory = DefaultHttpDataSource.Factory()
    private val dataSourceFactory = DefaultDataSource.Factory(context, httpDataSourceFactory)
    private val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
    private var preparedItem: TrackAudioItem? = null
    private var preparedTrackKey: String? = null

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(mediaSourceFactory)
        .build()
        .apply {
            volume = 0f
            playWhenReady = false
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(audioContentType)
                    .build(),
                handleAudioFocus
            )
        }

    var state: AndroidCrossfadeEngineState = AndroidCrossfadeEngineState.IDLE
        private set

    val preparedQueueId: Long?
        get() = preparedItem?.track?.queueId

    fun isPreparedFor(item: TrackAudioItem): Boolean = preparedTrackKey == trackKeyFor(item)

    val positionMs: Long
        get() = max(0L, player.currentPosition)

    val durationMs: Long
        get() = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L

    val bufferedMs: Long
        get() = max(positionMs, player.bufferedPosition)

    val isReady: Boolean
        get() = player.playbackState == Player.STATE_READY

    val playbackState: Int
        get() = player.playbackState

    suspend fun prepare(item: TrackAudioItem, positionMs: Long = 0L, timeoutMs: Long = PREPARE_TIMEOUT_MS) {
        val trackKey = trackKeyFor(item)
        androidXfadeLog("$name prepare start trackKey=$trackKey positionMs=$positionMs")
        state = AndroidCrossfadeEngineState.LOADING
        configureRequestOptions(item)
        player.playWhenReady = false
        player.pause()
        player.stop()
        player.clearMediaItems()
        player.setMediaItem(buildMediaItem(item))
        player.prepare()
        player.seekTo(max(0L, positionMs))
        preparedItem = item
        preparedTrackKey = trackKey

        val startedAt = SystemClock.elapsedRealtime()
        while (player.playbackState != Player.STATE_READY) {
            if (player.playbackState == Player.STATE_ENDED) {
                state = AndroidCrossfadeEngineState.ENDED
                throw RejectionException("$name ended before it was ready.", "crossfade_engine_ended")
            }
            if (player.playerError != null) {
                state = AndroidCrossfadeEngineState.FAILED
                throw RejectionException(player.playerError?.message ?: "$name failed to prepare.", "crossfade_engine_error")
            }
            if (SystemClock.elapsedRealtime() - startedAt > timeoutMs) {
                state = AndroidCrossfadeEngineState.FAILED
                throw RejectionException("$name did not become ready.", "crossfade_prepare_timeout")
            }
            delay(25)
        }

        state = AndroidCrossfadeEngineState.READY
        androidXfadeLog("$name prepare end ready=true durationMs=$durationMs bufferedMs=$bufferedMs")
    }

    fun play(rate: Float = 1f) {
        androidXfadeLog("$name play positionMs=$positionMs volume=${player.volume} rate=$rate")
        player.setPlaybackSpeed(max(0.1f, rate))
        player.playWhenReady = true
        player.play()
        state = AndroidCrossfadeEngineState.PLAYING
    }

    fun pause() {
        androidXfadeLog("$name pause positionMs=$positionMs")
        player.playWhenReady = false
        player.pause()
        state = AndroidCrossfadeEngineState.PAUSED
    }

    fun stop() {
        androidXfadeLog("$name stop positionMs=$positionMs")
        player.playWhenReady = false
        player.pause()
        player.stop()
        state = AndroidCrossfadeEngineState.IDLE
    }

    fun reset() {
        androidXfadeLog("$name reset")
        player.playWhenReady = false
        player.pause()
        player.stop()
        player.clearMediaItems()
        player.volume = 0f
        preparedItem = null
        preparedTrackKey = null
        state = AndroidCrossfadeEngineState.IDLE
    }

    fun release() {
        androidXfadeLog("$name release")
        player.release()
        preparedItem = null
        preparedTrackKey = null
        state = AndroidCrossfadeEngineState.IDLE
    }

    suspend fun seekTo(positionMs: Long, timeoutMs: Long = PREPARE_TIMEOUT_MS) {
        val target = max(0L, positionMs)
        androidXfadeLog("$name seek start positionMs=$target")
        player.seekTo(target)
        val startedAt = SystemClock.elapsedRealtime()
        while (player.playbackState == Player.STATE_BUFFERING) {
            if (SystemClock.elapsedRealtime() - startedAt > timeoutMs) {
                throw RejectionException("$name did not finish seeking.", "crossfade_seek_timeout")
            }
            delay(25)
        }
        androidXfadeLog("$name seek end positionMs=${this.positionMs} state=${player.playbackState}")
    }

    fun setVolume(value: Float) {
        player.volume = value
    }

    private fun configureRequestOptions(item: TrackAudioItem) {
        val options = item.options
        httpDataSourceFactory.setDefaultRequestProperties(options?.headers ?: emptyMap())
        options?.userAgent?.takeIf { it.isNotBlank() }?.let {
            httpDataSourceFactory.setUserAgent(it)
        }
    }

    private fun buildMediaItem(item: TrackAudioItem): MediaItem {
        val metadataBuilder = MediaMetadata.Builder()
            .setTitle(item.title)
            .setArtist(item.artist)
            .setAlbumTitle(item.albumTitle)
        item.artwork?.takeIf { it.isNotBlank() && it != "null" }?.let {
            metadataBuilder.setArtworkUri(Uri.parse(it))
        }
        return MediaItem.Builder()
            .setUri(Uri.parse(item.audioUrl))
            .setMediaMetadata(metadataBuilder.build())
            .build()
    }

    private fun trackKeyFor(item: TrackAudioItem): String {
        return item.track.originalItem?.getString("id")?.takeIf { it.isNotBlank() }
            ?: item.audioUrl
    }

    private companion object {
        const val PREPARE_TIMEOUT_MS = 5000L
    }
}
