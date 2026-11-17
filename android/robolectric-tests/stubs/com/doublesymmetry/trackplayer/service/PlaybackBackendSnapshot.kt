package com.doublesymmetry.trackplayer.service

/** Stand-in for the library's snapshot (PlaybackBackendRuntime.kt names it). */
data class PlaybackBackendSnapshot(
    val queueIds: List<String>,
    val activeIndex: Int?,
    val activeTrackId: String?,
    val playWhenReady: Boolean
)
