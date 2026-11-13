package com.doublesymmetry.trackplayer.service

/**
 * The playWhenReady last sent to JS for the orchestrated (PingPong) backend. Its state changes
 * report only `playback-state`, so play and pause must also say when playWhenReady flipped, or
 * JS's `usePlayWhenReady` / `useIsPlaying` keep the value read at mount (a mini player showing
 * Play while the music plays). The standard backend reports it from the player's own flow.
 */
internal class PlayWhenReadyPublication {
    private var last: Boolean? = null

    /**
     * Whether [value] must be sent now: always when [force] (the backend was just activated, and
     * JS must learn its value), otherwise only when it differs from the last value sent.
     */
    fun shouldPublish(value: Boolean, force: Boolean = false): Boolean {
        if (!force && last == value) return false
        last = value
        return true
    }
}
