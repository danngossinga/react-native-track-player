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
        // The current value is then kept (60000 ms unless the app set another one).
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
    fun theLoadLimitDefaultsToSixtySecondsASafetyCapBehindTheStallTimeout() {
        assertEquals(60_000L, DEFAULT_PREPARE_TIMEOUT_MS)
    }

    @Test
    fun theSettingKeepsTheDefaultUntilTheAppGivesAValidValue() {
        val setting = TimeoutSetting(DEFAULT_PREPARE_TIMEOUT_MS)
        assertEquals(60_000L, setting.milliseconds)
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
    fun theStandardReadinessWaitKeepsItsDefaultUntilTheAppSetsIt() {
        assertEquals("standardReadyTimeoutMs", STANDARD_READY_TIMEOUT_KEY)
        assertEquals(60_000L, DEFAULT_STANDARD_READY_TIMEOUT_MS)
        val setting = TimeoutSetting(DEFAULT_STANDARD_READY_TIMEOUT_MS)
        assertEquals(60_000L, setting.milliseconds)
        // A setting starts from the default it is given.
        assertEquals(1_234L, TimeoutSetting(1_234L).milliseconds)
        assertTrue(setting.apply(20_000.0))
        assertEquals(20_000L, setting.milliseconds)
    }

    @Test
    fun theStallTimeoutIsItsOwnOptionAndDefaultsToTenSeconds() {
        assertEquals("stallTimeoutMs", STALL_TIMEOUT_KEY)
        assertEquals(10_000L, DEFAULT_STALL_TIMEOUT_MS)
        val setting = TimeoutSetting(DEFAULT_STALL_TIMEOUT_MS)
        assertFalse(setting.apply(0.0))
        assertEquals(10_000L, setting.milliseconds)
        assertTrue(setting.apply(20_000.0))
        assertEquals(20_000L, setting.milliseconds)
    }

    @Test
    fun theInitialBitrateEstimateIsASetupOptionWithALowDefault() {
        assertEquals("initialBitrateEstimateBps", INITIAL_BITRATE_ESTIMATE_KEY)
        assertEquals(96_000L, DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS)
        val setting = BitrateSetting(DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS)
        assertFalse(setting.apply(-1.0))
        assertFalse(setting.apply("128000"))
        assertEquals(96_000L, setting.bitsPerSecond)
        assertTrue(setting.apply(64_000))
        assertEquals(64_000L, setting.bitsPerSecond)
    }

    @Test
    fun theIncomingStallGraceIsItsOwnOptionAndDefaultsToTwoSeconds() {
        assertEquals("incomingStallGraceMs", INCOMING_STALL_GRACE_KEY)
        assertEquals(2_000L, DEFAULT_INCOMING_STALL_GRACE_MS)
        val setting = TimeoutSetting(DEFAULT_INCOMING_STALL_GRACE_MS)
        assertFalse(setting.apply(0.0))
        assertTrue(setting.apply(4_000.0))
        assertEquals(4_000L, setting.milliseconds)
    }

    @Test
    fun thePlayStartAndStandardSeekLimitsAreTheIosOptionsWithTheSameDefaults() {
        assertEquals("playStartTimeoutMs", PLAY_START_TIMEOUT_KEY)
        assertEquals("standardSeekTimeoutMs", STANDARD_SEEK_TIMEOUT_KEY)
        assertEquals(60_000L, DEFAULT_PLAY_START_TIMEOUT_MS)
        assertEquals(60_000L, DEFAULT_STANDARD_SEEK_TIMEOUT_MS)
    }
}
