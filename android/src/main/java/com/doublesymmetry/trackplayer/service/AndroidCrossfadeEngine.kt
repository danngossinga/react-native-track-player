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
    val timestamp = runCatching { SystemClock.elapsedRealtimeNanos() }
        .getOrElse { System.nanoTime() }
    val formatted = "[XF-ORCH][$timestamp] $message"
    runCatching { Log.i("RNTP-Crossfade", formatted) }
    runCatching { Timber.tag("RNTP-Crossfade").d(formatted) }
}

internal interface AndroidCrossfadeEnginePort {
    val name: String
    val positionMs: Long
    val durationMs: Long
    val bufferedMs: Long
    val isReady: Boolean
    val playbackState: Int
    val currentVolume: Float
    val playerErrorMessage: String?

    fun isPreparedFor(item: TrackAudioItem): Boolean
    suspend fun prepare(
        item: TrackAudioItem,
        positionMs: Long = 0L,
        timeoutMs: Long = 5000L,
        ticket: PlaybackOperationTicket? = null
    )
    fun play(rate: Float = 1f)
    fun pause()
    fun reset()
    fun release()
    suspend fun seekTo(
        positionMs: Long,
        timeoutMs: Long = 5000L,
        ticket: PlaybackOperationTicket? = null
    )
    fun setVolume(value: Float)
    fun setRate(value: Float)
}

internal class AndroidCrossfadeEngine(
    context: Context,
    override val name: String,
    audioContentType: Int,
    handleAudioFocus: Boolean
) : AndroidCrossfadeEnginePort {
    private val httpDataSourceFactory = DefaultHttpDataSource.Factory()
    private val dataSourceFactory = DefaultDataSource.Factory(context, httpDataSourceFactory)
    private val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
    private var preparedItem: TrackAudioItem? = null
    private var preparedTrackKey: String? = null
    private var operationGeneration = 0L

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

    override fun isPreparedFor(item: TrackAudioItem): Boolean = preparedTrackKey == trackKeyFor(item)

    override val positionMs: Long
        get() = max(0L, player.currentPosition)

    override val durationMs: Long
        get() = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L

    override val bufferedMs: Long
        get() = max(positionMs, player.bufferedPosition)

    override val isReady: Boolean
        get() = player.playbackState == Player.STATE_READY

    override val playbackState: Int
        get() = player.playbackState

    override val currentVolume: Float
        get() = player.volume

    override val playerErrorMessage: String?
        get() = player.playerError?.message

    override suspend fun prepare(
        item: TrackAudioItem,
        positionMs: Long,
        timeoutMs: Long,
        ticket: PlaybackOperationTicket?
    ) {
        operationGeneration += 1
        val generation = operationGeneration
        ticket?.ensureActive()
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
                if (operationGeneration == generation) state = AndroidCrossfadeEngineState.ENDED
                throw RejectionException("$name ended before it was ready.", "crossfade_engine_ended")
            }
            if (player.playerError != null) {
                if (operationGeneration == generation) state = AndroidCrossfadeEngineState.FAILED
                throw RejectionException(player.playerError?.message ?: "$name failed to prepare.", "crossfade_engine_error")
            }
            if (SystemClock.elapsedRealtime() - startedAt > timeoutMs) {
                if (operationGeneration == generation) state = AndroidCrossfadeEngineState.FAILED
                throw RejectionException("$name did not become ready.", "crossfade_prepare_timeout")
            }
            if (ticket == null) delay(25) else ticket.delayOrThrow(25)
        }

        ticket?.ensureActive()
        if (operationGeneration != generation) {
            throw PlaybackOperationCancelledException("engine_reset")
        }
        state = AndroidCrossfadeEngineState.READY
        androidXfadeLog("$name prepare end ready=true durationMs=$durationMs bufferedMs=$bufferedMs")
    }

    override fun play(rate: Float) {
        androidXfadeLog("$name play positionMs=$positionMs volume=${player.volume} rate=$rate")
        player.setPlaybackSpeed(max(0.1f, rate))
        player.playWhenReady = true
        player.play()
        state = AndroidCrossfadeEngineState.PLAYING
    }

    override fun pause() {
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

    override fun reset() {
        operationGeneration += 1
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

    override fun release() {
        operationGeneration += 1
        androidXfadeLog("$name release")
        player.release()
        preparedItem = null
        preparedTrackKey = null
        state = AndroidCrossfadeEngineState.IDLE
    }

    override suspend fun seekTo(
        positionMs: Long,
        timeoutMs: Long,
        ticket: PlaybackOperationTicket?
    ) {
        val generation = operationGeneration
        ticket?.ensureActive()
        val target = max(0L, positionMs)
        androidXfadeLog("$name seek start positionMs=$target")
        player.seekTo(target)
        val startedAt = SystemClock.elapsedRealtime()
        while (player.playbackState == Player.STATE_BUFFERING) {
            if (SystemClock.elapsedRealtime() - startedAt > timeoutMs) {
                throw RejectionException("$name did not finish seeking.", "crossfade_seek_timeout")
            }
            if (ticket == null) delay(25) else ticket.delayOrThrow(25)
        }
        ticket?.ensureActive()
        if (operationGeneration != generation) {
            throw PlaybackOperationCancelledException("engine_reset")
        }
        androidXfadeLog("$name seek end positionMs=${this.positionMs} state=${player.playbackState}")
    }

    override fun setVolume(value: Float) {
        player.volume = value
    }

    override fun setRate(value: Float) {
        player.setPlaybackSpeed(max(0.1f, value))
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
