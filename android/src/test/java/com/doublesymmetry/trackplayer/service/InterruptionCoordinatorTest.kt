package com.doublesymmetry.trackplayer.service

import android.media.AudioManager
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
        var playFails = false
        val ducks = mutableListOf<RemoteDuckPayload?>()
        lateinit var coordinator: InterruptionCoordinator

        init {
            coordinator = InterruptionCoordinator(
                autoResume = { autoResume },
                focusRequester = focus,
                noisyReceiver = receiver,
                onInterruption = { decide ->
                    runTest {
                        ducks += coordinator.applyTo(
                            isPlaying = playing,
                            decide = decide,
                            pause = { playing = false },
                            play = { if (playFails) error("play failed") else playing = true }
                        )?.duck
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
        coordinator.applyTo(playing, { InterruptionDecision(InterruptionAction.RESUME, null) }, { playing = false }, { playing = true })
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
        // A late gain (delivered before the abandon took effect) does not resume.
        listener(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(harness.playing)
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
}
