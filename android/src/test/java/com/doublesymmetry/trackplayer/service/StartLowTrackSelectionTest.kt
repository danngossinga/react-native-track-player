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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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
    fun aTrackKeepsTheSettingUntilTheMeterHasReallyMeasured() {
        // The standard player's meter is built with an initial estimate (here an older setting);
        // until it has really measured (its own thresholds) it keeps reporting it.
        val unmeasured = 500_000L
        val meter = FakeMeter(unmeasured)
        val loads = OwnMediaLoadRegistry()
        val track = period(item(0))
        val seen = mutableListOf<BandwidthMeter>()
        val factory = StartLowTrackSelectionFactory({ DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, loads, unmeasured) { _, m, _, _ ->
            seen += m
            emptyArray()
        }
        @Suppress("UNCHECKED_CAST")
        val timeline = bare(Class.forName("com.google.android.exoplayer2.source.SinglePeriodTimeline") as Class<Timeline>)
        factory.createTrackSelections(emptyArray<ExoTrackSelection.Definition>(), meter, track, timeline)
        val trackMeter = seen.single()
        // Its own first small segment loaded, but the meter still reports its default: the track
        // keeps the current setting, not the meter's default.
        loadCompleted(StartLowLoadListener(loads), track, C.DATA_TYPE_MEDIA)
        assertEquals(DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS, trackMeter.bitrateEstimate)
        // The meter measured: the track follows it.
        meter.estimate = 2_000_000L
        assertEquals(2_000_000L, trackMeter.bitrateEstimate)
    }

    @Test
    fun periodsThatLeftTheTimelineAreForgotten() {
        val loads = OwnMediaLoadRegistry()
        val kept = period(item(0))
        val removed = period(item(1))
        val listener = StartLowLoadListener(loads)
        loadCompleted(listener, kept, C.DATA_TYPE_MEDIA)
        loadCompleted(listener, removed, C.DATA_TYPE_MEDIA)
        assertEquals(2, loads.size)
        val timeline = object : Timeline() {
            override fun getWindowCount() = 1
            override fun getWindow(windowIndex: Int, window: Window, defaultPositionProjectionUs: Long) = window
            override fun getPeriodCount() = 1
            override fun getPeriod(periodIndex: Int, period: Period, setIds: Boolean) = period
            override fun getIndexOfPeriod(uid: Any) = if (uid == kept.periodUid) 0 else C.INDEX_UNSET
            override fun getUidOfPeriod(periodIndex: Int): Any = kept.periodUid
        }
        listener.onTimelineChanged(
            AnalyticsListener.EventTime(0L, timeline, 0, null, 0L, timeline, 0, null, 0L, 0L),
            0
        )
        assertEquals(1, loads.size)
        assertTrue(loads.hasMeasured(kept))
        assertFalse(loads.hasMeasured(removed))
    }

    @Test
    fun theStandardMeterAndItsSelectionsShareOneUnmeasuredValue() {
        // Not the default (96 kbps): a meter built from the default would not pass.
        var setting = 64_000L
        val seen = mutableListOf<BandwidthMeter>()
        val startLow = StandardStartLow({ setting }, { bps -> FakeMeter(bps) }) { _, m, _, _ ->
            seen += m
            emptyArray()
        }
        // The meter is built with the setting as its unmeasured estimate.
        assertEquals(64_000L, startLow.meter.bitrateEstimate)
        // updateOptions: the next track starts from the new value; the meter (not measured yet)
        // still reports the one it was built with.
        setting = 48_000L
        val track = period(item(0))
        @Suppress("UNCHECKED_CAST")
        val timeline = bare(Class.forName("com.google.android.exoplayer2.source.SinglePeriodTimeline") as Class<Timeline>)
        startLow.selectionFactory.createTrackSelections(emptyArray<ExoTrackSelection.Definition>(), startLow.meter, track, timeline)
        loadCompleted(startLow.loadListener, track, C.DATA_TYPE_MEDIA)
        // Its own load, but the meter has not measured: the current setting, not the meter's value.
        assertEquals(48_000L, seen.single().bitrateEstimate)
        (startLow.meter as FakeMeter).estimate = 3_000_000L
        assertEquals(3_000_000L, seen.single().bitrateEstimate)
    }

    @Test
    fun earlierPlaysOfTheItemNowPlayingAreForgotten() {
        val loads = OwnMediaLoadRegistry()
        val listener = StartLowLoadListener(loads)
        val track = item(0)
        val holder = Any()
        val first = period(track, windowSequenceNumber = 1L, holder = holder)
        val second = period(track, windowSequenceNumber = 2L, holder = holder)
        // Another item, played earlier in the queue: not retired by this item's replay.
        val other = period(item(1), windowSequenceNumber = 0L)
        loadCompleted(listener, other, C.DATA_TYPE_MEDIA)
        loadCompleted(listener, first, C.DATA_TYPE_MEDIA)
        loadCompleted(listener, second, C.DATA_TYPE_MEDIA)
        // Repeat-one: the second play began; the first one ended.
        listener.onPositionDiscontinuity(
            AnalyticsListener.EventTime(0L, Timeline.EMPTY, 0, second, 0L, Timeline.EMPTY, 0, second, 0L, 0L),
            bare(com.google.android.exoplayer2.Player.PositionInfo::class.java),
            bare(com.google.android.exoplayer2.Player.PositionInfo::class.java),
            com.google.android.exoplayer2.Player.DISCONTINUITY_REASON_AUTO_TRANSITION
        )
        assertFalse(loads.hasMeasured(first))
        assertTrue(loads.hasMeasured(second))
        assertTrue(loads.hasMeasured(other))
        assertEquals(2, loads.size)
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
