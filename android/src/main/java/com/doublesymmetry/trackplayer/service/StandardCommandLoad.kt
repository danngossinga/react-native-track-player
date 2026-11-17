package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.Player

/** The message of a standard command's wait that a newer command ended (iOS: the same). */
internal const val STANDARD_COMMAND_LOAD_CANCELLED_MESSAGE = "A newer command replaced this one before its track loaded."

/**
 * The code a standard command rejects with when the player fails its track's load, as a
 * crossfade load whose engine fails (both platforms).
 */
internal const val STANDARD_LOAD_ERROR_CODE = "crossfade_engine_error"

/** The message of a standard load that failed with no message of its own (iOS: the same). */
internal const val STANDARD_LOAD_FAILED_MESSAGE = "The track failed to load."

/**
 * The standard player's commands that load a track (skip, next, previous, load) end as the
 * crossfade path's do: once the track loaded and is the active one ([FailedLoadRule]), or with
 * the load's failure, rejected with its code (a give-up: `crossfade_prepare_timeout`; a player
 * error: `crossfade_engine_error`). A newer command that loads or stops ends the older wait with
 * `cancelled`. A failure a command waits for is reported by its rejection only, not also as a
 * playback error (a load no command waits for, a natural advance, reports a playback error).
 * Same rule on iOS (`StandardCommandLoad` in PlaybackBackend.swift). Items are compared by
 * identity. Main thread.
 */
internal class StandardCommandLoad {
    sealed class Outcome {
        object Loaded : Outcome()
        data class Failed(val code: String, val message: String) : Outcome()
        object Cancelled : Outcome()
    }

    /** One command's wait for [target]'s load. */
    class Wait internal constructor(val target: Any, internal val settle: (Outcome) -> Unit)

    private var wait: Wait? = null
    /** The item whose failure a command's rejection reported (no playback error for it). */
    private var failureReportedByCommand: Any? = null

    /** A command waits for a load. */
    val isWaiting: Boolean
        get() = wait != null

    /**
     * A command waits for [target]'s load: settled at once when [target] is already the loaded
     * track the app was told of ([FailedLoadRule]'s [active] and [reported]), else by
     * [ruleSettled], [failed] or [cancel]. An older wait ends cancelled. Returns the wait, null
     * when settled at once.
     */
    fun begin(target: Any, active: Any?, reported: Any?, settle: (Outcome) -> Unit): Wait? {
        cancel()
        failureReportedByCommand = null
        if (active === target && reported === target) {
            settle(Outcome.Loaded)
            return null
        }
        return Wait(target, settle).also { wait = it }
    }

    /**
     * [FailedLoadRule] after a ready item: the wait for the track that loaded ends once it is the
     * active track and the app was told of it (a new queue's first track was reported at its
     * selection: it ends at its load all the same).
     */
    fun ruleSettled(active: Any?, reported: Any?) {
        val current = wait ?: return
        if (active == null || active !== reported || current.target !== active) return
        wait = null
        current.settle(Outcome.Loaded)
    }

    /** Whether a command waits for [item]'s load (its failure is then that command's to report). */
    fun waitsFor(item: Any?): Boolean = item != null && wait?.target === item

    /**
     * [item]'s load failed: its wait ends rejected with [code]. [reportedByPlayer]: the player
     * also sends this failure as its own error event (a player error, not a give-up, whose report
     * the backend decides at once), which the rejection replaces. Returns whether one waited.
     */
    fun failed(item: Any?, code: String, message: String, reportedByPlayer: Boolean): Boolean {
        val current = wait ?: return false
        if (current.target !== item) return false
        wait = null
        if (reportedByPlayer) failureReportedByCommand = item
        current.settle(Outcome.Failed(code, message))
        return true
    }

    /**
     * A newer command that loads, seeks, pauses or stops: the wait in progress ends cancelled.
     * Returns whether one was waiting ([standardCancelledLoad]).
     */
    fun cancel(): Boolean {
        val current = wait ?: return false
        wait = null
        current.settle(Outcome.Cancelled)
        return true
    }

    /** [abandoned] is no longer awaited (its caller went away): dropped without a result. */
    fun drop(abandoned: Wait) {
        if (wait === abandoned) wait = null
    }

    /**
     * Whether the player's error on [item] is a command's to report (by its rejection): one
     * waits for its load, or rejected with its failure.
     */
    fun reportsFailureOf(item: Any?): Boolean =
        item != null && (wait?.target === item || failureReportedByCommand === item)

    /**
     * The player is no longer in that error, or a command loads again (play, retry): its later
     * errors are reported again.
     */
    fun failureCleared() {
        failureReportedByCommand = null
    }
}

/**
 * Where a seek, pause or stop leaves the player when it cancelled a command's wait
 * ([StandardCommandLoad.cancel] returned true: a skip, next, previous or load whose track was
 * still loading), as crossfade's operation cancelled while it loads: the cancelled command does
 * not take effect, and its track is never reported. iOS: the same rule (`standardCancelledLoad`).
 */
internal sealed class StandardCancelledLoad {
    /** No wait cancelled (after a failed load too: LOAD-06, a command acts on the player's own track), or the player is on the reported track: it stays. */
    object Stays : StandardCancelledLoad()

    /** The player goes back to the reported track [item], paused (the seek acts there). */
    class ReturnsTo(val item: Any) : StandardCancelledLoad()

    /**
     * No track is reported (the first load failed, or the reported one left the queue): the
     * cancelled load stops and the player has no active track (logical idle, as crossfade's
     * active index -1): nothing loads or is reported until a play, skip or load selects a track
     * again (a play from idle starts the first track, as crossfade's).
     */
    object StopsInIdle : StandardCancelledLoad()
}

/** What a cancel leaves ([StandardCancelledLoad]); [reported]: the track the app was told is active. */
internal fun standardCancelledLoad(cancelledWait: Boolean, playerItem: Any?, reported: Any?): StandardCancelledLoad = when {
    !cancelledWait -> StandardCancelledLoad.Stays
    reported == null -> StandardCancelledLoad.StopsInIdle
    reported === playerItem -> StandardCancelledLoad.Stays
    else -> StandardCancelledLoad.ReturnsTo(reported)
}

/**
 * Whether a command's wait must start its track's load: the track is not the loaded one and the
 * player is not loading (stopped by a give-up, or failed: [Player.STATE_IDLE]). Else nothing would
 * end the wait. iOS: the same rule (`standardCommandLoadMustStart`).
 */
internal fun standardCommandLoadMustStart(targetLoaded: Boolean, exoState: Int): Boolean =
    !targetLoaded && exoState == Player.STATE_IDLE
