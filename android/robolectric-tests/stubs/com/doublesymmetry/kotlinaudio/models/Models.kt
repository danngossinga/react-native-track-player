package com.doublesymmetry.kotlinaudio.models

// Stand-ins for the KotlinAudio v2.1.0 types the engine's sources name (same shapes).

enum class MediaType { DEFAULT, DASH, HLS, SMOOTH_STREAMING }

enum class AudioPlayerState { LOADING, READY, BUFFERING, PAUSED, STOPPED, PLAYING, IDLE, ENDED, ERROR }

data class AudioItemOptions(
    val headers: MutableMap<String, String>? = null,
    val userAgent: String? = null,
    val resourceId: Int? = null
)

interface AudioItem {
    var audioUrl: String
    val type: MediaType
    var artist: String?
    var title: String?
    var albumTitle: String?
    val artwork: String?
    val duration: Long?
    val options: AudioItemOptions?
}
