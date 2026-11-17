package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.ForwardingPlayer
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.util.FlagSet

/**
 * The player the standard player's media session and notification read (vendored KotlinAudio's
 * [com.doublesymmetry.kotlinaudio.models.PlayerHooks.sessionPlayer]): [player] as is, except
 * while [hold] holds the reported track ([ReportedNowPlaying] held: another track loads, or failed
 * to load). Then it reports that track as the app reads it ([ReportedTrackProgress]: its last
 * position, its duration, what it had buffered) and not playing, as iOS holds the lock screen on
 * the reported track at its last position, rate 0 (monorepo rule 13: every reader agrees with
 * getActiveTrack). The media session and the notification only read the player at its events, so
 * a hold or release tells them at once ([hold]). Commands pass through. Main thread.
 */
internal class ReportedSessionPlayer(player: Player) : ForwardingPlayer(player) {
    /** The reported track's progress while held (null: the player's own values). */
    var held: TrackProgress? = null
        private set
    private val listeners = mutableListOf<Player.Listener>()

    /**
     * Holds the reported track's [progress] (null: released). A change tells the session and the
     * notification at once (their play state and position), not at the player's next event.
     */
    fun hold(progress: TrackProgress?) {
        if (progress == held) return
        held = progress
        val events = Player.Events(
            FlagSet.Builder().addAll(Player.EVENT_PLAY_WHEN_READY_CHANGED, Player.EVENT_IS_PLAYING_CHANGED).build()
        )
        listeners.toList().forEach { it.onEvents(this, events) }
    }

    override fun addListener(listener: Player.Listener) {
        listeners += listener
        super.addListener(listener)
    }

    override fun removeListener(listener: Player.Listener) {
        listeners -= listener
        super.removeListener(listener)
    }

    override fun getCurrentPosition(): Long = held?.positionMs ?: super.getCurrentPosition()
    override fun getContentPosition(): Long = held?.positionMs ?: super.getContentPosition()
    override fun getDuration(): Long = held?.let { durationOf(it) } ?: super.getDuration()
    override fun getContentDuration(): Long = held?.let { durationOf(it) } ?: super.getContentDuration()
    override fun getBufferedPosition(): Long = held?.bufferedMs ?: super.getBufferedPosition()
    override fun getContentBufferedPosition(): Long = held?.bufferedMs ?: super.getContentBufferedPosition()
    override fun getTotalBufferedDuration(): Long =
        held?.let { maxOf(0L, it.bufferedMs - it.positionMs) } ?: super.getTotalBufferedDuration()
    override fun isPlaying(): Boolean = held == null && super.isPlaying()
    override fun getPlayWhenReady(): Boolean = held == null && super.getPlayWhenReady()

    /** A duration the app reads as 0 (not known) is ExoPlayer's unset one. */
    private fun durationOf(progress: TrackProgress): Long =
        if (progress.durationMs > 0L) progress.durationMs else C.TIME_UNSET
}
