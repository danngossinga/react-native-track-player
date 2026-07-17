package com.doublesymmetry.trackplayer.service

import androidx.test.platform.app.InstrumentationRegistry
import com.doublesymmetry.kotlinaudio.models.BufferConfig
import com.doublesymmetry.kotlinaudio.models.CacheConfig
import com.doublesymmetry.kotlinaudio.models.PlayerConfig
import com.doublesymmetry.kotlinaudio.players.QueuedAudioPlayer
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KotlinAudioMediaSessionControlInstrumentationTest {
    @Test
    fun testPinnedReflectionSuspendsAndResumesLiveKotlinAudioSession() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val player = QueuedAudioPlayer(
                instrumentation.targetContext,
                PlayerConfig(),
                BufferConfig(null, null, null, null),
                CacheConfig(null)
            )
            try {
                val control = KotlinAudioMediaSessionControl.from(player)
                assertTrue(control.isActive())

                control.deactivate()
                assertFalse(control.isActive())

                control.activate()
                assertTrue(control.isActive())
            } finally {
                player.destroy()
            }
        }
    }
}
