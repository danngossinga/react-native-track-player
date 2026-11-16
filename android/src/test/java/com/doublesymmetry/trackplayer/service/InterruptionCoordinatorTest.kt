package com.doublesymmetry.trackplayer.service

import android.media.AudioManager
import com.doublesymmetry.kotlinaudio.models.AudioContentType
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import androidx.media.AudioAttributesCompat
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The service's interruption handling on both backends (DJE-204/205/206), with the system's audio
 * focus and headphones receiver faked: one focus, requested at the user's play and at a resume,
 * never before; given up on stop, reset, a permanent loss and destroy.
 */
class InterruptionCoordinatorTest {
    private class FakeFocus(var grant: Boolean = true) : AudioFocusRequester {
        var requests = 0
        var abandons = 0
        var listener: ((Int) -> Unit)? = null

        override fun request(onChange: (Int) -> Unit): Boolean {
            requests += 1
            listener = onChange
            return grant
        }

        override fun abandon() {
            abandons += 1
        }

        fun change(focusChange: Int) = checkNotNull(listener) { "no focus request" }(focusChange)
    }

    private class FakeReceiver : NoisyReceiverRegistrar {
        var onNoisy: (() -> Unit)? = null
        var unregisters = 0

        override fun register(onNoisy: () -> Unit) {
            this.onNoisy = onNoisy
        }

        override fun unregister() {
            unregisters += 1
            onNoisy = null
        }
    }

    /** A backend with the service's applyInterruption: runs every decision on it at once. */
    private class Harness(autoResume: Boolean = true) {
        val focus = FakeFocus()
        val receiver = FakeReceiver()
        var playing = false
        var state = AudioPlayerState.PLAYING
        var playFails = false
        val ducks = mutableListOf<RemoteDuckPayload?>()
        /** The remote-duck payloads emitted when each pause ran. */
        val ducksAtPause = mutableListOf<Int>()
        /** The remote-duck payloads emitted when each resumed play started. */
        val ducksAtPlay = mutableListOf<Int>()
        lateinit var coordinator: InterruptionCoordinator

        init {
            coordinator = InterruptionCoordinator(
                autoResume = { autoResume },
                focusRequester = focus,
                noisyReceiver = receiver,
                onInterruption = { decide ->
                    runTest {
                        val emitted = mutableListOf<RemoteDuckPayload>()
                        coordinator.applyTo(
                            playWhenReady = playing,
                            state = state,
                            decide = decide,
                            pause = {
                                ducksAtPause += emitted.size
                                playing = false
                            },
                            play = {
                                ducksAtPlay += emitted.size
                                if (playFails) error("play failed") else playing = true
                            },
                            emit = { emitted += it }
                        )
                        ducks += emitted.singleOrNull()
                    }
                }
            )
            coordinator.start()
        }

        fun userPlay() {
            coordinator.userPlay()
            playing = true
        }
    }

    @Test
    fun theFocusIsRequestedAtTheUsersPlayOnlyAndOnce() {
        val harness = Harness()
        // Setup and a paused player take no focus (KotlinAudio used to take it at READY).
        assertEquals(0, harness.focus.requests)
        harness.coordinator.userPause()
        assertEquals(0, harness.focus.requests)

        harness.userPlay()
        assertEquals(1, harness.focus.requests)
        assertTrue(harness.coordinator.focus.isHeld)
        harness.userPlay()
        assertEquals(1, harness.focus.requests)
    }

    @Test
    fun aPermanentLossGivesTheFocusUpAndTheNextPlayRequestsItAgain() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS)
        assertEquals(1, harness.focus.abandons)
        assertFalse(harness.coordinator.focus.isHeld)
        assertFalse(harness.playing)
        assertEquals(RemoteDuckPayload(paused = true, permanent = true), harness.ducks.last())

        harness.userPlay()
        assertEquals(2, harness.focus.requests)
        assertTrue(harness.coordinator.focus.isHeld)
    }

    @Test
    fun aPlayDuringATransientLossRequestsTheFocusAgain() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        assertFalse(harness.coordinator.focus.isHeld)
        assertEquals(0, harness.focus.abandons)

        harness.userPlay()
        assertEquals(2, harness.focus.requests)
    }

    @Test
    fun aRefusedRequestIsNotHeld() {
        val harness = Harness()
        harness.focus.grant = false
        assertFalse(harness.coordinator.userPlay())
        assertFalse(harness.coordinator.focus.isHeld)
        // Nothing registered: nothing to give up.
        harness.coordinator.userStop()
        assertEquals(0, harness.focus.abandons)
    }

    @Test
    fun aCanDuckLossPausesAndTheGainResumesWithTheFocusRequested() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        assertFalse(harness.playing)
        assertEquals(RemoteDuckPayload(paused = true, permanent = false), harness.ducks.last())

        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertTrue(harness.playing)
        assertTrue(harness.coordinator.focus.isHeld)
        assertEquals(RemoteDuckPayload(paused = false, permanent = false), harness.ducks.last())
    }

    @Test
    fun aResumeAfterTheFocusWasGivenUpRequestsItAgain() = runTest {
        val focus = FakeFocus()
        var playing = true
        val coordinator = InterruptionCoordinator({ true }, focus, FakeReceiver()) { }
        coordinator.applyTo(playing, AudioPlayerState.PAUSED, { InterruptionDecision(InterruptionAction.RESUME, null) }, { playing = false }, { playing = true }, {})
        assertEquals(1, focus.requests)
        assertTrue(coordinator.focus.isHeld)
    }

    @Test
    fun theGainIsReportedEvenWhenTheResumeFails() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        harness.playFails = true
        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(harness.playing)
        assertEquals(RemoteDuckPayload(paused = false, permanent = false), harness.ducks.last())
    }

    @Test
    fun stopAndResetGiveTheFocusUpAndCancelTheResume() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        val listener = harness.focus.listener!!
        harness.coordinator.userStop()
        assertEquals(1, harness.focus.abandons)
        assertFalse(harness.coordinator.focus.isHeld)
        // A late gain (delivered before the abandon took effect) does not resume, nor make the
        // given-up focus held: the next play requests it again.
        listener(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(harness.playing)
        assertFalse(harness.coordinator.focus.isHeld)
        harness.userPlay()
        assertEquals(2, harness.focus.requests)
    }

    @Test
    fun anInterruptionAfterTheQueueEndedNeitherPausesNorResumes() {
        val harness = Harness()
        harness.userPlay()
        // The queue ended: playWhenReady stays on, but nothing plays.
        harness.state = AudioPlayerState.ENDED
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        assertTrue(harness.playing)
        assertEquals(RemoteDuckPayload(paused = true, permanent = false), harness.ducks.last())
        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertTrue(harness.ducksAtPlay.isEmpty())
        assertEquals(RemoteDuckPayload(paused = false, permanent = false), harness.ducks.last())
    }

    @Test
    fun theGainIsReportedBeforeTheResumedPlayIsAwaitedAsOnIos() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertEquals(listOf(1), harness.ducksAtPlay)
    }

    @Test
    fun theFocusRequestCarriesTheAppsContentType() {
        assertEquals(AudioAttributesCompat.CONTENT_TYPE_MUSIC, focusContentTypeOf(AudioContentType.MUSIC))
        assertEquals(AudioAttributesCompat.CONTENT_TYPE_SPEECH, focusContentTypeOf(AudioContentType.SPEECH))
        assertEquals(AudioAttributesCompat.CONTENT_TYPE_SONIFICATION, focusContentTypeOf(AudioContentType.SONIFICATION))
        assertEquals(AudioAttributesCompat.CONTENT_TYPE_MOVIE, focusContentTypeOf(AudioContentType.MOVIE))
        assertEquals(AudioAttributesCompat.CONTENT_TYPE_UNKNOWN, focusContentTypeOf(AudioContentType.UNKNOWN))
    }

    @Test
    fun aUserPauseDuringAnInterruptionCancelsTheResume() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        harness.coordinator.userPause()
        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(harness.playing)
    }

    @Test
    fun headphonesUnpluggedPauseWithNoResume() {
        val harness = Harness()
        harness.userPlay()
        harness.receiver.onNoisy!!()
        assertFalse(harness.playing)
        assertNull(harness.ducks.last())
        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(harness.playing)
    }

    @Test
    fun destroyUnregistersTheReceiverAndGivesTheFocusUp() {
        val harness = Harness()
        harness.userPlay()
        harness.coordinator.destroy()
        assertEquals(1, harness.receiver.unregisters)
        assertNull(harness.receiver.onNoisy)
        assertEquals(1, harness.focus.abandons)
        assertFalse(harness.coordinator.focus.isHeld)
    }

    @Test
    fun aUserPlayDuringAnInterruptionCancelsItsResume() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        // The user plays again during the interruption: the gain does not play a second time.
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertTrue(harness.ducksAtPlay.isEmpty())
    }

    @Test
    fun theRemoteDuckOfALossIsEmittedOnceThePauseIsDone() {
        val harness = Harness()
        harness.userPlay()
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        assertEquals(listOf(0), harness.ducksAtPause)
        assertEquals(RemoteDuckPayload(paused = true, permanent = false), harness.ducks.last())
    }

    @Test
    fun aPlayTheSystemRefusesDoesNotStartAndRejectsWithAudioFocusRefused() = runTest {
        val focus = FakeFocus(grant = false)
        val coordinator = InterruptionCoordinator({ true }, focus, FakeReceiver()) { }
        val calls = mutableListOf<String>()
        val refused = runCatching {
            coordinator.playOrRefuse(play = { calls += "play" }, refuse = { calls += "pause" })
        }
        assertEquals(AUDIO_FOCUS_REFUSED, (refused.exceptionOrNull() as com.doublesymmetry.trackplayer.utils.RejectionException).code)
        // Nothing plays; the backend is paused (playWhenReady off, silent).
        assertEquals(listOf("pause"), calls)
        assertFalse(coordinator.focus.isHeld)
        // Nothing retries by itself; a later play the system allows plays.
        focus.grant = true
        coordinator.playOrRefuse(play = { calls += "play" }, refuse = { calls += "pause" })
        assertEquals(listOf("pause", "play"), calls)
        assertEquals(2, focus.requests)
    }

    @Test
    fun aResumeTheSystemRefusesDoesNotPlayAndIsReported() = runTest {
        val focus = FakeFocus(grant = false)
        val coordinator = InterruptionCoordinator({ true }, focus, FakeReceiver()) { }
        val failures = mutableListOf<Throwable>()
        val ducks = mutableListOf<RemoteDuckPayload>()
        var played = false
        coordinator.applyTo(
            false, AudioPlayerState.PAUSED,
            { InterruptionDecision(InterruptionAction.RESUME, RemoteDuckPayload(paused = false, permanent = false)) },
            { }, { played = true }, { ducks += it }, { failures += it }
        )
        assertFalse(played)
        assertEquals(listOf(AUDIO_FOCUS_REFUSED), failures.map { (it as com.doublesymmetry.trackplayer.utils.RejectionException).code })
        assertEquals(listOf(RemoteDuckPayload(paused = false, permanent = false)), ducks)
    }
    @Test
    fun aSkipAfterTheFocusWasLostWhileTheQueueEndedIsRefusedAndSilent() {
        val harness = Harness()
        harness.userPlay()
        // The queue ended (playWhenReady stays on), then a call takes the focus: nothing paused.
        harness.state = AudioPlayerState.ENDED
        harness.focus.change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        assertTrue(harness.playing)
        harness.focus.grant = false
        val calls = mutableListOf<String>()
        var allowed = true
        runTest {
            allowed = harness.coordinator.runStartingCommand(
                playWhenReady = harness.playing,
                state = harness.state,
                pause = { calls += "pause"; harness.playing = false },
                command = { calls += "skip" }
            )
        }
        // Refused: paused before the skip runs, so the skipped track does not start.
        assertFalse(allowed)
        assertEquals(listOf("pause", "skip"), calls)
        assertFalse(harness.playing)
        assertEquals(2, harness.focus.requests)
        // The user's last intent is to play: the call's end resumes the skipped track.
        harness.state = AudioPlayerState.PAUSED
        harness.focus.grant = true
        harness.focus.change(AudioManager.AUDIOFOCUS_GAIN)
        assertTrue(harness.playing)
    }

    @Test
    fun aStartingCommandThatStartsNothingRequestsNothing() = runTest {
        val focus = FakeFocus(grant = false)
        val coordinator = InterruptionCoordinator({ true }, focus, FakeReceiver()) { }
        var ran = 0
        // Playing (the focus is ours) or not asked to play: no request, the command runs.
        assertTrue(coordinator.runStartingCommand(true, AudioPlayerState.PLAYING, { error("paused") }) { ran += 1 })
        assertTrue(coordinator.runStartingCommand(false, AudioPlayerState.ENDED, { error("paused") }) { ran += 1 })
        assertEquals(2, ran)
        assertEquals(0, focus.requests)
        // Asked to play after the queue ended, with the focus still held: no new request.
        focus.grant = true
        coordinator.userPlay()
        assertTrue(coordinator.runStartingCommand(true, AudioPlayerState.ENDED, { error("paused") }) { ran += 1 })
        assertEquals(1, focus.requests)
        assertEquals(3, ran)
        for (state in AudioPlayerState.values()) {
            assertEquals("$state", state in INTERRUPTION_FINISHED_STATES, commandStartsPlayback(true, state))
            assertFalse("$state", commandStartsPlayback(false, state))
        }
    }

    @Test
    fun aRefusedStartingCommandThatFailsByItselfKeepsItsOwnFailure() = runTest {
        val coordinator = InterruptionCoordinator({ true }, FakeFocus(grant = false), FakeReceiver()) { }
        var paused = false
        val failure = runCatching {
            coordinator.runStartingCommand(true, AudioPlayerState.ENDED, { paused = true }) { error("load failed") }
        }.exceptionOrNull()
        assertEquals("load failed", failure?.message)
        assertTrue(paused)
    }
}
