package com.doublesymmetry.trackplayer.service

import kotlinx.coroutines.launch

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

/**
 * Runs one interruption event on the active backend of [facade], inside its command lease: reads
 * whether it plays, pauses it or requests the focus and resumes it, and emits the `remote-duck`
 * payload. The resume's play is started at once, still inside the lease, but not awaited there:
 * like iOS, a backend switch issued while that play starts does not wait for it, and a user pause
 * runs at once. A failed start is reported as the backend reports any play start (its
 * playback-error) and passed to [onResumeFailed].
 */
internal suspend fun InterruptionCoordinator.applyOn(
    facade: PlaybackBackendFacade,
    scope: kotlinx.coroutines.CoroutineScope,
    decide: (Boolean) -> InterruptionDecision?,
    emit: (RemoteDuckPayload) -> Unit,
    onResumeFailed: (Throwable) -> Unit,
    onDecided: (InterruptionDecision?, PlaybackBackendType) -> Unit = { _, _ -> }
) {
    facade.withCurrentBackend { current ->
        val backend = current as AndroidPlaybackBackendRouting
        val decision = applyTo(
            playWhenReady = backend.playWhenReady,
            state = backend.playbackState,
            decide = decide,
            pause = { backend.pause() },
            play = {
                scope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                    try {
                        backend.play()
                    } catch (error: Exception) {
                        if (error !is kotlinx.coroutines.CancellationException) onResumeFailed(error)
                    }
                }
            },
            emit = emit,
            onResumeFailed = onResumeFailed
        )
        onDecided(decision, backend.type)
    }
}

