package com.doublesymmetry.trackplayer.service

/**
 * Which track is active around a load, as iOS's crossfade loadIndex decides it (chosen alignment
 * for both backends and both platforms): a track becomes the active one once it loaded (ready);
 * when its load fails (a give-up, a player error) the previous track stays active (none when
 * there was none), and the next play loads that previous track. Items are compared by identity.
 * Shared scenarios: scripts/fixtures/failed-load-scenarios.json (iOS: FailedLoadRule).
 *
 * The standard players move to an item before it loads (and report it then); this rule tells
 * them what to report back when that load fails ([failed]) and what a play reloads ([play]).
 */
internal class FailedLoadRule {
    /** What a failed load reports: the track active again ([to]; null: none). */
    data class Revert(val to: Any?)

    private var current: Any? = null
    private var lastReady: Any? = null
    private var reverted = false

    /** The active track: the last one that loaded. */
    val active: Any?
        get() = lastReady

    /** A failed load was reverted and no command has acted since: [active] is what to report. */
    val isReverted: Boolean
        get() = reverted

    /** The player moved to [item] (a load, a skip, a natural advance). */
    fun loaded(item: Any?) {
        if (item === current) return
        current = item
    }

    /** The current item is ready (plays or has media): it is the active track. */
    fun ready() {
        lastReady = current
        reverted = false
    }

    /** The current item's load failed: the revert to report, or null when it was the active one. */
    fun failed(): Revert? {
        if (current === lastReady) return null
        reverted = true
        return Revert(lastReady)
    }

    /** A play: the item to load first (the active one after a revert), or null to play the current. */
    fun play(): Any? {
        if (!reverted) return null
        reverted = false
        val target = lastReady ?: return null
        current = target
        return target
    }

    /** Another command acted on the player: it reports its own item again. */
    fun command() {
        reverted = false
    }
}
