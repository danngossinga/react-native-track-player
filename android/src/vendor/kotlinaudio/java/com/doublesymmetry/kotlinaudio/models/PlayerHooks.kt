package com.doublesymmetry.kotlinaudio.models

import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.upstream.TransferListener

/**
 * Fork addition (react-native-track-player, see VENDORED.md): lets the host configure what
 * KotlinAudio builds privately. Defaults keep upstream behaviour.
 */
class PlayerHooks(
    /** Applied to the ExoPlayer builder before it builds (for example a track selector). */
    val configureExoPlayer: (ExoPlayer.Builder) -> Unit = {},
    /**
     * Builds the HTTP data source factory of an item from KotlinAudio's own configuration of it
     * (user agent, redirects, headers); null keeps a plain DefaultHttpDataSource.Factory.
     */
    val httpDataSourceFactory: ((DefaultHttpDataSource.Factory.() -> Unit) -> DataSource.Factory)? = null,
    /**
     * When true, KotlinAudio never requests audio focus (upstream requests it when the player
     * becomes READY, even while paused) and so neither ducks nor emits its own focus event: the
     * host holds one focus for every player, requested at the user's play, and pauses and resumes
     * itself (one rule for every backend).
     */
    val hostOwnsAudioFocus: Boolean = false,
    /**
     * Told of every media request's bytes (segments, chunks, a progressive file), not of
     * playlists, manifests or keys: the host's measure of a load's progress. Null: none.
     */
    val mediaTransferListener: TransferListener? = null
)
