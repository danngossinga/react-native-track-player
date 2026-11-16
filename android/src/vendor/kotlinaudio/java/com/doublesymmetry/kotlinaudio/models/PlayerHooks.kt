package com.doublesymmetry.kotlinaudio.models

import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource

/**
 * Fork addition (react-native-track-player, see VENDORED.md): lets the host configure what
 * KotlinAudio builds privately. Defaults keep upstream behaviour.
 */
class PlayerHooks(
    /** Applied to the ExoPlayer builder before it builds (for example a track selector). */
    val configureExoPlayer: (ExoPlayer.Builder) -> Unit = {},
    /**
     * Builds the HTTP data source factory of an item (given, so the host can tell its transfers
     * from other items') from KotlinAudio's own configuration of it (user agent, redirects,
     * headers); null keeps a plain DefaultHttpDataSource.Factory.
     */
    val httpDataSourceFactory: ((AudioItem, DefaultHttpDataSource.Factory.() -> Unit) -> DataSource.Factory)? = null,
    /**
     * When true, KotlinAudio never requests audio focus (upstream requests it when the player
     * becomes READY, even while paused) and so neither ducks nor emits its own focus event: the
     * host holds one focus for every player, requested at the user's play, and pauses and resumes
     * itself (one rule for every backend).
     */
    val hostOwnsAudioFocus: Boolean = false
)
