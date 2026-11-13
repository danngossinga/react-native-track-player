package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayWhenReadyPublicationTest {
    @Test
    fun publishesEachPlayAndPauseOnceAndAlwaysOnActivation() {
        val publication = PlayWhenReadyPublication()
        // The backend is activated: JS learns the value, even if it seems unchanged.
        assertTrue(publication.shouldPublish(false, force = true))
        // The forced value counts as sent.
        assertFalse(publication.shouldPublish(false))
        // play: playWhenReady flips, sent once whatever the number of state changes.
        assertTrue(publication.shouldPublish(true))
        assertFalse(publication.shouldPublish(true))
        // pause: flips back, sent once.
        assertTrue(publication.shouldPublish(false))
        assertFalse(publication.shouldPublish(false))
        // A new activation (backend swap) always republishes.
        assertTrue(publication.shouldPublish(false, force = true))
    }

    @Test
    fun publishesTheFirstValueEvenWithoutActivation() {
        assertTrue(PlayWhenReadyPublication().shouldPublish(true))
    }
}
