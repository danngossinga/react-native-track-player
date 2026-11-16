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
     * Builds the HTTP data source factory of an item from KotlinAudio's own configuration of it
     * (user agent, redirects, headers); null keeps a plain DefaultHttpDataSource.Factory.
     */
    val httpDataSourceFactory: ((DefaultHttpDataSource.Factory.() -> Unit) -> DataSource.Factory)? = null,
    /**
     * When set, receives every audio focus change of the focus KotlinAudio holds, and KotlinAudio
     * neither ducks nor emits its own focus event: the host pauses and resumes (one rule for every
     * backend). A permanent loss still gives the focus up.
     */
    val onAudioFocusChange: ((Int) -> Unit)? = null
)
