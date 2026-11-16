package com.doublesymmetry.trackplayer.service

import android.os.Handler
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.source.LoadEventInfo
import com.google.android.exoplayer2.source.MediaLoadData
import java.util.Collections
import com.google.android.exoplayer2.Timeline
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.trackselection.AdaptiveTrackSelection
import com.google.android.exoplayer2.trackselection.ExoTrackSelection
import com.google.android.exoplayer2.upstream.BandwidthMeter
import com.google.android.exoplayer2.upstream.TransferListener

/**
 * The media periods (one per track load or play: a replay or a duplicate in the queue is another
 * period) whose own media has been loaded, so a track's selection can tell its own measurement
 * from another track's (the one playing while the next one is prepared ahead). A manifest or
 * playlist load does not count: only media data (segments, a progressive file). Bounded: a period
 * whose item left the timeline is forgotten ([retainPeriodsOf]), and so is an earlier play of the
 * item now playing ([retireBefore]; a repeat-one replay is a new period of the same item).
 */
internal class OwnMediaLoadRegistry {
    private val measured = Collections.synchronizedSet(HashSet<MediaSource.MediaPeriodId>())

    fun mediaLoaded(period: MediaSource.MediaPeriodId) {
        measured += period
    }

    /** True once [period] loaded media. */
    fun hasMeasured(period: MediaSource.MediaPeriodId): Boolean = period in measured

    /** Forgets the periods no longer in the player's [timeline] (removed items, past replays). */
    fun retainPeriodsOf(timeline: Timeline) {
        val uids = (0 until timeline.periodCount).mapTo(HashSet()) { timeline.getUidOfPeriod(it) }
        synchronized(measured) { measured.removeAll { it.periodUid !in uids } }
    }

    /** [playing] began: the earlier plays (window sequences) of its item have ended. */
    fun retireBefore(playing: MediaSource.MediaPeriodId) {
        synchronized(measured) {
            measured.removeAll { it.periodUid == playing.periodUid && it.windowSequenceNumber < playing.windowSequenceNumber }
        }
    }

    internal val size: Int
        get() = measured.size
}

/** Feeds [OwnMediaLoadRegistry] from the standard player's completed loads (media data only). */
internal class StartLowLoadListener(private val loads: OwnMediaLoadRegistry) : AnalyticsListener {
    override fun onLoadCompleted(
        eventTime: AnalyticsListener.EventTime,
        loadEventInfo: LoadEventInfo,
        mediaLoadData: MediaLoadData
    ) {
        if (mediaLoadData.dataType != C.DATA_TYPE_MEDIA) return
        eventTime.mediaPeriodId?.let(loads::mediaLoaded)
    }

    override fun onTimelineChanged(eventTime: AnalyticsListener.EventTime, reason: Int) {
        loads.retainPeriodsOf(eventTime.timeline)
    }

    override fun onPositionDiscontinuity(
        eventTime: AnalyticsListener.EventTime,
        oldPosition: com.google.android.exoplayer2.Player.PositionInfo,
        newPosition: com.google.android.exoplayer2.Player.PositionInfo,
        reason: Int
    ) {
        eventTime.currentMediaPeriodId?.let(loads::retireBefore)
    }
}

/**
 * The standard player's track selections (KotlinAudio's ExoPlayer keeps one bandwidth meter for
 * all its tracks, and prepares the next track ahead): each track's adaptive selection sees the
 * app's current `initialBitrateEstimateBps`, read when the selection is created, until its own
 * media period has loaded media (so measured); then it follows the measured value. Another
 * track's loads (the one playing while this one is prepared ahead) and its own manifest or
 * playlist do not count. So every track, replayed or duplicated ones too, starts low, as on the
 * crossfade path (a fresh meter per track), and climbs as it measures.
 */
internal class StartLowTrackSelectionFactory(
    private val initialBitrateEstimateBps: () -> Long,
    private val loads: OwnMediaLoadRegistry = OwnMediaLoadRegistry(),
    /** The shared meter's estimate before it has measured (its initial estimate), if known. */
    private val unmeasuredEstimateBps: Long? = null,
    private val adaptive: ExoTrackSelection.Factory = AdaptiveTrackSelection.Factory()
) : ExoTrackSelection.Factory {
    override fun createTrackSelections(
        definitions: Array<out ExoTrackSelection.Definition>,
        bandwidthMeter: BandwidthMeter,
        mediaPeriodId: MediaSource.MediaPeriodId,
        timeline: Timeline
    ): Array<out ExoTrackSelection> = adaptive.createTrackSelections(
        definitions,
        StartLowBandwidthMeter(
            bandwidthMeter,
            initialBitrateEstimateBps(),
            hasOwnMeasurement = { loads.hasMeasured(mediaPeriodId) },
            unmeasuredEstimateBps = unmeasuredEstimateBps
        ),
        mediaPeriodId,
        timeline
    )
}

/**
 * The standard player's start-low pieces, built from one value: the meter's initial estimate and
 * the value its track selections take as "not measured yet" are the same by construction.
 */
internal class StandardStartLow(
    initialBitrateEstimateBps: () -> Long,
    /** Builds the player's meter reporting the given estimate until it has measured. */
    newMeter: (Long) -> BandwidthMeter,
    adaptive: ExoTrackSelection.Factory = AdaptiveTrackSelection.Factory()
) {
    private val loads = OwnMediaLoadRegistry()
    private val unmeasuredBps = initialBitrateEstimateBps()
    val meter: BandwidthMeter = newMeter(unmeasuredBps)
    val selectionFactory = StartLowTrackSelectionFactory(initialBitrateEstimateBps, loads, unmeasuredBps, adaptive)
    val loadListener = StartLowLoadListener(loads)
}

/**
 * Reports [initialEstimateBps] until the track has its own measurement ([hasOwnMeasurement]; when
 * not given, until [measured] changes its estimate), then the measured estimate.
 */
internal class StartLowBandwidthMeter(
    private val measured: BandwidthMeter,
    private val initialEstimateBps: Long,
    private val hasOwnMeasurement: (() -> Boolean)? = null,
    /**
     * [measured]'s estimate before it has measured anything (its initial estimate): while it
     * still reports it, the track keeps [initialEstimateBps] (the current setting).
     */
    private val unmeasuredEstimateBps: Long? = null
) : BandwidthMeter {
    private val estimateAtStart = measured.bitrateEstimate
    @Volatile
    private var hasMeasured = false

    override fun getBitrateEstimate(): Long {
        if (!hasMeasured) {
            hasMeasured = hasOwnMeasurement?.invoke() ?: (measured.bitrateEstimate != estimateAtStart)
        }
        val estimate = measured.bitrateEstimate
        return if (hasMeasured && estimate != unmeasuredEstimateBps) estimate else initialEstimateBps
    }
    override fun getTimeToFirstByteEstimateUs(): Long = measured.timeToFirstByteEstimateUs

    override fun getTransferListener(): TransferListener? = measured.transferListener

    override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) =
        measured.addEventListener(eventHandler, eventListener)

    override fun removeEventListener(eventListener: BandwidthMeter.EventListener) =
        measured.removeEventListener(eventListener)
}
