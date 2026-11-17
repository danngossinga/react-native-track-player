package com.doublesymmetry.trackplayer.service

import android.os.Handler
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.source.LoadEventInfo
import com.google.android.exoplayer2.source.MediaLoadData
import java.util.Collections

/**
 * The loads a real ExoPlayer starts, in the order its playback thread started them, with markers
 * that say where the player had processed a command (a stop, a jump to another item).
 *
 * The playback thread posts each load start to the player's application looper (MediaSourceList's
 * forwarding listener, then the analytics collector); a marker is a player message, which runs on
 * the playback thread after every command sent before it (messages to a player run in order), and
 * posts itself to the same looper. Both are posted from the playback thread, so the looper runs
 * them in the order the playback thread made them: a load after a marker started after the command
 * was processed. Neither the server's arrival times (a request started before the command can
 * reach it after) nor the clock (Robolectric's moves in steps of several milliseconds, so a load
 * and a marker often share a time) can tell that.
 */
internal class PlayerLoadLog : AnalyticsListener {
    sealed interface Entry

    /** A load the player started: its URI, its C.DATA_TYPE_*, and whether a media period made it. */
    data class LoadStart(val uri: String, val dataType: Int, val ofAMediaPeriod: Boolean) : Entry {
        val isMedia: Boolean get() = dataType == C.DATA_TYPE_MEDIA
    }

    class Marker : Entry {
        @Volatile
        var reached = false
    }

    private val entries: MutableList<Entry> = Collections.synchronizedList(mutableListOf())

    override fun onLoadStarted(eventTime: AnalyticsListener.EventTime, loadEventInfo: LoadEventInfo, mediaLoadData: MediaLoadData) {
        entries += LoadStart(loadEventInfo.uri.toString(), mediaLoadData.dataType, eventTime.mediaPeriodId != null)
    }

    /**
     * Marks the point where [player]'s playback thread has processed every command issued so far.
     * Call it on the player's application thread, right after the command; the marker is reached
     * once that looper ran it.
     */
    fun mark(player: ExoPlayer): Marker {
        val marker = Marker()
        val applicationThread = Handler(player.applicationLooper)
        player.createMessage { _, _ ->
            applicationThread.post {
                entries += marker
                marker.reached = true
            }
        }.send()
        return marker
    }

    /** The loads of [server]'s track started after [marker] (it must be reached). */
    fun loadsAfter(marker: Marker, server: HlsTestServer): List<LoadStart> = synchronized(entries) {
        check(marker.reached) { "the marker was not reached" }
        entries.drop(entries.indexOf(marker) + 1).filterIsInstance<LoadStart>().filter { it.isOf(server) }
    }

    /** The loads of [server]'s track started before [marker] (it must be reached). */
    fun loadsBefore(marker: Marker, server: HlsTestServer): List<LoadStart> = synchronized(entries) {
        check(marker.reached) { "the marker was not reached" }
        entries.take(entries.indexOf(marker)).filterIsInstance<LoadStart>().filter { it.isOf(server) }
    }

    /** Every media load started after [marker], of any track. */
    fun mediaLoadsAfter(marker: Marker): List<LoadStart> = synchronized(entries) {
        check(marker.reached) { "the marker was not reached" }
        entries.drop(entries.indexOf(marker) + 1).filterIsInstance<LoadStart>().filter { it.isMedia }
    }

    private fun LoadStart.isOf(server: HlsTestServer) = uri.startsWith("http://127.0.0.1:${server.port}/")
}
