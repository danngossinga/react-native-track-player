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
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.DefaultBandwidthMeter
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.upstream.TransferListener
import kotlinx.coroutines.delay
import timber.log.Timber
import java.util.concurrent.atomic.AtomicLong
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
        // No defaults: every call passes the app's settings (prepareTimeoutMs, the total limit,
        // and stallTimeoutMs, how long the load may go on with no progress).
        timeoutMs: Long,
        stallTimeoutMs: Long,
        ticket: PlaybackOperationTicket? = null
    )
    fun play(rate: Float = 1f)
    fun pause()
    fun reset()
    fun release()
    suspend fun seekTo(
        positionMs: Long,
        timeoutMs: Long,
        stallTimeoutMs: Long,
        ticket: PlaybackOperationTicket? = null
    )
    fun setVolume(value: Float)
    fun setRate(value: Float)
}

internal class AndroidCrossfadeEngine(
    context: Context,
    override val name: String,
    audioContentType: Int,
    handleAudioFocus: Boolean,
    /**
     * The bandwidth each track starts from before the player has measured any
     * (`initialBitrateEstimateBps`), read at every load: adaptive streams start low (see
     * [crossfadeBandwidthMeter]), then follow the measured bandwidth.
     */
    initialBitrateEstimateBps: () -> Long,
    /**
     * The app's current `stallTimeoutMs`, read at every HTTP request: the connect and read
     * timeouts follow it (see [CurrentTimeoutHttpDataSourceFactory]).
     */
    stallTimeoutMs: () -> Long
) : AndroidCrossfadeEnginePort {
    private val bandwidthMeter = PerTrackBandwidthMeter(initialBitrateEstimateBps) { estimate ->
        crossfadeBandwidthMeter(context, estimate)
    }
    /** Bytes this player has downloaded: a load's progress, counted while a segment arrives. */
    private val bytesLoaded = AtomicLong(0L)
    private val httpDataSourceFactory = CurrentTimeoutHttpDataSourceFactory(stallTimeoutMs)
    private val dataSourceFactory = DefaultDataSource.Factory(context, httpDataSourceFactory)
        .setTransferListener(object : TransferListener {
            override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
            override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
            override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
                bytesLoaded.addAndGet(bytesTransferred.toLong())
            }
            override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        })
    private val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
    private var preparedItem: TrackAudioItem? = null
    private var preparedTrackKey: String? = null
    private var operationGeneration = 0L

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(mediaSourceFactory)
        .setBandwidthMeter(bandwidthMeter)
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


    /** What a wait reads as progress: bytes downloaded and media buffered. */
    private fun loadProgress(): LongArray =
        longArrayOf(bytesLoaded.get(), player.bufferedPosition, player.totalBufferedDuration)

    override suspend fun prepare(
        item: TrackAudioItem,
        positionMs: Long,
        timeoutMs: Long,
        stallTimeoutMs: Long,
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
        // Every track starts from the app's current estimate, not from the last track's measure.
        // A start-of-track estimate: a new value waits for the next track; the playing one keeps
        // following the measured bandwidth.
        val initialEstimate = bandwidthMeter.startTrack()
        androidXfadeLog("$name track start initialBitrateEstimateBps=$initialEstimate")
        player.setMediaItem(buildMediaItem(item))
        player.prepare()
        player.seekTo(max(0L, positionMs))
        preparedItem = item
        preparedTrackKey = trackKey

        // Fails when nothing loads for stallTimeoutMs, or after timeoutMs in all.
        val verdict = awaitWhileProgressing(
            stallTimeoutMs = stallTimeoutMs,
            totalTimeoutMs = timeoutMs,
            pollIntervalMs = ENGINE_WAIT_POLL_INTERVAL_MS,
            nowMs = SystemClock::elapsedRealtime,
            pause = { if (ticket == null) delay(it) else ticket.delayOrThrow(it) },
            readings = ::loadProgress
        ) {
            if (player.playbackState == Player.STATE_ENDED) {
                if (operationGeneration == generation) state = AndroidCrossfadeEngineState.ENDED
                throw RejectionException("$name ended before it was ready.", "crossfade_engine_ended")
            }
            if (player.playerError != null) {
                if (operationGeneration == generation) state = AndroidCrossfadeEngineState.FAILED
                throw RejectionException(player.playerError?.message ?: "$name failed to prepare.", "crossfade_engine_error")
            }
            player.playbackState == Player.STATE_READY
        }
        if (verdict != null) {
            if (operationGeneration == generation) state = AndroidCrossfadeEngineState.FAILED
            val reason = if (verdict == StallVerdict.STALLED) "no progress for ${stallTimeoutMs}ms" else "over the ${timeoutMs}ms limit"
            throw RejectionException("$name did not become ready ($reason).", "crossfade_prepare_timeout")
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
        stallTimeoutMs: Long,
        ticket: PlaybackOperationTicket?
    ) {
        val generation = operationGeneration
        ticket?.ensureActive()
        val target = max(0L, positionMs)
        androidXfadeLog("$name seek start positionMs=$target")
        player.seekTo(target)
        val verdict = awaitWhileProgressing(
            stallTimeoutMs = stallTimeoutMs,
            totalTimeoutMs = timeoutMs,
            pollIntervalMs = ENGINE_WAIT_POLL_INTERVAL_MS,
            nowMs = SystemClock::elapsedRealtime,
            pause = { if (ticket == null) delay(it) else ticket.delayOrThrow(it) },
            readings = ::loadProgress
        ) { player.playbackState != Player.STATE_BUFFERING }
        if (verdict != null) {
            // As on iOS: the player stops, so audio does not resume by itself when data arrives.
            player.playWhenReady = false
            player.pause()
            if (operationGeneration == generation) state = AndroidCrossfadeEngineState.FAILED
            val reason = if (verdict == StallVerdict.STALLED) "no progress for ${stallTimeoutMs}ms" else "over the ${timeoutMs}ms limit"
            throw RejectionException("$name did not finish seeking ($reason).", "crossfade_seek_timeout")
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
        httpDataSourceFactory.configure {
            setDefaultRequestProperties(options?.headers ?: emptyMap())
            options?.userAgent?.takeIf { it.isNotBlank() }?.let { setUserAgent(it) }
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

}

/** How often an engine's load or seek wait reads its progress (a poll interval, not a limit). */
internal const val ENGINE_WAIT_POLL_INTERVAL_MS = 25L

// Every wait for a track gives up when it makes no progress for `stallTimeoutMs`, or when it
// exceeds its own total limit below, a safety cap for slow but progressing loads.

/**
 * How long, in all, a crossfade engine may wait for a track to become ready
 * (`crossfade_prepare_timeout`), or for a seek to finish buffering (`crossfade_seek_timeout`),
 * unless the app sets `prepareTimeoutMs`.
 */
internal const val DEFAULT_PREPARE_TIMEOUT_MS = 60_000L

/** How long, in all, the standard backend waits for a restored track to be ready (`standardReadyTimeoutMs`). */
internal const val DEFAULT_STANDARD_READY_TIMEOUT_MS = 60_000L
internal const val STANDARD_READY_TIMEOUT_KEY = "standardReadyTimeoutMs"

/** How long any of those waits goes on with no progress before it fails (`stallTimeoutMs`). */
internal const val DEFAULT_STALL_TIMEOUT_MS = 10_000L
internal const val STALL_TIMEOUT_KEY = "stallTimeoutMs"

/**
 * The bandwidth, in bits per second, a crossfade player assumes before it has measured any
 * (`initialBitrateEstimateBps`, setupPlayer): low, so an adaptive stream starts at its lowest
 * rendition and climbs as the player measures the network.
 */
internal const val DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS = 96_000L

/**
 * How long a crossfade waits for the incoming track's position to move before it falls back to
 * playing that track alone (`incomingStallGraceMs`, `incoming_stalled`).
 */
internal const val DEFAULT_INCOMING_STALL_GRACE_MS = 2_000L
internal const val INCOMING_STALL_GRACE_KEY = "incomingStallGraceMs"

/**
 * The bandwidth meter of a crossfade player: it reports [initialBitrateEstimateBps] until it has
 * measured the network. ExoPlayer's adaptive selection then picks the highest rendition whose
 * bitrate fits about 70 % of the estimate (its default bandwidth fraction), or the lowest when
 * none fits.
 */
internal fun crossfadeBandwidthMeter(context: Context, initialBitrateEstimateBps: Long): DefaultBandwidthMeter =
    DefaultBandwidthMeter.Builder(context)
        .setInitialBitrateEstimate(initialBitrateEstimateBps)
        .build()
internal const val INITIAL_BITRATE_ESTIMATE_KEY = "initialBitrateEstimateBps"

/**
 * A timeout option (`prepareTimeoutMs`, `standardReadyTimeoutMs`), in milliseconds, read from setup
 * or update options: null when it is absent or not a number from 1 to 2147483646, so the current
 * value is kept.
 */
internal fun timeoutOptionFrom(value: Any?): Long? {
    val ms = (value as? Number)?.toDouble() ?: return null
    // Same bounds as iOS: 1 ms to 2^31 - 2 ms.
    if (!ms.isFinite() || ms < 1.0 || ms >= Int.MAX_VALUE.toDouble()) return null
    return ms.toLong()
}

internal const val PREPARE_TIMEOUT_KEY = "prepareTimeoutMs"

/**
 * A whole-number option from 1 to 2147483646 (setup or update options): one value, kept until a
 * valid new one comes. Written on the main thread; read there and by the players' loading threads
 * (HTTP timeouts), so it is volatile.
 */
internal open class WholeNumberSetting(defaultValue: Long) {
    @Volatile
    var value: Long = defaultValue
        private set

    /**
     * Takes a valid value (the option's raw value). Returns false when the value is ignored and
     * the current one kept.
     */
    fun apply(raw: Any?): Boolean {
        value = timeoutOptionFrom(raw) ?: return false
        return true
    }
}

/** One of the app's timeouts, in milliseconds. */
internal class TimeoutSetting(defaultMs: Long) : WholeNumberSetting(defaultMs) {
    val milliseconds: Long
        get() = value
}

/** A bandwidth in bits per second (`initialBitrateEstimateBps`). */
internal class BitrateSetting(defaultBps: Long) : WholeNumberSetting(defaultBps) {
    val bitsPerSecond: Long
        get() = value
}
