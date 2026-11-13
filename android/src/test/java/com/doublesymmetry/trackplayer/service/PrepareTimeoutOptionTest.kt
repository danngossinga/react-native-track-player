package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PrepareTimeoutOptionTest {
    @Test
    fun takesAPositiveNumberOfMilliseconds() {
        assertEquals(12_000L, prepareTimeoutFrom(12_000.0))
        assertEquals(8_000L, prepareTimeoutFrom(8_000))
        assertEquals(1L, prepareTimeoutFrom(1.9))
    }

    @Test
    fun ignoresAnythingElse() {
        // The current value is then kept (5000 ms unless the app set another one).
        assertNull(prepareTimeoutFrom(null))
        assertNull(prepareTimeoutFrom("12000"))
        assertNull(prepareTimeoutFrom(true))
        assertNull(prepareTimeoutFrom(0.0))
        assertNull(prepareTimeoutFrom(-5_000.0))
        assertNull(prepareTimeoutFrom(0.5))
        assertNull(prepareTimeoutFrom(Double.NaN))
        assertNull(prepareTimeoutFrom(Double.POSITIVE_INFINITY))
        assertNull(prepareTimeoutFrom(1e30))
    }

    @Test
    fun defaultsToFiveSeconds() {
        assertEquals(5_000L, DEFAULT_PREPARE_TIMEOUT_MS)
    }
}
