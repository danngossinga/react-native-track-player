/*
 * Modified by the react-native-track-player fork, 2026: see VENDORED.md
 * (Apache License 2.0, section 4(b)). Originally from KotlinAudio v2.1.0.
 */
package com.doublesymmetry.kotlinaudio.models

data class PlaybackError (
    val code: String? = null,
    val message: String? = null,
    // Fork: an error the host reported (BaseAudioPlayer.failLoad), whose code is the host's own.
    val fromHost: Boolean = false
)
