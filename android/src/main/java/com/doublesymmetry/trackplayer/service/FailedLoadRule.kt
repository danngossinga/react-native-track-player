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

    private var current: Any? = null
    private var reverted = false
    private var selectionPending = true

    /** The active track: the last one that loaded. */
    var active: Any? = null
        private set

    /** The track the app was last told is active (null: none). */
    var reported: Any? = null
        private set

    /** The player moved to [item]: whether to report it now (else once it loaded). */
    fun moved(item: Any?): Boolean {
        current = item
        if (item === reported) return false
        if (!selectionPending) return false
        selectionPending = false
        reported = item
        return true
    }

    /** The current item is ready: it is the active track, reported when the app was not told. */
    fun ready(): Report? {
        active = current
        reverted = false
        selectionPending = false
        return reportCurrentTrack(current)
    }

    /**
     * The current item's load failed: the previous track stays active. A report only when the
     * failed track had been reported (a selected first track): back to the active one.
     */
    fun failed(): Report? {
        if (current === active) return null
        reverted = true
        return reportCurrentTrack(active)
    }

    /** A play: the item to load first (the active one, else the failed one), or null to play the current. */
    fun play(): Any? {
        if (!reverted) return null
        reverted = false
        val target = active ?: current
        current = target
        return target
    }

    /** Another command acts on the player's own track: reported once it loads (no report now). */
    fun command(): Report? {
        reverted = false
        return null
    }

    /** The queue was replaced or cleared: its first track is a new selection. */
    fun reset() {
        current = null
        active = null
        reported = null
        reverted = false
        selectionPending = true
    }

    /**
     * [item] left the queue: when it was the reported (or active) track, there is none any more,
     * reported at once (the next track is reported once it loaded).
     */
    fun removed(item: Any?): Report? {
        if (item == null) return null
        if (active === item) active = null
        if (current === item) current = null
        return if (reported === item) reportCurrentTrack(null) else null
    }

    /** The app was told about [item] another way (a logical idle activation). */
    fun published(item: Any?) {
        current = item
        reported = item
        selectionPending = false
    }

    /** The player is on [item], loaded and known to the app (a backend switch restored it). */
    fun adopted(item: Any?) {
        current = item
        active = item
        reported = item
        reverted = false
        selectionPending = item == null
    }

    /** [old] was replaced by [new] for the same track (new metadata): it keeps its place. */
    fun replaced(old: Any?, new: Any?) {
        if (current === old) current = new
        if (active === old) active = new
        if (reported === old) reported = new
    }

    /** The player is on an item other than the one reported: report [reported]'s index instead. */
    fun isPending(item: Any?): Boolean = item !== reported

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
