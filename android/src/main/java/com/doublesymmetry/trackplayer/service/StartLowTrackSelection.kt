package com.doublesymmetry.trackplayer.service

import android.os.Handler
import com.doublesymmetry.kotlinaudio.models.AudioItemHolder
import java.util.Collections
import java.util.WeakHashMap
import com.google.android.exoplayer2.Timeline
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.trackselection.AdaptiveTrackSelection
import com.google.android.exoplayer2.trackselection.ExoTrackSelection
import com.google.android.exoplayer2.upstream.BandwidthMeter
import com.google.android.exoplayer2.upstream.TransferListener

/**
 * The items whose own transfers have ended (measured by the player's meter), so a track's
 * selection can tell its own measurement from another track's (the one playing, while the next
 * one is prepared ahead). Weak: an item that leaves the queue is forgotten.
 */
internal class OwnTransferRegistry {
    private val measured = Collections.synchronizedMap(WeakHashMap<Any, Boolean>())

    fun transferEnded(item: Any) {
        measured[item] = true
    }

    fun hasMeasured(item: Any): Boolean = measured[item] == true
}

/** The KotlinAudio item a media period plays (its MediaItem's tag), or null. */
internal fun periodItem(mediaPeriodId: MediaSource.MediaPeriodId, timeline: Timeline): Any? = runCatching {
    val windowIndex = timeline.getPeriodByUid(mediaPeriodId.periodUid, Timeline.Period()).windowIndex
    (timeline.getWindow(windowIndex, Timeline.Window()).mediaItem.localConfiguration?.tag as? AudioItemHolder)?.audioItem
}.getOrNull()

/**
 * The standard player's track selections (KotlinAudio's ExoPlayer keeps one bandwidth meter for
 * all its tracks, and prepares the next track ahead): each track's adaptive selection sees the
 * app's current `initialBitrateEstimateBps`, read when the selection is created, until one of the
 * track's own transfers has ended (so measured); then it follows the measured value. A transfer of
 * another track (the one playing while this one is prepared ahead) does not count. So every track
 * starts low, as on the crossfade path (a fresh meter per track), and climbs as it measures.
 */
internal class StartLowTrackSelectionFactory(
    private val initialBitrateEstimateBps: () -> Long,
    private val transfers: OwnTransferRegistry = OwnTransferRegistry(),
    private val itemOf: (MediaSource.MediaPeriodId, Timeline) -> Any? = ::periodItem,
    private val adaptive: ExoTrackSelection.Factory = AdaptiveTrackSelection.Factory()
) : ExoTrackSelection.Factory {
    override fun createTrackSelections(
        definitions: Array<out ExoTrackSelection.Definition>,
        bandwidthMeter: BandwidthMeter,
        mediaPeriodId: MediaSource.MediaPeriodId,
        timeline: Timeline
    ): Array<out ExoTrackSelection> {
        val item = itemOf(mediaPeriodId, timeline)
        return adaptive.createTrackSelections(
            definitions,
            StartLowBandwidthMeter(
                bandwidthMeter,
                initialBitrateEstimateBps(),
                hasOwnMeasurement = item?.let { { transfers.hasMeasured(it) } }
            ),
            mediaPeriodId,
            timeline
        )
    }
}

/**
 * Reports [initialEstimateBps] until the track has its own measurement ([hasOwnMeasurement]; with
 * no item to tell, until [measured] changes its estimate), then the measured estimate.
 */
internal class StartLowBandwidthMeter(
    private val measured: BandwidthMeter,
    private val initialEstimateBps: Long,
    private val hasOwnMeasurement: (() -> Boolean)? = null
) : BandwidthMeter {
    private val estimateAtStart = measured.bitrateEstimate
    @Volatile
    private var hasMeasured = false

    override fun getBitrateEstimate(): Long {
        if (!hasMeasured) {
            hasMeasured = hasOwnMeasurement?.invoke() ?: (measured.bitrateEstimate != estimateAtStart)
        }
        return if (hasMeasured) measured.bitrateEstimate else initialEstimateBps
    }
    override fun getTimeToFirstByteEstimateUs(): Long = measured.timeToFirstByteEstimateUs

    override fun getTransferListener(): TransferListener? = measured.transferListener

    override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) =
        measured.addEventListener(eventHandler, eventListener)

    override fun removeEventListener(eventListener: BandwidthMeter.EventListener) =
        measured.removeEventListener(eventListener)
}
