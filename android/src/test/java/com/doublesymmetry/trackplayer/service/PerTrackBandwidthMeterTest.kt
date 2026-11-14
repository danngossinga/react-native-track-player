package com.doublesymmetry.trackplayer.service

import android.net.Uri
import android.os.Handler
import com.google.android.exoplayer2.upstream.BandwidthMeter
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PerTrackBandwidthMeterTest {
    // Android framework classes are stubs in JVM tests (and a DataSpec needs a Uri): build the
    // values the meter only passes along without running a constructor.
    private fun <T> bare(type: Class<T>): T {
        val unsafeField = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe").apply { isAccessible = true }
        val unsafe = unsafeField.get(null)
        @Suppress("UNCHECKED_CAST")
        return unsafe.javaClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, type) as T
    }
    private val spec = bare(DataSpec::class.java)
    private val handler = bare(Handler::class.java)

    /** A measuring meter: reports its initial estimate, then what it measured. */
    private class FakeMeter(val initialEstimate: Long) : BandwidthMeter, TransferListener {
        var measured: Long? = null
        var openTransfers = 0
        var bytes = 0L
        val eventListeners = mutableListOf<BandwidthMeter.EventListener>()

        override fun getBitrateEstimate(): Long = measured ?: initialEstimate
        override fun getTransferListener(): TransferListener = this
        override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) {
            eventListeners += eventListener
        }
        override fun removeEventListener(eventListener: BandwidthMeter.EventListener) {
            eventListeners.remove(eventListener)
        }
        override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
            openTransfers += 1
        }
        override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
            // DefaultBandwidthMeter asserts a transfer is open on it.
            check(openTransfers > 0) { "bytes reported to a meter with no open transfer" }
            bytes += bytesTransferred
        }
        override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
            check(openTransfers > 0) { "end reported to a meter with no open transfer" }
            openTransfers -= 1
        }
    }

    private class FakeSource : DataSource {
        override fun addTransferListener(transferListener: TransferListener) = Unit
        override fun open(dataSpec: DataSpec): Long = 0L
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int = 0
        override fun getUri(): Uri? = null
        override fun close() = Unit
    }

    @Test
    fun everyTrackStartsFromTheCurrentSettingNotFromTheLastMeasure() {
        var setting = DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS
        val built = mutableListOf<FakeMeter>()
        val meter = PerTrackBandwidthMeter({ setting }) { FakeMeter(it).also(built::add) }
        assertEquals(96_000L, meter.bitrateEstimate)

        // The first track measures a fast network...
        assertEquals(96_000L, meter.startTrack())
        built.last().measured = 2_000_000L
        assertEquals(2_000_000L, meter.bitrateEstimate)
        // ...the next one starts low again.
        assertEquals(96_000L, meter.startTrack())
        assertEquals(96_000L, meter.bitrateEstimate)

        // A new value from updateOptions applies to the next track, without a new player.
        setting = 64_000L
        assertEquals(96_000L, meter.bitrateEstimate)
        assertEquals(64_000L, meter.startTrack())
        assertEquals(64_000L, meter.bitrateEstimate)
    }

    @Test
    fun theTrackSelectionListenersFollowTheNewMeter() {
        val built = mutableListOf<FakeMeter>()
        val meter = PerTrackBandwidthMeter({ 96_000L }) { FakeMeter(it).also(built::add) }
        val listener = BandwidthMeter.EventListener { _, _, _ -> }
        meter.addEventListener(handler, listener)
        meter.startTrack()
        assertTrue(built.first().eventListeners.isEmpty())
        assertEquals(listOf(listener), built.last().eventListeners)
        meter.removeEventListener(listener)
        assertTrue(built.last().eventListeners.isEmpty())
        assertSame(meter, meter.transferListener)
    }

    @Test
    fun aTransferStartedBeforeAResetEndsOnTheMeterItStartedOn() {
        val built = mutableListOf<FakeMeter>()
        val meter = PerTrackBandwidthMeter({ 96_000L }) { FakeMeter(it).also(built::add) }
        val oldSegment = FakeSource()
        meter.onTransferInitializing(oldSegment, spec, true)
        meter.onTransferStart(oldSegment, spec, true)
        meter.onBytesTransferred(oldSegment, spec, true, 100)

        meter.startTrack()
        val newSegment = FakeSource()
        meter.onTransferInitializing(newSegment, spec, true)
        meter.onTransferStart(newSegment, spec, true)
        meter.onBytesTransferred(newSegment, spec, true, 50)
        meter.onBytesTransferred(oldSegment, spec, true, 20)
        meter.onTransferEnd(oldSegment, spec, true)
        meter.onTransferEnd(newSegment, spec, true)

        assertEquals(120L, built[0].bytes)
        assertEquals(0, built[0].openTransfers)
        assertEquals(50L, built[1].bytes)
        assertEquals(0, built[1].openTransfers)
    }
}
