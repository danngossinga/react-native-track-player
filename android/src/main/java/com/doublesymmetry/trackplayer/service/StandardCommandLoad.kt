package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
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
 * Where a seek, pause or stop leaves the player when a load is pending, as crossfade's operation
 * cancelled while it loads: the cancelled command does not take effect, and its track is never
 * reported. A seek or stop ([actsOnReportedTrack]) acts on the reported track whenever the player
 * is on another one (a skip or load waiting, a natural advance loading, a skip that failed: owner
 * decision, 2026-11-17, LOAD-06); a pause only when it cancelled a command's wait
 * ([StandardCommandLoad.cancel] returned true: a skip, next, previous or load whose track was still
 * loading). iOS: the same rule (`standardCancelledLoad`).
 */
internal sealed class StandardCancelledLoad {
    /** Nothing pending, or the player is on the reported track (none reported: a seek retries the failed track): it stays. */
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

/**
 * What a seek, pause or stop leaves ([StandardCancelledLoad]); [cancelledWait]: it cancelled a
 * command's wait; [reported]: the track the app was told is active; [actsOnReportedTrack]: a seek
 * or stop (owner decision, 2026-11-17), not a pause.
 */
internal fun standardCancelledLoad(
    cancelledWait: Boolean,
    playerItem: Any?,
    reported: Any?,
    actsOnReportedTrack: Boolean = false
): StandardCancelledLoad = when {
    reported == null -> if (cancelledWait) StandardCancelledLoad.StopsInIdle else StandardCancelledLoad.Stays
    reported === playerItem -> StandardCancelledLoad.Stays
    cancelledWait || actsOnReportedTrack -> StandardCancelledLoad.ReturnsTo(reported)
    else -> StandardCancelledLoad.Stays
}

/**
 * Whether a command's wait must start its track's load: the track is not the loaded one and the
 * player is not loading (stopped by a give-up, or failed: [Player.STATE_IDLE]). Else nothing would
 * end the wait. iOS: the same rule (`standardCommandLoadMustStart`).
 */
internal fun standardCommandLoadMustStart(targetLoaded: Boolean, exoState: Int): Boolean =
    !targetLoaded && exoState == Player.STATE_IDLE

/**
 * The module's play request after a load failed, and whether a seek holds the player paused: one
 * explicit state (rule 12, ADR 0042 form 3), moved only by its events; the same states, events and
 * moves as iOS's `StandardSeekResume` (PlaybackBackend.swift). The reference is crossfade's: its
 * failure keeps playWhenReady until a pause or stop, and its seek after a failed skip plays.
 *
 * - [Kind.NONE]: no request kept; the player's own play-when-ready is the request.
 * - [Kind.KEPT_AFTER_FAILURE]: a failure (a give-up, whose stop ends the player's own
 *   play-when-ready, or a resuming seek that failed) stopped the player while playback was
 *   requested: the request stays (the app reads play-when-ready true), a seek then plays, and the
 *   next command that loads a track (play, retry, skip, next, previous, load, a new queue) plays.
 * - [Kind.RESUMES_AFTER_SEEK]: a seek holds the player paused after a failure, playback requested:
 *   the player waits paused and plays once the latest seek completed (any number of seeks in a
 *   row: a scrubber drag). The app reads play-when-ready true and, as crossfade's seek, LOADING.
 *
 * A pause or stop (a clear is crossfade's stop) ends it; a seek that cancelled a command's wait
 * (crossfade's cancelled operation) or a natural advance stays paused.
 */
internal class StandardSeekResume {
    enum class Kind { NONE, KEPT_AFTER_FAILURE, RESUMES_AFTER_SEEK }

    var kind: Kind = Kind.NONE
        private set

    /** The latest seek's token ([seekBegan]): only its end resumes. */
    private var latestSeek = 0L

    /** A failure kept the module's play request: the app reads play-when-ready true. */
    val requestsPlay: Boolean
        get() = requestsPlay(kind)

    /** The state the app reads for the player's [physical] one ([reportedState] in [kind]). */
    fun reportedState(physical: AudioPlayerState): AudioPlayerState = reportedState(kind, physical)

    /** A load or seek gave up while the player's own request was [playing] (or a failure kept it). */
    fun gaveUp(playing: Boolean) {
        kind = if (playing || requestsPlay) Kind.KEPT_AFTER_FAILURE else Kind.NONE
    }

    /** A pause or stop ends any request to resume. */
    fun paused() {
        kind = Kind.NONE
    }

    /**
     * A command that loads a track (play, retry, skip, next, previous, load, a new queue) takes the
     * request over: returns whether a failure kept it (the command then plays, as crossfade's skip
     * with playWhenReady kept); nothing is kept any more (the player's own request is the request).
     */
    fun handedToPlayer(): Boolean {
        val kept = requestsPlay
        kind = Kind.NONE
        return kept
    }

    /**
     * A seek began. [returnsToActiveTrack]: it moved the player back to the active track;
     * [afterFailedLoad]: the player's track had failed to load (not a natural advance, not a
     * command's wait); [cancelledWait]: it cancelled a command's wait; [playerPlaying]: the
     * player's own request. Returns the seek's token.
     */
    fun seekBegan(
        returnsToActiveTrack: Boolean,
        afterFailedLoad: Boolean,
        cancelledWait: Boolean,
        playerPlaying: Boolean
    ): Long {
        val playing = playerPlaying || requestsPlay
        kind = when {
            cancelledWait || !playing -> Kind.NONE
            returnsToActiveTrack -> if (afterFailedLoad) Kind.RESUMES_AFTER_SEEK else Kind.NONE
            // On the player's track with a request a failure kept (a give-up's error, a failed
            // seek, a seek in progress): the player is held, the seek plays once done.
            requestsPlay -> Kind.RESUMES_AFTER_SEEK
            else -> Kind.NONE
        }
        latestSeek += 1
        return latestSeek
    }

    /**
     * The seek [seek] ended ([succeeded]): whether the player plays now (the latest seek, which
     * succeeded, holding the player). The latest one that failed keeps the request
     * ([Kind.KEPT_AFTER_FAILURE]). An older seek's end changes nothing.
     */
    fun seekEnded(seek: Long, succeeded: Boolean): Boolean {
        if (seek != latestSeek || kind != Kind.RESUMES_AFTER_SEEK) return false
        kind = if (succeeded) Kind.NONE else Kind.KEPT_AFTER_FAILURE
        return succeeded
    }

    companion object {
        /** The paused player's states while a seek holds it (KotlinAudio's). */
        private val HELD_STATES = setOf(
            AudioPlayerState.LOADING,
            AudioPlayerState.BUFFERING,
            AudioPlayerState.READY,
            AudioPlayerState.PAUSED
        )

        fun requestsPlay(kind: Kind): Boolean = kind != Kind.NONE

        /**
         * The state the app reads for the player's [physical] one in [kind]: while a seek holds
         * the player paused, LOADING, crossfade's state during a seek (its SEEKING), not the
         * paused player's loading, buffering, ready or paused.
         */
        fun reportedState(kind: Kind, physical: AudioPlayerState): AudioPlayerState =
            if (kind == Kind.RESUMES_AFTER_SEEK && physical in HELD_STATES) AudioPlayerState.LOADING else physical
    }
}
