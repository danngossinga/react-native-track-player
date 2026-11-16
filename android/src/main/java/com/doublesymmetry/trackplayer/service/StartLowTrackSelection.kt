package com.doublesymmetry.trackplayer.service

import android.os.Handler
import com.google.android.exoplayer2.Timeline
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.trackselection.AdaptiveTrackSelection
import com.google.android.exoplayer2.trackselection.ExoTrackSelection
import com.google.android.exoplayer2.upstream.BandwidthMeter
import com.google.android.exoplayer2.upstream.TransferListener

/**
 * The standard player's track selections (KotlinAudio's ExoPlayer keeps one bandwidth meter for
 * all its tracks, and prepares the next track ahead): each track's adaptive selection sees the
 * app's current `initialBitrateEstimateBps`, read when the selection is created, until the meter
 * measures new bandwidth; then it follows the measured value. So every track starts low, as on
 * the crossfade path, and climbs as the player measures.
 */
internal class StartLowTrackSelectionFactory(
    private val initialBitrateEstimateBps: () -> Long,
    private val adaptive: ExoTrackSelection.Factory = AdaptiveTrackSelection.Factory()
) : ExoTrackSelection.Factory {
    override fun createTrackSelections(
        definitions: Array<out ExoTrackSelection.Definition>,
        bandwidthMeter: BandwidthMeter,
        mediaPeriodId: MediaSource.MediaPeriodId,
        timeline: Timeline
    ): Array<out ExoTrackSelection> = adaptive.createTrackSelections(
        definitions,
        StartLowBandwidthMeter(bandwidthMeter, initialBitrateEstimateBps()),
        mediaPeriodId,
        timeline
    )
}

/**
 * Reports [initialEstimateBps] until [measured] changes its estimate (a new measurement), then
 * the measured estimate.
 */
internal class StartLowBandwidthMeter(
    private val measured: BandwidthMeter,
    private val initialEstimateBps: Long
) : BandwidthMeter {
    private val estimateAtStart = measured.bitrateEstimate
    @Volatile
    private var hasMeasured = false

    override fun getBitrateEstimate(): Long {
        if (!hasMeasured && measured.bitrateEstimate != estimateAtStart) hasMeasured = true
        return if (hasMeasured) measured.bitrateEstimate else initialEstimateBps
    }

    override fun getTimeToFirstByteEstimateUs(): Long = measured.timeToFirstByteEstimateUs

    override fun getTransferListener(): TransferListener? = measured.transferListener

    override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) =
        measured.addEventListener(eventHandler, eventListener)

    override fun removeEventListener(eventListener: BandwidthMeter.EventListener) =
        measured.removeEventListener(eventListener)
}
