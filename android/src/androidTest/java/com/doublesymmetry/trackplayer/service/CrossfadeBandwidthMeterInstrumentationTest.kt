package com.doublesymmetry.trackplayer.service

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test

class CrossfadeBandwidthMeterInstrumentationTest {
    @Test
    fun aCrossfadePlayerStartsFromTheAppsInitialBitrateEstimate() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Before any measurement, the meter reports the app's value, which adaptive selection uses.
        for (estimate in listOf(DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS, 64_000L, 320_000L)) {
            assertEquals(estimate, crossfadeBandwidthMeter(context, estimate).bitrateEstimate)
        }
    }

    @Test
    fun eachCrossfadeTrackStartsFromTheCurrentEstimateOnARealMeter() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var setting = DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS
        val meter = PerTrackBandwidthMeter({ setting }) { crossfadeBandwidthMeter(context, it) }
        assertEquals(DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS, meter.bitrateEstimate)
        setting = 48_000L
        assertEquals(48_000L, meter.startTrack())
        assertEquals(48_000L, meter.bitrateEstimate)
    }
}
