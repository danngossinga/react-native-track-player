package com.doublesymmetry.trackplayer.service

import android.os.Handler
import com.doublesymmetry.kotlinaudio.models.MediaType
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.Timeline
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.source.LoadEventInfo
import com.google.android.exoplayer2.source.MediaLoadData
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

    private fun item(index: Int) = TrackAudioItem(
        track = bare(Track::class.java),
        type = MediaType.DEFAULT,
        audioUrl = "https://example.invalid/$index.mp3",
        title = "Track $index",
        duration = 60_000L
    )

    /** A period as ExoPlayer's playlist makes it: its holder's uid with the item's period. */
    private fun period(item: Any, windowSequenceNumber: Long = 0L, holder: Any = Any()) =
        MediaSource.MediaPeriodId(Pair(holder, item), windowSequenceNumber)

    private fun loadCompleted(listener: StartLowLoadListener, period: MediaSource.MediaPeriodId, dataType: Int) =
        listener.onLoadCompleted(
            AnalyticsListener.EventTime(0L, Timeline.EMPTY, 0, period, 0L, Timeline.EMPTY, 0, period, 0L, 0L),
            bare(LoadEventInfo::class.java),
            MediaLoadData(dataType)
        )

    /** Selections for [periods] from one factory; returns each one's meter. */
    private fun selections(loads: OwnMediaLoadRegistry, shared: BandwidthMeter, vararg periods: MediaSource.MediaPeriodId): List<BandwidthMeter> {
        val seen = mutableListOf<BandwidthMeter>()
        val factory = StartLowTrackSelectionFactory({ DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, loads) { _, meter, _, _ ->
            seen += meter
            emptyArray()
        }
        @Suppress("UNCHECKED_CAST")
        val timeline = bare(Class.forName("com.google.android.exoplayer2.source.SinglePeriodTimeline") as Class<Timeline>)
        periods.forEach { factory.createTrackSelections(emptyArray<ExoTrackSelection.Definition>(), shared, it, timeline) }
        return seen
    }

    @Test
    fun theNextTrackPreparedAheadStartsLowUntilItsOwnMediaIsLoaded() {
        val shared = FakeMeter(96_000L)
        val loads = OwnMediaLoadRegistry()
        val listener = StartLowLoadListener(loads)
        val playing = period(item(0))
        val next = period(item(1))
        val nextMeter = selections(loads, shared, next).single()
        // Its own playlist (manifest) loads before the first estimate: not a measurement.
        loadCompleted(listener, next, C.DATA_TYPE_MANIFEST)
        // The playing track keeps downloading: the shared meter measures a fast network.
        shared.estimate = 4_000_000L
        loadCompleted(listener, playing, C.DATA_TYPE_MEDIA)
        assertEquals(96_000L, nextMeter.bitrateEstimate)
        // Its own first media segment loaded: it follows the meter from then on.
        loadCompleted(listener, next, C.DATA_TYPE_MEDIA)
        assertEquals(4_000_000L, nextMeter.bitrateEstimate)
        shared.estimate = 1_000_000L
        assertEquals(1_000_000L, nextMeter.bitrateEstimate)
    }

    @Test
    fun twoEqualItemsInTheQueueAreMeasuredApart() {
        val shared = FakeMeter(4_000_000L)
        val loads = OwnMediaLoadRegistry()
        val first = item(0)
        val duplicate = first.copy()
        assertEquals(first, duplicate)
        val firstPeriod = period(first)
        val duplicatePeriod = period(duplicate)
        val (firstMeter, duplicateMeter) = selections(loads, shared, firstPeriod, duplicatePeriod)
        StartLowLoadListener(loads).let { loadCompleted(it, firstPeriod, C.DATA_TYPE_MEDIA) }
        assertEquals(4_000_000L, firstMeter.bitrateEstimate)
        assertEquals(96_000L, duplicateMeter.bitrateEstimate)
    }

    @Test
    fun aReplayedTrackStartsLowAgain() {
        val shared = FakeMeter(4_000_000L)
        val loads = OwnMediaLoadRegistry()
        val track = item(0)
        val holder = Any()
        val firstPlay = period(track, windowSequenceNumber = 1L, holder = holder)
        val replay = period(track, windowSequenceNumber = 2L, holder = holder)
        val firstMeter = selections(loads, shared, firstPlay).single()
        loadCompleted(StartLowLoadListener(loads), firstPlay, C.DATA_TYPE_MEDIA)
        assertEquals(4_000_000L, firstMeter.bitrateEstimate)
        // The same item played again (a new period): it starts low again.
        val replayMeter = selections(loads, shared, replay).single()
        assertEquals(96_000L, replayMeter.bitrateEstimate)
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
