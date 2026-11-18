package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.ForwardingPlayer
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.PlaybackException
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.util.FlagSet

/**
 * The player the standard player's media session and notification read (vendored KotlinAudio's
 * [com.doublesymmetry.kotlinaudio.models.PlayerHooks.sessionPlayer]): [player] as is, except
 * while [hold] holds the reported track ([ReportedNowPlaying] held: another track loads, or failed
 * to load). Then it reports that track as the app reads it ([ReportedTrackProgress]: its last
 * position, its duration, what it had buffered), not playing (speed 0, the position does not
 * move: a track that loads or failed to load never plays, so ExoPlayer's own isPlaying is false
 * while held), as iOS holds the lock screen on the reported track at its last position, rate 0
 * (monorepo rule 13: every reader agrees with getActiveTrack). Its play-when-ready is the one the
 * app reads ([requestKept]: a failure's kept request, StandardSeekResume, as crossfade's surface
 * keys its play/pause on the snapshot's playWhenReady): the notification's ongoing flag
 * (PlayerNotificationManager.getOngoing: buffering or ready and play-when-ready) keeps
 * MusicService's foreground service as the app's request is, so the session shows buffering at
 * that position while the player means to play. While a seek holds the player paused after a
 * failure ([seekHolds]) its state is buffering, as the app reads loading (crossfade's surface:
 * LOADING is STATE_BUFFERING), not the paused player's ready (which the connector would show
 * paused, or playing with the kept request). Held, the
 * current media item (index, item, next and previous) is the reported track's, as the app's
 * active track: the media session's active queue item (TimelineQueueNavigator reads the current
 * media item index). A host give-up's error ([hostError]: a load or seek the host gave up, which
 * stops the player with no ExoPlayer error) is the player's error, so the session shows the error
 * state as the app does (ERROR), not none. The media session and the notification only read the
 * player at its events, so a change of what it reports tells them at once ([hold], [refresh]).
 * Commands pass through. Main thread.
 */
internal class ReportedSessionPlayer(player: Player) : ForwardingPlayer(player) {
    /** The reported track's progress while held (null: the player's own values). */
    var held: TrackProgress? = null
        private set
    private val listeners = mutableListOf<Player.Listener>()

    /** The reported track's index (null: none), read live while held (a queue change moves it). */
    var reportedIndex: () -> Int? = { null }

    /** The error of a host give-up the player is in (null: none), read live (the next command ends it). */
    var hostError: () -> PlaybackException? = { null }

    /**
     * Whether a failure keeps the module's play request the player itself no longer has
     * (StandardSeekResume.requestsPlay; false in the logical idle), read live: the session's
     * play-when-ready is the app's.
     */
    var requestKept: () -> Boolean = { false }

    /** Whether a seek holds the player paused after a failure (the app reads LOADING), read live. */
    var seekHolds: () -> Boolean = { false }

    /** What the session and the notification were last told. */
    private data class Told(
        val held: TrackProgress?,
        val index: Int?,
        val error: Boolean,
        val playWhenReady: Boolean,
        val state: Int
    )

    private var told = Told(null, null, false, false, Player.STATE_IDLE)

    /**
     * Holds the reported track's [progress] (null: released), then [refresh].
     */
    fun hold(progress: TrackProgress?) {
        held = progress
        refresh()
    }

    /**
     * A change of what this player reports (held, the held index, a host error, a kept request,
     * a seek's hold) tells the session and the notification at once, not at the player's next
     * event (none may come: a stop or a cleared queue after a give-up, a pause of a player a seek
     * holds paused): EVENT_IS_PLAYING_CHANGED, at which ExoPlayer 2.19.0's MediaSessionConnector
     * invalidates its playback state (it reads getPlayerError, getPlaybackState and
     * getPlayWhenReady) and PlayerNotificationManager posts again (its play/pause action and
     * ongoing flag read getPlayWhenReady and getPlaybackState), with
     * EVENT_PLAY_WHEN_READY_CHANGED and EVENT_PLAYBACK_STATE_CHANGED when those changed, and
     * EVENT_POSITION_DISCONTINUITY when the current media item index changed (the connector then
     * tells TimelineQueueNavigator, whose active queue item follows it).
     */
    fun refresh() {
        val now = Told(held, heldIndex(), hostError() != null, playWhenReady, playbackState)
        if (now == told) return
        val before = told
        told = now
        val flags = FlagSet.Builder().add(Player.EVENT_IS_PLAYING_CHANGED)
        if (now.index != before.index) flags.add(Player.EVENT_POSITION_DISCONTINUITY)
        if (now.playWhenReady != before.playWhenReady) flags.add(Player.EVENT_PLAY_WHEN_READY_CHANGED)
        if (now.state != before.state) flags.add(Player.EVENT_PLAYBACK_STATE_CHANGED)
        val events = Player.Events(flags.build())
        listeners.toList().forEach { it.onEvents(this, events) }
    }

    /** The reported track's index while held and in the timeline (null: the player's own). */
    private fun heldIndex(): Int? =
        if (held == null) null else reportedIndex()?.takeIf { it in 0 until super.getMediaItemCount() }

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
    // The loading track's window is a placeholder, dynamic until it loads: KotlinAudio's
    // notification metadata would then drop the held duration (NotificationManager.getDuration).
    // Held, the item is dynamic only when the reported track's duration is not known.
    override fun isCurrentMediaItemDynamic(): Boolean = held?.let { it.durationMs <= 0L } ?: super.isCurrentMediaItemDynamic()
    override fun getCurrentMediaItemIndex(): Int = heldIndex() ?: super.getCurrentMediaItemIndex()
    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun getCurrentWindowIndex(): Int = heldIndex() ?: super.getCurrentWindowIndex()
    override fun getCurrentMediaItem(): MediaItem? = heldIndex()?.let { super.getMediaItemAt(it) } ?: super.getCurrentMediaItem()
    override fun getNextMediaItemIndex(): Int = heldIndex()?.let { neighbour(it, next = true) } ?: super.getNextMediaItemIndex()
    override fun getPreviousMediaItemIndex(): Int = heldIndex()?.let { neighbour(it, next = false) } ?: super.getPreviousMediaItemIndex()
    override fun hasNextMediaItem(): Boolean = heldIndex()?.let { neighbour(it, next = true) != C.INDEX_UNSET } ?: super.hasNextMediaItem()
    override fun hasPreviousMediaItem(): Boolean = heldIndex()?.let { neighbour(it, next = false) != C.INDEX_UNSET } ?: super.hasPreviousMediaItem()
    override fun getPlayerError(): PlaybackException? = super.getPlayerError() ?: hostError()
    override fun getPlayWhenReady(): Boolean = super.getPlayWhenReady() || requestKept()
    override fun getPlaybackState(): Int = if (seekHolds()) Player.STATE_BUFFERING else super.getPlaybackState()

    /** The item after or before [index] in the timeline, as ExoPlayer's own (repeat one: off). */
    private fun neighbour(index: Int, next: Boolean): Int {
        val timeline = super.getCurrentTimeline()
        if (timeline.isEmpty) return C.INDEX_UNSET
        val repeat = super.getRepeatMode().let { if (it == Player.REPEAT_MODE_ONE) Player.REPEAT_MODE_OFF else it }
        return if (next) timeline.getNextWindowIndex(index, repeat, super.getShuffleModeEnabled())
        else timeline.getPreviousWindowIndex(index, repeat, super.getShuffleModeEnabled())
    }

    /** A duration the app reads as 0 (not known) is ExoPlayer's unset one. */
    private fun durationOf(progress: TrackProgress): Long =
        if (progress.durationMs > 0L) progress.durationMs else C.TIME_UNSET
}
