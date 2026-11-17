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
    /**
     * Its progress: bytes downloaded, buffered position, total buffered duration; null while the
     * load has no progress signal. ExoPlayer's load always has one (its playlist bytes count until
     * the first segment is asked for, [LoadedBytes]): [standardLoadObservation] never sends null.
     * Kept for the same moves as iOS's watch, whose player has no item (no signal) before the
     * asset is playable.
     */
    val readings: LongArray?,
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
    /** A load starts being watched (the progress counter's per-load reset: [StandardPlayerAnalytics.startLoad]). */
    private val onLoadStart: () -> Unit = {}
) {
    /**
     * A load in progress: its [item], when it began (the first time the item was seen loading,
     * even while a seek owned it), whether its progress counter was started ([onLoadStart]; once
     * per load) and its stall [watch] while it is watched (null while a seek owns it: once the
     * seek ends, the load is watched again with its own total limit and a fresh stall clock).
     */
    data class Load(
        val item: Any,
        val startedAtMs: Long,
        val progressStarted: Boolean = false,
        val watch: Watch? = null
    )

    /**
     * A watched load's stage (iOS: `StandardLoadWatch.Watch`, the same moves):
     * - [Playable]: no progress signal (null readings): only the total limit ends it.
     * - [Item]: readings arrived: the stall rule, its clock restarted when they first came.
     * Moves: watched -> Playable or Item (by its first readings); Playable -readings-> Item
     * (progress noted); Item -null readings-> Playable. ExoPlayer's loads are always [Item].
     */
    sealed class Watch {
        abstract val stall: StallWatch
        data class Playable(override val stall: StallWatch) : Watch()
        data class Item(override val stall: StallWatch) : Watch()
    }

    /**
     * Where the watch stands (one explicit state, the monorepo's state-machine form 3: a closed
     * union moved only by [check] and [reset]; iOS: `StandardLoadWatch.State`, same moves).
     *
     * - [Idle]: no load. [Idle.ready] is the item ready since it was loaded (null: none): its
     *   buffering is a rebuffer, not a load.
     * - [Loading]: [Loading.load]'s item loads (never [Loading.ready], which a return to it would
     *   find ready).
     *
     * Moves: no item or an error -> Idle(null); owned elsewhere -> the load (if any) disarmed, and
     * an item buffering not ready since its load -> Loading (the same load, else a new one from
     * now); ready or ended -> Idle(item); idle -> Idle(null); buffering the ready item ->
     * Idle(ready); buffering another -> Loading (its load, watched; a new one for a new item), and
     * a verdict other than wait -> Idle(ready); reset -> Idle(null).
     */
    sealed class State {
        abstract val ready: Any?
        data class Idle(override val ready: Any?) : State()
        data class Loading(override val ready: Any?, val load: Load) : State()
    }

    var state: State = State.Idle(null)
        private set

    /** The limits of the last load watched (what a give-up reports). */
    var lastStallTimeoutMs = 0L
        private set
    var lastTotalTimeoutMs = 0L
        private set

    private val load: Load?
        get() = (state as? State.Loading)?.load

    /** A load is being watched. */
    val isWatching: Boolean
        get() = load?.watch != null

    /** Takes one observation: the verdict that ends a load the caller must give up, else null. */
    fun check(observed: StandardLoadObservation): StallVerdict? {
        val item = observed.item
        if (item == null || observed.hasError) {
            state = State.Idle(null)
            return null
        }
        val ready = state.ready
        if (observed.ownedElsewhere) {
            // A seek on an item not ready since it was loaded: its load goes on (and its total).
            if (observed.playbackState == Player.STATE_BUFFERING && ready !== item) {
                state = State.Loading(ready, loadOf(item).copy(watch = null))
            } else {
                load?.let { state = State.Loading(ready, it.copy(watch = null)) }
            }
            return null
        }
        when (observed.playbackState) {
            Player.STATE_READY, Player.STATE_ENDED -> {
                state = State.Idle(item)
                return null
            }
            Player.STATE_IDLE -> {
                // Stopped or not prepared: whatever loads next is a new load.
                state = State.Idle(null)
                return null
            }
        }
        // Buffering.
        if (ready === item) {
            state = State.Idle(ready)
            return null
        }
        var current = loadOf(item)
        if (current.watch == null) {
            val created = StallWatch(stallTimeoutMs(), totalTimeoutMs(), startedAtMs = current.startedAtMs, lastProgressAtMs = nowMs())
            lastStallTimeoutMs = created.stallTimeoutMs
            lastTotalTimeoutMs = created.totalTimeoutMs
            val starts = !current.progressStarted
            current = current.copy(progressStarted = true, watch = Watch.Playable(created))
            state = State.Loading(ready, current)
            if (starts) onLoadStart()
        }
        val at = nowMs()
        val watch = current.watch!!
        val readings = observed.readings
        val verdict = when {
            // No progress signal: only the total limit.
            readings == null -> {
                current = current.copy(watch = Watch.Playable(watch.stall))
                watch.stall.capVerdict(at)
            }
            watch is Watch.Playable -> {
                // The signal appeared: a stage reached, the stall clock starts again from it.
                watch.stall.noteProgress(at)
                current = current.copy(watch = Watch.Item(watch.stall))
                watch.stall.check(at, readings)
            }
            else -> watch.stall.check(at, readings)
        }
        if (verdict == StallVerdict.WAIT) {
            state = State.Loading(ready, current)
            return null
        }
        state = State.Idle(ready)
        return verdict
    }

    /** [item] is loading: the load in progress, or a new one from now. */
    private fun loadOf(item: Any): Load = load?.takeIf { it.item === item } ?: Load(item, nowMs())

    /**
     * When to check next, in milliseconds from [nowMs], while a load is watched (null: none): at
     * the moment the load would give up if nothing progresses, and every
     * [standardLoadSampleIntervalMs] before it, to read the progress the player does not signal.
     */
    fun nextCheckInMs(): Long? {
        val current = load?.watch ?: return null
        // No progress signal: only the total limit ends it (the stall deadline would set a timer
        // at 0 ms in a loop).
        val deadline = if (current is Watch.Playable) current.stall.capDeadlineMs() else current.stall.deadlineMs()
        val untilDeadline = (deadline - nowMs()).coerceAtLeast(0L)
        return minOf(untilDeadline, standardLoadSampleIntervalMs(current.stall.stallTimeoutMs))
    }

    /** Forgets the load in progress (the player is no longer this backend's to watch). */
    fun reset() {
        state = State.Idle(null)
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
 * Progress belongs to one load: [startLoad] names the item that loads (ExoPlayer's MediaItem of
 * the source it loads), and each source reports through its own item's listeners ([media],
 * [playlists]: the player makes them when it builds the source). A transfer of another item (the
 * previous track's request still in flight on a loader thread when the next one starts) is not
 * this load's progress and does not end its playlists' count. ExoPlayer's item, not KotlinAudio's
 * AudioItem: new metadata for a track (replaceItem) gives KotlinAudio's queue a new AudioItem
 * while ExoPlayer keeps loading the source built for the first one.
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
