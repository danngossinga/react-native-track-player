package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.delay

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
    val readings: LongArray
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
    private val nowMs: () -> Long = ::monotonicNowMs
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
            }
        val verdict = current.check(nowMs(), observed.readings)
        if (verdict == StallVerdict.WAIT) return null
        disarm()
        return verdict
    }

    /** Forgets the load in progress (another owner waits for it: a seek, a backend switch). */
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
 * Runs [watch] on the player for as long as the calling coroutine (the player's owner, on the main
 * thread) is active: every poll it reads [observe] and, when a load gives up, calls [giveUp] (which
 * stops the player and reports the error).
 */
internal suspend fun StandardLoadWatch.supervise(
    observe: () -> StandardLoadObservation,
    giveUp: (StallVerdict) -> Unit,
    pollIntervalMs: Long = ENGINE_WAIT_POLL_INTERVAL_MS
) {
    while (true) {
        check(observe())?.let(giveUp)
        delay(pollIntervalMs)
    }
}

/**
 * The message of a standard load that gave up: the crossfade load's words without the engine
 * ("The track did not become ready (no progress for N ms)."), the same text on iOS.
 */
internal fun standardLoadGiveUpMessage(verdict: StallVerdict, stallTimeoutMs: Long, totalTimeoutMs: Long): String =
    "The track did not become ready (${stallVerdictReason(verdict, stallTimeoutMs, totalTimeoutMs)})."

/** Counts the bytes a player downloads (a load's progress), from every request it opens. */
internal class LoadedBytes : TransferListener {
    private val count = AtomicLong(0L)

    val value: Long
        get() = count.get()

    override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
    override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
    override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
        count.addAndGet(bytesTransferred.toLong())
    }
    override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
}

/** [factory]'s sources, each counting its bytes into [bytes]. */
internal fun DataSource.Factory.countingBytes(bytes: LoadedBytes): DataSource.Factory = DataSource.Factory {
    createDataSource().also { it.addTransferListener(bytes) }
}

/** What the load watch reads of ExoPlayer [player] with its [bytes] counter. */
internal fun standardLoadObservation(player: Player?, item: Any?, bytes: LoadedBytes?): StandardLoadObservation =
    StandardLoadObservation(
        item = item,
        playbackState = player?.playbackState ?: Player.STATE_IDLE,
        hasError = player?.playerError != null,
        readings = longArrayOf(bytes?.value ?: 0L, player?.bufferedPosition ?: 0L, player?.totalBufferedDuration ?: 0L)
    )
