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
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "scripts/fixtures/interruption-scenarios.json").exists()) dir = dir.parentFile
        val text = File(checkNotNull(dir) { "scenarios not found" }, "scripts/fixtures/interruption-scenarios.json").readText()
        @Suppress("UNCHECKED_CAST")
        return parse(text)["scenarios"] as List<Map<String, Any?>>
    }

    // org.json is a stub in JVM tests: a small parser for this file's JSON.
    private fun parse(text: String): Map<String, Any?> {
        var i = 0
        fun ws() { while (i < text.length && text[i].isWhitespace()) i++ }
        fun value(): Any? {
            ws()
            return when (text[i]) {
                '{' -> { i++; val m = linkedMapOf<String, Any?>(); ws(); if (text[i] == '}') { i++; return m }
                    while (true) { ws(); val k = value() as String; ws(); i++; m[k] = value(); ws(); if (text[i++] == '}') break }; m }
                '[' -> { i++; val l = mutableListOf<Any?>(); ws(); if (text[i] == ']') { i++; return l }
                    while (true) { l += value(); ws(); if (text[i++] == ']') break }; l }
                '"' -> { i++; val sb = StringBuilder(); while (text[i] != '"') { if (text[i] == '\\') i++; sb.append(text[i++]) }; i++; sb.toString() }
                't' -> { i += 4; true }
                'f' -> { i += 5; false }
                'n' -> { i += 4; null }
                else -> { val s = i; while (i < text.length && (text[i].isDigit() || text[i] == '-' || text[i] == '.')) i++; text.substring(s, i).toDouble() }
            }
        }
        @Suppress("UNCHECKED_CAST")
        return value() as Map<String, Any?>
    }

    @Test
    fun followsTheSharedScenarios() {
        val all = scenarios()
        assertEquals(13, all.size)
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
                    "userPause" -> { policy.userCommand(); playing = false; InterruptionDecision(InterruptionAction.NONE, null) }
                    "userPlay" -> { policy.userCommand(); playing = true; InterruptionDecision(InterruptionAction.NONE, null) }
                    else -> error("unknown event $event in $id")
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
