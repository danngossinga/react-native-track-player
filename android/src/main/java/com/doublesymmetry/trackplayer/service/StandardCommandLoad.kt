package com.doublesymmetry.trackplayer.service

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

    /** [item]'s load failed: its wait ends rejected with [code]. Returns whether one waited. */
    fun failed(item: Any?, code: String, message: String): Boolean {
        val current = wait ?: return false
        if (current.target !== item) return false
        wait = null
        failureReportedByCommand = item
        current.settle(Outcome.Failed(code, message))
        return true
    }

    /** A newer command that loads or stops: the wait in progress ends cancelled. */
    fun cancel() {
        val current = wait ?: return
        wait = null
        current.settle(Outcome.Cancelled)
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

    /** The player is no longer in that error (a new load): its later errors are reported again. */
    fun failureCleared() {
        failureReportedByCommand = null
    }
}
