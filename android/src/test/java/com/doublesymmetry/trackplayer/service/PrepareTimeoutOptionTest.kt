package com.doublesymmetry.trackplayer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

class PrepareTimeoutOptionTest {
    @Test
    fun takesAPositiveNumberOfMilliseconds() {
        assertEquals(12_000L, timeoutOptionFrom(12_000.0))
        assertEquals(8_000L, timeoutOptionFrom(8_000))
        assertEquals(1L, timeoutOptionFrom(1.9))
        assertEquals(2_147_483_646L, timeoutOptionFrom(2_147_483_646.0))
    }

    @Test
    fun ignoresAnythingElse() {
        // The current value is then kept (5000 ms unless the app set another one).
        assertNull(timeoutOptionFrom(null))
        assertNull(timeoutOptionFrom("12000"))
        assertNull(timeoutOptionFrom(true))
        assertNull(timeoutOptionFrom(0.0))
        assertNull(timeoutOptionFrom(-5_000.0))
        assertNull(timeoutOptionFrom(0.5))
        assertNull(timeoutOptionFrom(Double.NaN))
        assertNull(timeoutOptionFrom(Double.POSITIVE_INFINITY))
        assertNull(timeoutOptionFrom(1e30))
        // The same upper bound as iOS.
        assertNull(timeoutOptionFrom(2_147_483_647.0))
    }

    @Test
    fun isReadFromTheOptionTheAppGives() {
        // The key of setupPlayer / updateOptions, as on iOS and in the TypeScript options.
        assertEquals("prepareTimeoutMs", PREPARE_TIMEOUT_KEY)
    }

    @Test
    fun defaultsToFiveSeconds() {
        assertEquals(5_000L, DEFAULT_PREPARE_TIMEOUT_MS)
    }

    @Test
    fun theSettingKeepsTheDefaultUntilTheAppGivesAValidValue() {
        val setting = TimeoutSetting(DEFAULT_PREPARE_TIMEOUT_MS)
        assertEquals(5_000L, setting.milliseconds)
        assertTrue(setting.apply(15_000.0))
        assertEquals(15_000L, setting.milliseconds)
        // An invalid value keeps the current one; a new valid value replaces it.
        assertFalse(setting.apply("30000"))
        assertFalse(setting.apply(null))
        assertEquals(15_000L, setting.milliseconds)
        assertTrue(setting.apply(30_000.0))
        assertEquals(30_000L, setting.milliseconds)
    }

    @Test
    fun theStandardReadinessWaitKeepsItsOldValueUntilTheAppSetsIt() {
        assertEquals("standardReadyTimeoutMs", STANDARD_READY_TIMEOUT_KEY)
        assertEquals(5_000L, DEFAULT_STANDARD_READY_TIMEOUT_MS)
        val setting = TimeoutSetting(DEFAULT_STANDARD_READY_TIMEOUT_MS)
        assertEquals(5_000L, setting.milliseconds)
        assertTrue(setting.apply(20_000.0))
        assertEquals(20_000L, setting.milliseconds)
    }
}
