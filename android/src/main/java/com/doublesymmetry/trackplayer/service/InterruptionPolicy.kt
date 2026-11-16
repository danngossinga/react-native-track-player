package com.doublesymmetry.trackplayer.service

import android.media.AudioManager
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState

/**
 * Whether a backend plays as far as an interruption is concerned, the same rule on all four
 * backends (iOS: `interruptionCountsAsPlaying`): it was asked to play and has an active track
 * that has not ended, failed or stopped. After the queue ended, an interruption neither pauses
 * nor resumes.
 */
internal fun interruptionCountsAsPlaying(playWhenReady: Boolean, state: AudioPlayerState): Boolean =
    playWhenReady && state !in INTERRUPTION_FINISHED_STATES

internal val INTERRUPTION_FINISHED_STATES = setOf(
    AudioPlayerState.IDLE, AudioPlayerState.ENDED, AudioPlayerState.ERROR, AudioPlayerState.STOPPED
)

/** What the player does on an interruption event (DJE-204/205/206; iOS has the same policy). */
internal enum class InterruptionAction { NONE, PAUSE, RESUME }

/**
 * The `remote-duck` event for an interruption event: `paused` while the audio is taken away,
 * `permanent` when it will not be given back (same meaning on iOS and Android).
 */
internal data class RemoteDuckPayload(val paused: Boolean, val permanent: Boolean)

internal data class InterruptionDecision(val action: InterruptionAction, val duck: RemoteDuckPayload?)

/**
 * The owner's rule for calls, audio focus and headphones, the same as iOS's `InterruptionPolicy`
 * (shared scenarios in scripts/fixtures/interruption-scenarios.json): pause when the audio is taken
 * away; when it is given back, resume only if the system allows it, `autoHandleInterruptions` is
 * on, playback was playing when it was taken and the user did not pause or play since. A
 * permanent loss or headphones unplugged pause with no resume. A can-duck loss is a transient
 * loss: pause, then resume (iOS has no ducking, so both platforms pause). A second loss during
 * an interruption keeps what the first one recorded (the player is paused by then). Main thread
 * only.
 */
internal class InterruptionPolicy(
    /** `autoHandleInterruptions`, read at every interruption end. */
    private val autoResume: () -> Boolean
) {
    private var resumeOnEnd = false
    /** An interruption began and has not ended (nor been overtaken by the user or a permanent loss). */
    private var interrupted = false

    fun began(isPlaying: Boolean): InterruptionDecision {
        if (!interrupted) resumeOnEnd = isPlaying
        interrupted = true
        return InterruptionDecision(if (isPlaying) InterruptionAction.PAUSE else InterruptionAction.NONE, RemoteDuckPayload(paused = true, permanent = false))
    }

    fun ended(shouldResume: Boolean): InterruptionDecision {
        val resume = shouldResume && resumeOnEnd && autoResume()
        forget()
        return InterruptionDecision(if (resume) InterruptionAction.RESUME else InterruptionAction.NONE, RemoteDuckPayload(paused = !shouldResume, permanent = !shouldResume))
    }

    fun lostPermanently(isPlaying: Boolean): InterruptionDecision {
        forget()
        return InterruptionDecision(if (isPlaying) InterruptionAction.PAUSE else InterruptionAction.NONE, RemoteDuckPayload(paused = true, permanent = true))
    }

    /** Headphones unplugged (becoming noisy). */
    fun noisy(isPlaying: Boolean): InterruptionDecision {
        forget()
        return InterruptionDecision(if (isPlaying) InterruptionAction.PAUSE else InterruptionAction.NONE, null)
    }

    /** A play or pause from the user (app or remote control): an interruption's end no longer resumes. */
    fun userCommand() {
        forget()
    }

    private fun forget() {
        resumeOnEnd = false
        interrupted = false
    }

    /** An Android audio focus change, as an interruption event. */
    fun onFocusChange(focusChange: Int, isPlaying: Boolean): InterruptionDecision? = when (focusChange) {
        AudioManager.AUDIOFOCUS_LOSS -> lostPermanently(isPlaying)
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> began(isPlaying)
        AudioManager.AUDIOFOCUS_GAIN -> ended(shouldResume = true)
        else -> null
    }
}
