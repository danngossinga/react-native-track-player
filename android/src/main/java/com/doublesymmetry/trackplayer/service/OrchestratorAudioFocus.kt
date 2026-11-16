package com.doublesymmetry.trackplayer.service

import android.content.Context
import android.media.AudioManager
import androidx.core.content.ContextCompat
import androidx.media.AudioAttributesCompat
import androidx.media.AudioFocusRequestCompat
import androidx.media.AudioManagerCompat

/**
 * The crossfade backend's single audio focus holder (DJE-204): one request for the orchestrator,
 * never one per engine, so a fade between the two engines never takes the focus from itself.
 * Requested at every play, given up on stop or a permanent loss; every change goes to
 * [onFocusChange] (the service's InterruptionPolicy). A can-duck loss is reported, not ducked.
 */
internal class OrchestratorAudioFocus(
    private val context: Context,
    private val onFocusChange: (Int) -> Unit
) {
    private var request: AudioFocusRequestCompat? = null

    val isHeld: Boolean
        get() = request != null

    fun requestIfNeeded() {
        if (request != null) return
        val manager = ContextCompat.getSystemService(context, AudioManager::class.java) ?: return
        val created = AudioFocusRequestCompat.Builder(AudioManagerCompat.AUDIOFOCUS_GAIN)
            .setOnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS) abandon()
                onFocusChange(change)
            }
            .setAudioAttributes(
                AudioAttributesCompat.Builder()
                    .setUsage(AudioAttributesCompat.USAGE_MEDIA)
                    .setContentType(AudioAttributesCompat.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setWillPauseWhenDucked(true)
            .build()
        if (AudioManagerCompat.requestAudioFocus(manager, created) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            request = created
        }
    }

    fun abandon() {
        val held = request ?: return
        request = null
        ContextCompat.getSystemService(context, AudioManager::class.java)?.let {
            AudioManagerCompat.abandonAudioFocusRequest(it, held)
        }
    }
}
