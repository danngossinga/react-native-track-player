package com.doublesymmetry.trackplayer.service

import android.media.AudioManager
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

class InterruptionPolicyTest {
    private fun scenarios(): List<Map<String, Any?>> {
        // The JSON the iOS XCTests read too.
        @Suppress("UNCHECKED_CAST")
        return readSharedFixture("scripts/fixtures/interruption-scenarios.json")["scenarios"] as List<Map<String, Any?>>
    }

    @Test
    fun followsTheSharedScenarios() {
        val all = scenarios()
        assertEquals(22, all.size)
        for (scenario in all) {
            val id = scenario["id"] as String
            val autoResume = scenario["autoResume"] as Boolean
            var playing = scenario["playing"] as Boolean
            // The backend's state: an ended queue does not count as playing (same rule as iOS).
            val state = AudioPlayerState.valueOf(((scenario["state"] as String?) ?: "playing").uppercase())
            fun isPlaying() = interruptionCountsAsPlaying(playing, state)
            val policy = InterruptionPolicy { autoResume }
            @Suppress("UNCHECKED_CAST")
            for (step in scenario["steps"] as List<Map<String, Any?>>) {
                val event = step["event"] as String
                val decision = when (event) {
                    "began" -> policy.began(isPlaying())
                    "ended" -> policy.ended(step["shouldResume"] as Boolean)
                    "lostPermanently" -> policy.lostPermanently(isPlaying())
                    "noisy" -> policy.noisy(isPlaying())
                    "userPause" -> { policy.userPause(); playing = false; InterruptionDecision(InterruptionAction.NONE, null) }
                    "userStop" -> { policy.userStop(); playing = false; InterruptionDecision(InterruptionAction.NONE, null) }
                    "userPlay" -> {
                        // The system's answer (Android: the focus request; iOS: the activation).
                        val granted = step["granted"] as Boolean? ?: true
                        val decision = policy.userPlay(activate = { granted })
                        assertEquals("$id userPlay", step["action"] == "refused", decision == UserPlayDecision.REFUSED)
                        if (decision == UserPlayDecision.PLAY) playing = true
                        InterruptionDecision(InterruptionAction.NONE, null)
                    }
                    else -> error("unknown event $event in $id")
                }
                if (event == "userPlay") {
                    assertNull("$id $event", decision.duck)
                    continue
                }
                val expected = when (step["action"]) {
                    "pause" -> InterruptionAction.PAUSE
                    "resume" -> InterruptionAction.RESUME
                    else -> InterruptionAction.NONE
                }
                assertEquals("$id $event", expected, decision.action)
                @Suppress("UNCHECKED_CAST")
                val duck = step["duck"] as Map<String, Any?>?
                assertEquals("$id $event", duck?.let { RemoteDuckPayload(it["paused"] as Boolean, it["permanent"] as Boolean) }, decision.duck)
                if (decision.action == InterruptionAction.PAUSE) playing = false
                if (decision.action == InterruptionAction.RESUME) playing = true
            }
        }
    }

    @Test
    fun audioFocusChangesAreInterruptionEvents() {
        val policy = InterruptionPolicy { true }
        // A call (transient loss) or a can-duck loss pauses; the gain resumes.
        assertEquals(InterruptionAction.PAUSE, policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, isPlaying = true)?.action)
        assertEquals(InterruptionAction.RESUME, policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPlaying = false)?.action)
        assertEquals(InterruptionAction.PAUSE, policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, isPlaying = true)?.action)
        assertEquals(InterruptionAction.RESUME, policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPlaying = false)?.action)
        // A permanent loss pauses for good.
        assertEquals(RemoteDuckPayload(paused = true, permanent = true), policy.onFocusChange(AudioManager.AUDIOFOCUS_LOSS, isPlaying = true)?.duck)
        assertEquals(InterruptionAction.NONE, policy.onFocusChange(AudioManager.AUDIOFOCUS_GAIN, isPlaying = false)?.action)
        assertNull(policy.onFocusChange(12345, isPlaying = true))
    }

    @Test
    fun readsTheOptionAtTheEnd() {
        var autoResume = false
        val policy = InterruptionPolicy { autoResume }
        policy.began(isPlaying = true)
        autoResume = true
        assertEquals(InterruptionAction.RESUME, policy.ended(shouldResume = true).action)
    }

    @Test
    fun onlyAnActiveTrackThatWasAskedToPlayCountsAsPlaying() {
        val playingStates = AudioPlayerState.values().filter { it !in INTERRUPTION_FINISHED_STATES }
        assertEquals(
            setOf(AudioPlayerState.IDLE, AudioPlayerState.ENDED, AudioPlayerState.ERROR, AudioPlayerState.STOPPED),
            INTERRUPTION_FINISHED_STATES
        )
        for (state in AudioPlayerState.values()) {
            assertEquals("$state", state in playingStates, interruptionCountsAsPlaying(true, state))
            assertEquals("$state", false, interruptionCountsAsPlaying(false, state))
        }
    }
}
