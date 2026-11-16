package com.doublesymmetry.trackplayer.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import androidx.core.content.ContextCompat
import androidx.media.AudioAttributesCompat
import androidx.media.AudioFocusRequestCompat
import androidx.media.AudioManagerCompat
import com.doublesymmetry.kotlinaudio.models.AudioContentType

/** The system's audio focus, behind a small interface so the JVM tests can fake it. */
internal interface AudioFocusRequester {
    /** Requests the focus; [onChange] receives every later change. True when it is granted. */
    fun request(onChange: (Int) -> Unit): Boolean

    fun abandon()
}

/** The headphones-unplugged broadcast, behind a small interface so the JVM tests can fake it. */
internal interface NoisyReceiverRegistrar {
    fun register(onNoisy: () -> Unit)

    fun unregister()
}

/**
 * The service's single audio focus holder, for both backends (DJE-204): KotlinAudio and the
 * crossfade engines hold none, so a backend switch or a fade between two engines never takes the
 * focus from itself. Requested at every play and every resume after an interruption; given up on
 * stop, reset, a permanent loss and when the service is destroyed. Every change goes to
 * [onFocusChange] (the InterruptionPolicy). A can-duck loss is reported, not ducked. Main thread.
 */
internal class PlaybackAudioFocus(
    private val requester: AudioFocusRequester,
    private val onFocusChange: (Int) -> Unit
) {
    /** The request is registered with the system (until abandoned or lost for good). */
    private var registered = false

    /** The focus is ours now: registered and not taken away for a while. */
    var isHeld: Boolean = false
        private set

    /** Requests the focus unless it is held. True when it is held afterwards. */
    fun requestIfNeeded(): Boolean {
        if (isHeld) return true
        val granted = requester.request(::changed)
        if (granted) registered = true
        isHeld = granted
        return granted
    }

    fun abandon() {
        isHeld = false
        if (!registered) return
        registered = false
        requester.abandon()
    }

    private fun changed(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> abandon()
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> isHeld = false
            AudioManager.AUDIOFOCUS_GAIN -> isHeld = registered
        }
        onFocusChange(change)
    }
}

/**
 * [AudioFocusRequester] on the system's AudioManager: one request, reused while registered. Its
 * content type is the app's `androidAudioContentType` (an AudioAttributesCompat content type),
 * read when a request is built.
 */
internal class SystemAudioFocusRequester(
    private val context: Context,
    private val contentType: () -> Int
) : AudioFocusRequester {
    private var listener: (Int) -> Unit = {}
    private var current: AudioFocusRequestCompat? = null

    override fun request(onChange: (Int) -> Unit): Boolean {
        listener = onChange
        val manager = ContextCompat.getSystemService(context, AudioManager::class.java) ?: return false
        val focusRequest = current ?: AudioFocusRequestCompat.Builder(AudioManagerCompat.AUDIOFOCUS_GAIN)
            .setOnAudioFocusChangeListener { change -> listener(change) }
            .setAudioAttributes(
                AudioAttributesCompat.Builder()
                    .setUsage(AudioAttributesCompat.USAGE_MEDIA)
                    .setContentType(contentType())
                    .build()
            )
            .setWillPauseWhenDucked(true)
            .build()
        current = focusRequest
        return AudioManagerCompat.requestAudioFocus(manager, focusRequest) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    override fun abandon() {
        val held = current ?: return
        current = null
        ContextCompat.getSystemService(context, AudioManager::class.java)?.let {
            AudioManagerCompat.abandonAudioFocusRequest(it, held)
        }
    }
}

/** The focus request's content type for the app's `androidAudioContentType`. */
internal fun focusContentTypeOf(type: AudioContentType): Int = when (type) {
    AudioContentType.MUSIC -> AudioAttributesCompat.CONTENT_TYPE_MUSIC
    AudioContentType.SPEECH -> AudioAttributesCompat.CONTENT_TYPE_SPEECH
    AudioContentType.SONIFICATION -> AudioAttributesCompat.CONTENT_TYPE_SONIFICATION
    AudioContentType.MOVIE -> AudioAttributesCompat.CONTENT_TYPE_MOVIE
    AudioContentType.UNKNOWN -> AudioAttributesCompat.CONTENT_TYPE_UNKNOWN
}

/** [NoisyReceiverRegistrar] on the system broadcast (delivered to a not-exported receiver too). */
internal class ContextNoisyReceiverRegistrar(private val context: Context) : NoisyReceiverRegistrar {
    private var receiver: BroadcastReceiver? = null

    override fun register(onNoisy: () -> Unit) {
        if (receiver != null) return
        val created = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) onNoisy()
            }
        }
        ContextCompat.registerReceiver(
            context, created, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        receiver = created
    }

    override fun unregister() {
        val registered = receiver ?: return
        receiver = null
        runCatching { context.unregisterReceiver(registered) }
    }
}
