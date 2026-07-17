package com.doublesymmetry.trackplayer.service

import android.support.v4.media.session.MediaSessionCompat
import org.junit.Assert.assertEquals
import org.junit.Test

class KotlinAudioMediaSessionControlTest {
    @Test
    fun pinnedKotlinAudioFieldStillMatchesTheRuntimeContract() {
        val field = KotlinAudioMediaSessionControl.resolvePinnedField()

        assertEquals(KotlinAudioMediaSessionControl.PINNED_OWNER_CLASS, field.declaringClass.name)
        assertEquals(KotlinAudioMediaSessionControl.PINNED_FIELD_NAME, field.name)
        assertEquals(MediaSessionCompat::class.java, field.type)
    }
}
