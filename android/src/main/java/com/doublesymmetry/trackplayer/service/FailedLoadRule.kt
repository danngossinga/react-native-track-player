package com.doublesymmetry.trackplayer.service

/**
 * Which track is active around a load, as iOS's crossfade loadIndex decides it (chosen alignment
 * for both backends and both platforms): a track becomes the active one once it loaded (ready);
 * when its load fails (a give-up, a player error) the previous track stays active (none when
 * there was none), and the next play loads that previous track. Items are compared by identity.
 * Shared scenarios: scripts/fixtures/failed-load-scenarios.json (iOS: FailedLoadRule).
 *
 * A standard player moves to an item before it loads and reports it then ([moved]); the rule
 * also keeps what the app was last told, so each correction is reported once: back to the
 * previous track when a load fails ([failed]), to the player's own track when a command acts
 * after that ([command]) or when a track that was never reported becomes ready ([ready]), and
 * not again when a play reloads the previous track ([play], then [moved]).
 */
internal class FailedLoadRule {
    /** A change of the active track to report: [to] (null: none). */
    data class Report(val to: Any?)

    private var current: Any? = null
    private var lastReady: Any? = null
    private var reported: Any? = null
    private var reverted = false

    /** The active track: the last one that loaded. */
    val active: Any?
        get() = lastReady

    /** A failed load was reverted and no command has acted since: [active] is what to report. */
    val isReverted: Boolean
        get() = reverted

    /** The player is on [item] (polled). */
    fun loaded(item: Any?) {
        current = item
    }

    /** The player moved to [item] and would report it: whether to (false: the app has it). */
    fun moved(item: Any?): Boolean {
        current = item
        if (item === reported) return false
        reported = item
        return true
    }

    /** The current item is ready: it is the active track; a report when the app was not told. */
    fun ready(): Report? {
        lastReady = current
        reverted = false
        if (current === reported) return null
        reported = current
        return Report(current)
    }

    /** The current item's load failed: the revert to report, or null when it was the active one. */
    fun failed(): Report? {
        if (current === lastReady) return null
        reverted = true
        reported = lastReady
        return Report(lastReady)
    }

    /** A play: the item to load first (the active one after a revert), or null to play the current. */
    fun play(): Any? {
        if (!reverted) return null
        reverted = false
        val target = lastReady ?: return null
        current = target
        return target
    }

    /** Another command acts on the player's own track: a report when the app was told another. */
    fun command(): Report? {
        if (!reverted) return null
        reverted = false
        if (current === reported) return null
        reported = current
        return Report(current)
    }
}
