package com.doublesymmetry.trackplayer.service

import android.os.Handler
import com.google.android.exoplayer2.upstream.BandwidthMeter
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import java.util.Collections
import java.util.IdentityHashMap

/**
 * A crossfade player's bandwidth meter that starts every track from the app's current
 * `initialBitrateEstimateBps`: [startTrack] replaces the measuring meter with a fresh one built
 * from that value, so adaptive selection starts low for each track and climbs as it measures.
 *
 * ExoPlayer keeps this object for the player's life (track selection reads [getBitrateEstimate],
 * media sources report their transfers to [getTransferListener]); the measuring meter behind it
 * changes. A transfer that started before a reset keeps reporting to the meter it started on, so
 * that meter's start and end calls stay paired.
 *
 * The setting is a start-of-track estimate by nature: a new value is used at the next
 * [startTrack]; the playing track is not reset mid-track, its adaptive choice follows the
 * bandwidth the meter measures (ExoPlayer's design).
 */
internal class PerTrackBandwidthMeter(
    /** The app's current value, read at every [startTrack]. */
    private val initialBitrateEstimateBps: () -> Long,
    /** Builds a measuring meter that reports the given estimate until it has measured. */
    private val newMeter: (Long) -> BandwidthMeter
) : BandwidthMeter, TransferListener {
    @Volatile
    private var current: BandwidthMeter = newMeter(initialBitrateEstimateBps())
    private val listeners = mutableListOf<Pair<Handler, BandwidthMeter.EventListener>>()
    private val transfers: MutableMap<DataSource, BandwidthMeter> =
        Collections.synchronizedMap(IdentityHashMap())

    /** Starts a new track from the current setting; returns the estimate it starts from. */
    fun startTrack(): Long {
        val estimate = initialBitrateEstimateBps()
        val fresh = newMeter(estimate)
        synchronized(listeners) {
            val previous = current
            for ((handler, listener) in listeners) {
                previous.removeEventListener(listener)
                fresh.addEventListener(handler, listener)
            }
            current = fresh
        }
        return estimate
    }

    override fun getBitrateEstimate(): Long = current.bitrateEstimate

    override fun getTimeToFirstByteEstimateUs(): Long = current.timeToFirstByteEstimateUs

    override fun getTransferListener(): TransferListener = this

    override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) {
        synchronized(listeners) {
            listeners += eventHandler to eventListener
            current.addEventListener(eventHandler, eventListener)
        }
    }

    override fun removeEventListener(eventListener: BandwidthMeter.EventListener) {
        synchronized(listeners) {
            listeners.removeAll { it.second === eventListener }
            current.removeEventListener(eventListener)
        }
    }

    /** Transfers started and not yet ended (a failed open never starts, so it is not kept). */
    internal val openTransfers: Int
        get() = transfers.size

    override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        current.transferListener?.onTransferInitializing(source, dataSpec, isNetwork)
    }

    override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        val meter = current
        transfers[source] = meter
        meter.transferListener?.onTransferStart(source, dataSpec, isNetwork)
    }

    override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
        val meter = transfers[source] ?: return
        meter.transferListener?.onBytesTransferred(source, dataSpec, isNetwork, bytesTransferred)
    }

    override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        val meter = transfers.remove(source) ?: return
        meter.transferListener?.onTransferEnd(source, dataSpec, isNetwork)
    }
}
