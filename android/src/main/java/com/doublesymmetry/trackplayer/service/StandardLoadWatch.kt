package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * The code a load that gives up reports, on both backends and both platforms (the crossfade
 * engines name it in their own errors).
 */
internal const val PREPARE_TIMEOUT_CODE = "crossfade_prepare_timeout"

/** What the standard player's load watch reads of the player, once per poll. */
internal data class StandardLoadObservation(
    /** The player's current item (compared by identity), null with none. */
    val item: Any?,
    /** ExoPlayer's own `Player.STATE_*`. */
    val playbackState: Int,
    val hasError: Boolean,
    /** Its progress: bytes downloaded, buffered position, total buffered duration. */
    val readings: LongArray,
    /**
     * Another wait owns the player's loading now (a seek): not watched, but whether the item was
     * ready is kept, so buffering once that wait ended is a rebuffer, not a load.
     */
    val ownedElsewhere: Boolean = false
)

/**
 * The stall rule for the standard player's loads, as the crossfade engines apply it to theirs:
 * a load gives up after `stallTimeoutMs` with no progress (no new bytes, no more media buffered),
 * or after `prepareTimeoutMs` in all, and is then stopped by the caller.
 *
 * Driven by the player's state, since no command waits for a standard load (load, skip and a
 * natural advance return or happen before the track loads): a load is the player buffering an
 * item that has not been ready since it was loaded (an item change, a prepare after a stop or an
 * error: a retry is a new load). It ends when the item is ready or ended, on a player error (the
 * player reports it), or with another item (a new load). Buffering again after ready (a seek,
 * which [StandardSeekGate] watches, or a rebuffer while playing) is not a load, as on the
 * crossfade path. Main thread.
 */
internal class StandardLoadWatch(
    private val stallTimeoutMs: () -> Long,
    private val totalTimeoutMs: () -> Long,
    private val nowMs: () -> Long = ::monotonicNowMs,
    /** A load of the item starts being watched (the progress counter's per-load reset: [LoadedBytes.startLoad]). */
    private val onLoadStart: (item: Any) -> Unit = {}
) {
    private var readyItem: Any? = null
    private var watchedItem: Any? = null
    private var watch: StallWatch? = null

    /** The limits of the last load watched (what a give-up reports). */
    var lastStallTimeoutMs = 0L
        private set
    var lastTotalTimeoutMs = 0L
        private set

    /** A load is being watched. */
    val isWatching: Boolean
        get() = watch != null

    /** Takes one observation: the verdict that ends a load the caller must give up, else null. */
    fun check(observed: StandardLoadObservation): StallVerdict? {
        val item = observed.item
        if (item == null || observed.hasError) {
            readyItem = null
            disarm()
            return null
        }
        if (observed.ownedElsewhere) {
            disarm()
            return null
        }
        when (observed.playbackState) {
            Player.STATE_READY, Player.STATE_ENDED -> {
                readyItem = item
                disarm()
                return null
            }
            Player.STATE_IDLE -> {
                // Stopped or not prepared: whatever loads next is a new load.
                readyItem = null
                disarm()
                return null
            }
        }
        // Buffering.
        if (readyItem === item) {
            disarm()
            return null
        }
        val current = watch?.takeIf { watchedItem === item }
            ?: StallWatch(stallTimeoutMs(), totalTimeoutMs(), nowMs()).also {
                watch = it
                watchedItem = item
                lastStallTimeoutMs = it.stallTimeoutMs
                lastTotalTimeoutMs = it.totalTimeoutMs
                onLoadStart(item)
            }
        val verdict = current.check(nowMs(), observed.readings)
        if (verdict == StallVerdict.WAIT) return null
        disarm()
        return verdict
    }

    /**
     * When to check next, in milliseconds from [nowMs], while a load is watched (null: none): at
     * the moment the load would give up if nothing progresses, and every
     * [standardLoadSampleIntervalMs] before it, to read the progress the player does not signal.
     */
    fun nextCheckInMs(): Long? {
        val current = watch ?: return null
        val untilDeadline = (current.deadlineMs() - nowMs()).coerceAtLeast(0L)
        return minOf(untilDeadline, standardLoadSampleIntervalMs(current.stallTimeoutMs))
    }

    /** Forgets the load in progress (the player is no longer this backend's to watch). */
    fun reset() {
        readyItem = null
        disarm()
    }

    private fun disarm() {
        watch = null
        watchedItem = null
    }
}

/**
 * How often a watched load's progress is read between events, from its stall timeout: a tenth of
 * it, so a give-up comes at most that late after the last progress. Same rule on iOS
 * (`standardLoadSampleIntervalMs`); no fixed interval.
 */
internal fun standardLoadSampleIntervalMs(stallTimeoutMs: Long): Long = (stallTimeoutMs / 10L).coerceAtLeast(1L)

/**
 * Runs a [StandardLoadWatch] on a player's thread ([handler]), driven by the player's events
 * ([poke]: [listenTo] wires ExoPlayer's), and, only while a load is watched, by one timer at the
 * watch's next check ([StandardLoadWatch.nextCheckInMs]). No load, no timer.
 */
internal class StandardLoadDriver(
    private val watch: StandardLoadWatch,
    private val handler: android.os.Handler,
    private val observe: () -> StandardLoadObservation,
    private val giveUp: (StallVerdict) -> Unit
) {
    private val check = Runnable { poke() }
    private var stopped = false

    /** A timer is set (a load is watched). */
    var isScheduled = false
        private set

    /** Checks now (an event, a command), then sets the timer while a load is watched. */
    fun poke() {
        handler.removeCallbacks(check)
        isScheduled = false
        if (stopped) return
        watch.check(observe())?.let(giveUp)
        if (stopped) return
        watch.nextCheckInMs()?.let {
            handler.postDelayed(check, it)
            isScheduled = true
        }
    }

    fun stop() {
        stopped = true
        handler.removeCallbacks(check)
        isScheduled = false
    }

    /** Checks at every event of the player [analytics] collects (state, item, error, loading). */
    fun listenTo(analytics: com.google.android.exoplayer2.analytics.DefaultAnalyticsCollector) {
        analytics.addListener(object : com.google.android.exoplayer2.analytics.AnalyticsListener {
            override fun onEvents(player: Player, events: com.google.android.exoplayer2.analytics.AnalyticsListener.Events) {
                poke()
            }
        })
    }
}

/**
 * The message of a standard load that gave up: the crossfade load's words without the engine
 * ("The track did not become ready (no progress for N ms)."), the same text on iOS.
 */
internal fun standardLoadGiveUpMessage(verdict: StallVerdict, stallTimeoutMs: Long, totalTimeoutMs: Long): String =
    "The track did not become ready (${stallVerdictReason(verdict, stallTimeoutMs, totalTimeoutMs)})."

/**
 * The bytes a player downloads that count as a load's progress, as on the crossfade path: media
 * (segments, a progressive file; [media]) always; HLS playlists and keys ([playlists]) only
 * until the track's first segment is asked for. Before that they are the load's only progress (a
 * slow proxy answering the playlists must not fail a healthy track); after it, the player reloads
 * them when it falls back to another rendition, which is not progress.
 *
 * Progress belongs to one load: [startLoad] names the item that loads, and each item's sources
 * report through that item's own listeners ([media], [playlists]: the player makes them when it
 * builds the item's source). A transfer of another item (the previous track's request still in
 * flight on a loader thread when the next one starts) is not this load's progress and does not
 * end its playlists' count.
 */
internal class LoadedBytes {
    private class Load(val item: Any) {
        val mediaRequested = AtomicBoolean(false)
    }

    private val count = AtomicLong(0L)
    private val current = AtomicReference<Load?>(null)

    val value: Long
        get() = count.get()

    /** A new load of [item]: its playlists are progress again until it asks for a segment. */
    fun startLoad(item: Any) {
        current.set(Load(item))
    }

    /** The load in progress, when it is [item]'s. */
    private fun loadOf(item: Any): Load? = current.get()?.takeIf { it.item === item }

    /** The listener of [item]'s media requests. */
    fun media(item: Any): TransferListener = object : TransferListener {
        override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
            loadOf(item)?.mediaRequested?.set(true)
        }
        override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
            if (loadOf(item) != null) count.addAndGet(bytesTransferred.toLong())
        }
        override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
    }

    /** The listener of [item]'s playlist and key requests. */
    fun playlists(item: Any): TransferListener = object : TransferListener {
        override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
            val load = loadOf(item) ?: return
            if (!load.mediaRequested.get()) count.addAndGet(bytesTransferred.toLong())
        }
        override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
    }
}

/** [factory]'s sources, each telling [listener] its bytes. */
internal fun DataSource.Factory.countingBytes(listener: TransferListener): DataSource.Factory = DataSource.Factory {
    createDataSource().also { it.addTransferListener(listener) }
}

/** What the load watch reads of ExoPlayer [player] with its [bytes] counter. */
internal fun standardLoadObservation(
    player: Player?,
    item: Any?,
    bytes: LoadedBytes?,
    ownedElsewhere: Boolean = false
): StandardLoadObservation =
    StandardLoadObservation(
        item = item,
        playbackState = player?.playbackState ?: Player.STATE_IDLE,
        hasError = player?.playerError != null,
        readings = longArrayOf(bytes?.value ?: 0L, player?.bufferedPosition ?: 0L, player?.totalBufferedDuration ?: 0L),
        ownedElsewhere = ownedElsewhere
    )
