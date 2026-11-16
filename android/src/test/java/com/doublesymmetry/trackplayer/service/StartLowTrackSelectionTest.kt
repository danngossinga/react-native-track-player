package com.doublesymmetry.trackplayer.service

import android.os.Handler
import com.google.android.exoplayer2.Timeline
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.trackselection.ExoTrackSelection
import com.google.android.exoplayer2.upstream.BandwidthMeter
import com.google.android.exoplayer2.upstream.TransferListener
import org.junit.Assert.assertEquals
import org.junit.Test

class StartLowTrackSelectionTest {
    private class FakeMeter(var estimate: Long) : BandwidthMeter {
        override fun getBitrateEstimate(): Long = estimate
        override fun getTransferListener(): TransferListener? = null
        override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) = Unit
        override fun removeEventListener(eventListener: BandwidthMeter.EventListener) = Unit
    }

    private fun <T> bare(type: Class<T>): T {
        val unsafe = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        @Suppress("UNCHECKED_CAST")
        return unsafe.javaClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, type) as T
    }

    @Test
    fun aTrackSeesTheStartEstimateUntilTheMeterMeasuresAgain() {
        // The standard player's meter already measured a fast network on the previous track.
        val shared = FakeMeter(4_000_000L)
        val meter = StartLowBandwidthMeter(shared, DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS)
        assertEquals(96_000L, meter.bitrateEstimate)
        assertEquals(96_000L, meter.bitrateEstimate)
        // A new measurement: the track follows it from then on.
        shared.estimate = 1_500_000L
        assertEquals(1_500_000L, meter.bitrateEstimate)
        shared.estimate = 4_000_000L
        assertEquals(4_000_000L, meter.bitrateEstimate)
    }

    @Test
    fun theNextTrackPreparedAheadStartsLowUntilItsOwnTransferIsMeasured() {
        val shared = FakeMeter(96_000L)
        val transfers = OwnTransferRegistry()
        val playing = Any()
        val next = Any()
        var item: Any? = next
        val seen = mutableListOf<BandwidthMeter>()
        val factory = StartLowTrackSelectionFactory({ DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, transfers, { _, _ -> item }) { _, meter, _, _ ->
            seen += meter
            emptyArray()
        }
        val period = bare(MediaSource.MediaPeriodId::class.java)
        @Suppress("UNCHECKED_CAST")
        val timeline = bare(Class.forName("com.google.android.exoplayer2.source.SinglePeriodTimeline") as Class<Timeline>)
        factory.createTrackSelections(emptyArray<ExoTrackSelection.Definition>(), shared, period, timeline)
        val nextMeter = seen.single()
        // The playing track keeps downloading: the shared meter measures a fast network.
        shared.estimate = 4_000_000L
        transfers.transferEnded(playing)
        assertEquals(96_000L, nextMeter.bitrateEstimate)
        // The next track's own first transfer ends: it follows the meter from then on.
        transfers.transferEnded(next)
        assertEquals(4_000_000L, nextMeter.bitrateEstimate)
        shared.estimate = 1_000_000L
        assertEquals(1_000_000L, nextMeter.bitrateEstimate)
    }

    @Test
    fun everyTrackSelectionReadsTheCurrentSetting() {
        var setting = DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS
        val seen = mutableListOf<Long>()
        val factory = StartLowTrackSelectionFactory({ setting }, adaptive = { _, meter, _, _ ->
            seen += meter.bitrateEstimate
            emptyArray()
        })
        val shared = FakeMeter(4_000_000L)
        val period = bare(MediaSource.MediaPeriodId::class.java)
        @Suppress("UNCHECKED_CAST")
        val timeline = bare(Class.forName("com.google.android.exoplayer2.source.SinglePeriodTimeline") as Class<Timeline>)
        factory.createTrackSelections(emptyArray<ExoTrackSelection.Definition>(), shared, period, timeline)
        // updateOptions: the next track starts from the new value.
        setting = 48_000L
        factory.createTrackSelections(emptyArray<ExoTrackSelection.Definition>(), shared, period, timeline)
        assertEquals(listOf(96_000L, 48_000L), seen)
    }
}
