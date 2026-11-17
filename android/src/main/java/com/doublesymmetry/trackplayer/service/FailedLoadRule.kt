package com.doublesymmetry.trackplayer.service

/**
 * Which track is active around a load, and when the app is told, as iOS's crossfade loadIndex
 * decides it (chosen alignment for both backends and both platforms): a track becomes the active
 * one once it loaded (ready), and only then is it reported; while it loads and after its load
 * fails (a give-up, a player error) the previous track stays active (none when there was none)
 * and the failed track is never reported. The next play loads the previous track again or, when
 * there was none, retries the track that failed. Items are compared by identity.
 * Shared scenarios: scripts/fixtures/failed-load-scenarios.json (iOS: FailedLoadRule).
 *
 * A standard player moves to an item before it loads ([moved]); the rule says when to report it.
 * The only move reported at once is the selection of a new queue's first track (nothing reported
 * yet: the players select it when the queue is set, before any load).
 */
internal class FailedLoadRule {
    /** A change of the active track to report: [to] (null: none) from [from] (null: none). */
    data class Report(val to: Any?, val from: Any?)

    /**
     * Where the player's own item stands (one explicit state, the monorepo's state-machine form 3:
     * a closed union moved only by this class's events; iOS: the same `FailedLoadRule.Phase`).
     *
     * - [Selecting]: a new queue (or none); the player's first move is its selection, reported at
     *   once. No item.
     * - [Loading]: the player is on [item] (null: none), which has not loaded since it moved there.
     * - [Loaded]: [item] loaded: it is the active track ([active] === item).
     * - [Failed]: [item]'s load failed (a give-up, a player error); the next play loads the active
     *   track again, else retries [item]. A move keeps it failed (the player's own item changes).
     *
     * Moves: Selecting -moved(x)-> Loading(x) (reported at once; x null: stays); Loading/Loaded
     * -moved(x)-> Loaded(x) when x is the active track, else Loading(x); Failed -moved(x)->
     * Failed(x); any -ready-> Loaded(item); Loading/Failed(not active) -failed-> Failed(item);
     * Failed -play/command-> Loaded/Loading (play: the active track, else the failed one);
     * any -reset-> Selecting; -adopted(x)-> Loaded(x) (x null: Selecting); published, replaced and
     * removed keep the kind and follow the item.
     */
    sealed class Phase {
        object Selecting : Phase() {
            override fun toString() = "selecting"
        }
        data class Loading(val item: Any?) : Phase()
        data class Loaded(val item: Any?) : Phase()
        data class Failed(val item: Any?) : Phase()
    }

    /**
     * The player's error, as the load sees it: [NONE], or [REPORTED] once a player error failed
     * the load, until the player has no error any more (an edge: one failure per error, which
     * outlives the moves, commands and a new queue that come while the player still has it).
     */
    enum class PlayerError { NONE, REPORTED }

    var phase: Phase = Phase.Selecting
        private set

    var playerError: PlayerError = PlayerError.NONE
        private set

    /** The active track: the last one that loaded. */
    var active: Any? = null
        private set

    /** The track the app was last told is active (null: none). */
    var reported: Any? = null
        private set

    /** The player's item (null: none, or a new queue's selection not made yet). */
    private val current: Any?
        get() = when (val phase = phase) {
            Phase.Selecting -> null
            is Phase.Loading -> phase.item
            is Phase.Loaded -> phase.item
            is Phase.Failed -> phase.item
        }

    /** The player is on [item], not failed: loaded when it is the active track. */
    private fun following(item: Any?): Phase = if (item === active) Phase.Loaded(item) else Phase.Loading(item)

    /** The same kind of phase on [item] (a failed one stays failed). */
    private fun onItem(item: Any?): Phase = when (phase) {
        Phase.Selecting -> Phase.Selecting
        is Phase.Failed -> Phase.Failed(item)
        else -> following(item)
    }

    /** The player moved to [item]: whether to report it now (else once it loaded). */
    fun moved(item: Any?): Boolean {
        if (phase == Phase.Selecting) {
            // Nothing is reported in a new queue: a move to no item is no selection.
            if (item === reported) return false
            reported = item
            phase = following(item)
            return true
        }
        phase = onItem(item)
        return false
    }

    /** The current item is ready: it is the active track, reported when the app was not told. */
    fun ready(): Report? {
        val item = current
        active = item
        phase = Phase.Loaded(item)
        return reportCurrentTrack(item)
    }

    /**
     * The current item's load failed: the previous track stays active. A report only when the
     * failed track had been reported (a selected first track): back to the active one.
     */
    fun failed(): Report? {
        val item = when (val phase = phase) {
            is Phase.Loading -> phase.item
            is Phase.Failed -> if (phase.item === active) return null else phase.item
            Phase.Selecting, is Phase.Loaded -> return null
        }
        phase = Phase.Failed(item)
        return reportCurrentTrack(active)
    }

    /** A play: the item to load first (the active one, else the failed one), or null to play the current. */
    fun play(): Any? {
        val failed = phase as? Phase.Failed ?: return null
        val target = active ?: failed.item
        phase = following(target)
        return target
    }

    /** Another command acts on the player's own track: reported once it loads (no report now). */
    fun command(): Report? {
        (phase as? Phase.Failed)?.let { phase = following(it.item) }
        return null
    }

    /** The queue was replaced or cleared: its first track is a new selection. */
    fun reset() {
        phase = Phase.Selecting
        active = null
        reported = null
    }

    /**
     * [item] left the queue: when it was the reported (or active) track, there is none any more,
     * reported at once (the next track is reported once it loaded).
     */
    fun removed(item: Any?): Report? {
        if (item == null) return null
        if (active === item) active = null
        phase = onItem(current.takeIf { it !== item })
        return if (reported === item) reportCurrentTrack(null) else null
    }

    /** The app was told about [item] another way (a logical idle activation). */
    fun published(item: Any?) {
        reported = item
        phase = if (phase is Phase.Failed) Phase.Failed(item) else following(item)
    }

    /** The player is on [item], loaded and known to the app (a backend switch restored it). */
    fun adopted(item: Any?) {
        active = item
        reported = item
        phase = if (item == null) Phase.Selecting else Phase.Loaded(item)
    }

    /** [old] was replaced by [new] for the same track (new metadata): it keeps its place. */
    fun replaced(old: Any?, new: Any?) {
        if (active === old) active = new
        if (reported === old) reported = new
        val item = current
        phase = onItem(if (item === old) new else item)
    }

    /** The player is on an item other than the one reported: report [reported]'s index instead. */
    fun isPending(item: Any?): Boolean = item !== reported

    /** The player reports an error: true the first time (the caller fails the load), false while it lasts. */
    fun playerErrorSeen(): Boolean {
        if (playerError == PlayerError.REPORTED) return false
        playerError = PlayerError.REPORTED
        return true
    }

    /** The player has no error: true when one had failed the load (it is over now). */
    fun playerErrorGone(): Boolean {
        val had = playerError == PlayerError.REPORTED
        playerError = PlayerError.NONE
        return had
    }

    private fun reportCurrentTrack(to: Any?): Report? {
        if (to === reported) return null
        val from = reported
        reported = to
        return Report(to, from)
    }
}

/**
 * The track a play loads after a failed load (crossfade, both platforms): the active track when
 * there is one; with none (the first load failed), the track that failed, retried; null when
 * neither is in the queue. The standard backends follow the same rule ([FailedLoadRule.play]).
 */
internal fun indexToPlayAfterFailedLoad(currentIndex: Int, failedIndex: Int?, count: Int): Int? {
    if (currentIndex in 0 until count) return currentIndex
    return failedIndex?.takeIf { it in 0 until count }
}
