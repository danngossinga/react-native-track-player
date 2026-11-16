package com.doublesymmetry.trackplayer.service

/**
 * What the service does about calls, other apps' audio and headphones on both backends
 * (DJE-204/205/206): the InterruptionPolicy, the single audio focus and the headphones receiver,
 * with every user command and lifecycle step that touches them. The service only forwards to it;
 * [onInterruption] runs one interruption event on the active backend (see [applyTo]). Main thread.
 */
internal class InterruptionCoordinator(
    autoResume: () -> Boolean,
    focusRequester: AudioFocusRequester,
    private val noisyReceiver: NoisyReceiverRegistrar,
    private val onInterruption: (decide: (isPlaying: Boolean) -> InterruptionDecision?) -> Unit
) {
    private val policy = InterruptionPolicy(autoResume)
    val focus = PlaybackAudioFocus(focusRequester) { change ->
        onInterruption { isPlaying -> policy.onFocusChange(change, isPlaying) }
    }

    /** At setup: headphones unplugged pause both backends (no resume). */
    fun start() {
        noisyReceiver.register { onInterruption { isPlaying -> policy.noisy(isPlaying) } }
    }

    /**
     * A play from the user (app, notification, lock screen, headset): an interruption's end no
     * longer resumes, and the focus is requested. True when the focus is held.
     */
    fun userPlay(): Boolean {
        policy.userCommand()
        return focus.requestIfNeeded()
    }

    /** A pause from the user: an interruption's end no longer resumes. */
    fun userPause() {
        policy.userCommand()
    }

    /** A stop or a reset from the user: no resume, and the focus is given up. */
    fun userStop() {
        policy.userCommand()
        focus.abandon()
    }

    /** The service is destroyed: the receiver and the focus are given up. */
    fun destroy() {
        noisyReceiver.unregister()
        focus.abandon()
    }

    /**
     * Applies one decision to the active backend: pauses it, or requests the focus and resumes
     * it. [emit] gets the `remote-duck` payload once the pause is done, or before the resumed play
     * is awaited (as on iOS, where play does not wait), so also when the resume fails.
     */
    suspend fun applyTo(
        playWhenReady: Boolean,
        state: com.doublesymmetry.kotlinaudio.models.AudioPlayerState,
        decide: (Boolean) -> InterruptionDecision?,
        pause: suspend () -> Unit,
        play: suspend () -> Unit,
        emit: (RemoteDuckPayload) -> Unit,
        onResumeFailed: (Throwable) -> Unit = {}
    ): InterruptionDecision? {
        val decision = decide(interruptionCountsAsPlaying(playWhenReady, state)) ?: return null
        when (decision.action) {
            InterruptionAction.PAUSE -> {
                pause()
                decision.duck?.let(emit)
            }
            InterruptionAction.RESUME -> {
                focus.requestIfNeeded()
                decision.duck?.let(emit)
                try {
                    play()
                } catch (error: Exception) {
                    if (error is kotlinx.coroutines.CancellationException) throw error
                    onResumeFailed(error)
                }
            }
            InterruptionAction.NONE -> decision.duck?.let(emit)
        }
        return decision
    }
}
