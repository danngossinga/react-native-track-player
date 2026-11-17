package com.google.android.exoplayer2.ext.mediasession

import android.os.Bundle
import android.os.ResultReceiver
import android.support.v4.media.MediaDescriptionCompat
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.RatingCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import com.google.android.exoplayer2.Player

// Stand-ins for ExoPlayer's media session extension (2.19.0), which vendored KotlinAudio names:
// not in this machine's offline Gradle 8 cache. The media session is not under test here; same
// shapes, no behaviour.

class MediaSessionConnector(@Suppress("UNUSED_PARAMETER") mediaSession: MediaSessionCompat) {
    interface CommandReceiver {
        fun onCommand(player: Player, command: String, extras: Bundle?, cb: ResultReceiver?): Boolean
    }

    interface QueueNavigator : CommandReceiver

    interface RatingCallback : CommandReceiver {
        fun onSetRating(player: Player, rating: RatingCompat)
        fun onSetRating(player: Player, rating: RatingCompat, extras: Bundle?)
    }

    interface CustomActionProvider {
        fun onCustomAction(player: Player, action: String, extras: Bundle?)
        fun getCustomAction(player: Player): PlaybackStateCompat.CustomAction?
    }

    fun interface MediaMetadataProvider {
        fun getMetadata(player: Player): MediaMetadataCompat
    }

    fun setPlayer(player: Player?) = Unit
    fun setQueueNavigator(queueNavigator: QueueNavigator?) = Unit
    fun setMetadataDeduplicationEnabled(enabled: Boolean) = Unit
    fun invalidateMediaSessionQueue() = Unit
    fun invalidateMediaSessionMetadata() = Unit
    fun setEnabledPlaybackActions(actions: Long) = Unit
    fun setCustomActionProviders(vararg providers: CustomActionProvider?) = Unit
    fun setRatingCallback(callback: RatingCallback?) = Unit
    fun setMediaMetadataProvider(provider: MediaMetadataProvider?) = Unit
}

abstract class TimelineQueueNavigator(@Suppress("UNUSED_PARAMETER") mediaSession: MediaSessionCompat) :
    MediaSessionConnector.QueueNavigator {
    open fun getSupportedQueueNavigatorActions(player: Player): Long = 0L
    abstract fun getMediaDescription(player: Player, windowIndex: Int): MediaDescriptionCompat
    override fun onCommand(player: Player, command: String, extras: Bundle?, cb: ResultReceiver?): Boolean = false
}
