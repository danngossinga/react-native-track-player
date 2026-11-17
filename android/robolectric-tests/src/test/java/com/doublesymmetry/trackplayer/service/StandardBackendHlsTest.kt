package com.doublesymmetry.trackplayer.service

import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.MediaType
import com.doublesymmetry.kotlinaudio.models.PlaybackError
import com.doublesymmetry.kotlinaudio.models.PlayerConfig
import com.doublesymmetry.kotlinaudio.players.QueuedAudioPlayer
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.utils.RejectionException
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.util.MimeTypes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.MediaCodecInfoBuilder
import org.robolectric.shadows.ShadowMediaCodec
import org.robolectric.shadows.ShadowMediaCodecList
import org.robolectric.shadows.ShadowSystemClock
import java.time.Duration

/**
 * The standard backend as the service builds it: vendored KotlinAudio's QueuedAudioPlayer with the
 * service's hooks ([standardPlayerHooks]: its ExoPlayer configuration, HTTP sources and transfer
 * listeners, so its own HLS source), and [KotlinAudioPlaybackBackend] with its load watch, on the
 * main thread as in MusicService, loading HLS from a local server ([HlsTestServer]). What a load or
 * a seek that gives up leaves: the player in error until the next command, the error the app
 * sees, the active track, and no more loading.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class StandardBackendHlsTest {
    private val servers = mutableListOf<HlsTestServer>()
    private val backends = mutableListOf<Backed>()

    /** Robolectric's SystemClock stands still unless moved: move it with real time. */
    private val clock = Thread {
        var last = System.nanoTime()
        while (!Thread.currentThread().isInterrupted) {
            try {
                Thread.sleep(CLOCK_TICK_MS)
            } catch (_: InterruptedException) {
                return@Thread
            }
            val now = System.nanoTime()
            ShadowSystemClock.advanceBy(Duration.ofNanos(now - last))
            last = now
        }
    }.apply { isDaemon = true }

    @Before
    fun setUp() {
        clock.start()
        // An AAC decoder that copies its input, so the audio tracks are selectable (as in
        // StandardPlayerHlsTest).
        ShadowMediaCodecList.addCodec(
            MediaCodecInfoBuilder.newBuilder()
                .setName(TEST_DECODER)
                .setIsEncoder(false)
                .setCapabilities(
                    MediaCodecInfoBuilder.CodecCapabilitiesBuilder.newBuilder()
                        .setMediaFormat(MediaFormat.createAudioFormat(MimeTypes.AUDIO_AAC, 44_100, 2))
                        .build()
                )
                .build()
        )
        ShadowMediaCodec.addDecoder(
            TEST_DECODER,
            ShadowMediaCodec.CodecConfig(CODEC_BUFFER_BYTES, CODEC_BUFFER_BYTES) { input, output -> output.put(input) }
        )
    }

    @After
    fun tearDown() {
        backends.forEach { runCatching { it.player.destroy() } }
        pump(0L)
        servers.forEach { it.close() }
        clock.interrupt()
    }

    // A load that gives up (stallTimeoutMs with no progress) stops the player, which stays in
    // error until the next command (iOS: hostFailure), reports crossfade_prepare_timeout without
    // ExoPlayer's android- prefix, keeps the previous track active (FailedLoadRule) and loads
    // nothing more.

    @Test
    fun aStalledTrackTappedWhileAnotherPlaysEndsInErrorWithThePreviousTrackActive() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("the first track plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        assertEquals("the first track was reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
        // The fan taps an uncached track while the first one plays.
        backed.loadStartedAtMs = monotonicNowMs()
        command { backed.backend.skip(1) }
        backed.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled)
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
        // The error the app sees (the backend's and KotlinAudio's playback-error event): the
        // host's code as is, not android-crossfade_prepare_timeout.
        assertEquals(PREPARE_TIMEOUT_CODE, backed.backend.playbackError?.code)
        val emitted = backed.player.event.playbackError.replayCache.single()
        assertEquals(PREPARE_TIMEOUT_CODE, emitted.code)
        assertEquals(PREPARE_TIMEOUT_CODE, standardPlaybackErrorCode(emitted))
        assertTrue("${emitted.message}", emitted.message!!.startsWith("The track did not become ready (no progress for $STALL_TIMEOUT_MS ms"))
        // FailedLoadRule: the previous track is active again, and the failed one never reported.
        assertEquals("the active track", 0, backed.backend.currentIndex)
        assertEquals("the load failure names the active track", listOf<Int?>(0), backed.loadFailures)
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
        // The player itself is on the failed track, stopped there.
        assertEquals(1, backed.player.currentIndex)
    }

    @Test
    fun aStalledFirstTrackEndsInErrorWithNoActiveTrack() {
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(stalled, 1L)))
        backed.loadStartedAtMs = monotonicNowMs()
        command { backed.backend.play() }
        backed.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled)
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
        assertEquals(PREPARE_TIMEOUT_CODE, backed.player.event.playbackError.replayCache.single().code)
        // The selected first track was reported at once; it failed: none is active.
        assertEquals(-1, backed.backend.currentIndex)
        assertEquals(listOf<Int?>(0, null), backed.activeTrackChanges.map { it.first })
        assertEquals(listOf<Int?>(null), backed.loadFailures)
    }

    // A seek that gives up stops loading too and leaves the player in error (its rejection is
    // the report: no playback error event), with its target as the position.

    @Test
    fun aStalledSeekWhilePlayingEndsInErrorAtItsTarget() {
        // Segments from the fourth on (12 s) never come; the seek to 20 s stalls.
        val server = server(LADDER, segmentCount = 8, stalledFrom = 3)
        val backed = backed()
        backed.backend.add(listOf(item(server, 1L)))
        command { backed.backend.play() }
        awaitTrue("the track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        val seekedAt = monotonicNowMs()
        val error = command { backed.backend.seekTo(SEEK_TARGET_MS) }
        assertEquals("standard_seek_timeout", (error as RejectionException).code)
        assertTrue("gave up ${monotonicNowMs() - seekedAt}ms after the seek", monotonicNowMs() - seekedAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS)
        backed.gaveUpAtMs += monotonicNowMs()
        backed.markStopProcessed()
        backed.assertStopsLoading(server)
        backed.assertStaysInError("standard_seek_timeout")
        assertEquals("standard_seek_timeout", backed.backend.playbackError?.code)
        assertTrue("no playback error event", backed.player.event.playbackError.replayCache.isEmpty())
        // A failed seek keeps its target as the position (as the crossfade path and iOS).
        assertEquals(SEEK_TARGET_MS, backed.player.position)
        assertEquals(SEEK_TARGET_MS, backed.backend.positionMs)
        assertEquals(0, backed.backend.currentIndex)
    }

    @Test
    fun theNextCommandEndsTheErrorASeekLoadsTheTrackAgainAtItsTarget() {
        val server = server(LADDER, segmentCount = 8, stalledFrom = 3)
        val backed = backed()
        backed.backend.add(listOf(item(server, 1L)))
        command { backed.backend.play() }
        awaitTrue("the track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals("standard_seek_timeout", (command { backed.backend.seekTo(SEEK_TARGET_MS) } as RejectionException).code)
        backed.assertStaysInError("standard_seek_timeout")
        // A seek to a part that loads: the stopped track loads again there (paused: the give-up
        // stopped playback), as after a stop and as iOS.
        assertNull(command { backed.backend.seekTo(LOADABLE_TARGET_MS) })
        assertEquals(LOADABLE_TARGET_MS, backed.player.position)
        awaitTrue("ready at the target") { backed.player.playerState == AudioPlayerState.READY }
        assertEquals(AudioPlayerState.READY, backed.backend.playbackState)
    }

    // Playlists are a load's progress only until its first segment is asked for: a segment that
    // fails makes the player fall back to another rendition's playlist, which is not progress.
    // Through KotlinAudio's own HLS source (its media and playlist factories).

    @Test
    fun failingSegmentsGiveUpAtTheStallTimeoutThoughThePlayerFallsBackToOtherRenditions() {
        val failing = server(LADDER, failingStatus = 503, failingAfterMs = STALL_TIMEOUT_MS * 4 / 5)
        val backed = backed()
        backed.backend.add(listOf(item(failing, 1L)))
        command { backed.backend.play() }
        awaitTrue("a give-up; requests ${failing.requests}", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        val firstSegmentAt = failing.stalledRequestTimesMs.first()
        val gaveUpAt = backed.gaveUpAtMs.first()
        assertTrue(
            "gave up ${gaveUpAt - firstSegmentAt}ms after the first segment request (renditions asked: ${failing.segmentRenditions()}); stallTimeoutMs is $STALL_TIMEOUT_MS",
            gaveUpAt - firstSegmentAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS
        )
        assertTrue("the player fell back to another rendition: ${failing.segmentRenditions()}", failing.segmentRenditions().toSet().size > 1)
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
    }

    @Test
    fun aHealthyTrackLoadsThroughTheServicesHooks() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L)))
        command { backed.backend.play() }
        awaitTrue("the track plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        // At the lowest rendition (the service's ExoPlayer configuration), no give-up.
        assertEquals("v064", playable.segmentRenditions().first())
        assertTrue(backed.gaveUpAtMs.isEmpty())
        assertNull(backed.backend.playbackError)
        assertTrue("the load counted its bytes", backed.analytics.loadedBytes.value > 0L)
    }

    /** The standard backend and its player, as MusicService.createPlaybackBackend builds them. */
    private inner class Backed {
        val analytics = StandardPlayerAnalytics()
        val player = QueuedAudioPlayer(
            RuntimeEnvironment.getApplication(),
            // MusicService's configuration (no cache: the app's default maxCacheSize).
            PlayerConfig(
                interceptPlayerActionsTriggeredExternally = true,
                handleAudioBecomingNoisy = false,
                handleAudioFocus = false
            ),
            null,
            null,
            standardPlayerHooks(RuntimeEnvironment.getApplication(), analytics, { DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, { STALL_TIMEOUT_MS })
        )
        val gaveUpAtMs = java.util.Collections.synchronizedList(mutableListOf<Long>())
        /** When ExoPlayer's playback thread had processed each give-up's stop (its clock). */
        val stopProcessedAtMs = java.util.Collections.synchronizedList(mutableListOf<Long>())
        /** When the player started each media load (segment request), on its playback thread's clock. */
        val mediaLoadsStartedAtMs = java.util.Collections.synchronizedList(mutableListOf<Long>())
        val activeTrackChanges = mutableListOf<Pair<Int?, Int?>>()
        val loadFailures = mutableListOf<Int?>()
        /** When the load under test began (a command; the stalled request may go out earlier). */
        var loadStartedAtMs = 0L
        val backend = KotlinAudioPlaybackBackend(
            player,
            Any(),
            AndroidTrackQueue(),
            PlaybackTransitionGenerationSidecar(),
            onCommitted = {},
            onActivated = {},
            onDisposed = {},
            readinessGate = StandardPlaybackReadinessGate(timeoutMs = { PREPARE_TIMEOUT_MS }, stallTimeoutMs = { STALL_TIMEOUT_MS }),
            seekGate = StandardSeekGate(timeoutMs = { PREPARE_TIMEOUT_MS }, stallTimeoutMs = { STALL_TIMEOUT_MS }),
            analytics = { analytics },
            onActiveTrackChanged = { index, lastIndex, _, _ -> activeTrackChanges += index to lastIndex },
            onLoadFailed = { activeIndex ->
                // Called right after the give-up stopped the player (a load the watch gave up).
                gaveUpAtMs += monotonicNowMs()
                loadFailures += activeIndex
                markStopProcessed()
            },
            loadWatch = StandardLoadWatch(
                stallTimeoutMs = { STALL_TIMEOUT_MS },
                totalTimeoutMs = { PREPARE_TIMEOUT_MS },
                onLoadStart = { item -> analytics.loadedBytes.startLoad(item) }
            ),
            initiallyAuthoritative = true
        ).also { it.startLoadWatch(Handler(Looper.getMainLooper())) }

        init {
            analytics.addListener(object : com.google.android.exoplayer2.analytics.AnalyticsListener {
                override fun onLoadStarted(
                    eventTime: com.google.android.exoplayer2.analytics.AnalyticsListener.EventTime,
                    loadEventInfo: com.google.android.exoplayer2.source.LoadEventInfo,
                    mediaLoadData: com.google.android.exoplayer2.source.MediaLoadData
                ) {
                    // The playback thread's clock when the load started (the event reaches this
                    // thread later).
                    if (mediaLoadData.dataType == com.google.android.exoplayer2.C.DATA_TYPE_MEDIA) mediaLoadsStartedAtMs += loadEventInfo.elapsedRealtimeMs
                }
            })
        }

        /** A message sent now runs on the playback thread after the stop just issued. */
        fun markStopProcessed() {
            (analytics.player as ExoPlayer).createMessage { _, _ -> stopProcessedAtMs += android.os.SystemClock.elapsedRealtime() }.send()
        }

        fun assertGivesUpAtTheStallTimeoutAndStopsLoading(server: HlsTestServer) {
            awaitTrue("a give-up; requests ${server.requests}", AWAIT_MS) { gaveUpAtMs.isNotEmpty() }
            val gaveUpAt = gaveUpAtMs.first()
            // The load starts at the stalled request, or at the command when the request went out
            // earlier (the next item buffered ahead while the first one played).
            val requestAt = server.stalledRequestTimesMs.last { it <= gaveUpAt }
            val loadAt = maxOf(requestAt, loadStartedAtMs)
            assertTrue(
                "gave up ${gaveUpAt - loadAt}ms after the load began; stallTimeoutMs is $STALL_TIMEOUT_MS",
                gaveUpAt - loadAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS
            )
            assertStopsLoading(server)
        }

        /** As StandardPlayerHlsTest's: no load once the stop was processed, every request closed. */
        fun assertStopsLoading(server: HlsTestServer) {
            val gaveUpAt = gaveUpAtMs.first()
            awaitTrue("the stop processed by the player") { stopProcessedAtMs.isNotEmpty() }
            val stoppedAt = stopProcessedAtMs.first()
            // ExoPlayer's default policy retries a failed request after 0, 1, 2 s...: wait past those.
            pump(3 * STALL_TIMEOUT_MS)
            assertEquals(
                "media loads started after the stop (started ${mediaLoadsStartedAtMs.toList()}, stop processed at $stoppedAt; requests at ${server.stalledRequestTimesMs.map { it - gaveUpAt }} from the give-up)",
                0,
                mediaLoadsStartedAtMs.count { it > stoppedAt }
            )
            assertTrue(
                "stalled requests after the give-up: ${server.stalledRequestTimesMs.map { it - gaveUpAt }}",
                server.stalledRequestTimesMs.none { it - gaveUpAt > GIVE_UP_SLACK_MS }
            )
            assertEquals("every stalled request is closed", server.stalledRequestTimesMs.size, server.stalledRequestClosedTimesMs.size)
            assertTrue(
                "closed ${server.stalledRequestClosedTimesMs.map { it - gaveUpAt }}ms after the give-up",
                server.stalledRequestClosedTimesMs.all { it - gaveUpAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS }
            )
            assertEquals("one give-up per load", 1, gaveUpAtMs.size)
            assertEquals(com.google.android.exoplayer2.Player.STATE_IDLE, analytics.player!!.playbackState)
        }

        /**
         * In error with [code] once the player's own events after the stop ran (ExoPlayer reports
         * the stop and the play-when-ready change a message later), and still after a while.
         */
        fun assertStaysInError(code: String) {
            pump(STALL_TIMEOUT_MS)
            assertEquals("KotlinAudio's state", AudioPlayerState.ERROR, player.playerState)
            assertEquals("the backend's state", AudioPlayerState.ERROR, backend.playbackState)
            assertEquals(code, player.playbackError?.code)
            assertTrue(player.playbackError!!.fromHost)
        }
    }

    private fun backed(): Backed = Backed().also { backends += it }

    private fun item(server: HlsTestServer, queueId: Long) =
        TrackAudioItem(track = Track(queueId = queueId), type = MediaType.HLS, audioUrl = server.masterUrl)

    /** Runs a backend command on the main thread (the service's), to its end; its error, if any. */
    private fun command(block: suspend () -> Unit): Throwable? {
        var result: Result<Unit>? = null
        CoroutineScope(Dispatchers.Main.immediate).launch { result = runCatching { block() } }
        awaitTrue("the command ends", AWAIT_MS) { result != null }
        return result!!.exceptionOrNull()
    }

    /** Runs the main thread's messages (the player's events, the watch's timer) for [ms]. */
    private fun pump(ms: Long) {
        val until = monotonicNowMs() + ms
        do {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(CLOCK_TICK_MS)
        } while (monotonicNowMs() < until)
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun awaitTrue(what: String, timeoutMs: Long = AWAIT_MS, condition: () -> Boolean) {
        val deadline = monotonicNowMs() + timeoutMs
        while (monotonicNowMs() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return
            Thread.sleep(CLOCK_TICK_MS)
        }
        fail("timed out waiting for $what")
    }

    private fun server(
        renditions: List<Pair<String, Int>>,
        segmentCount: Int = 2,
        stalledFrom: Int = 0,
        failingStatus: Int? = null,
        failingAfterMs: Long = 0L
    ): HlsTestServer =
        HlsTestServer(renditions, segmentCount, stalledFrom, failingStatus, failingAfterMs).also { servers += it }

    private companion object {
        const val TEST_DECODER = "test.aac.decoder"
        const val CODEC_BUFFER_BYTES = 100 * 1024
        val LADDER = listOf("v192" to 192_000, "v128" to 128_000, "v064" to 64_000)
        const val AWAIT_MS = 15_000L
        const val STALL_TIMEOUT_MS = 1_500L
        const val PREPARE_TIMEOUT_MS = 60_000L
        const val PLAYED_MS = 1_000L
        const val SEEK_TARGET_MS = 20_000L
        /** In the second segment, which arrives. */
        const val LOADABLE_TARGET_MS = 5_000L
        /** Time for the watch's sampling and the threads around a give-up. */
        const val GIVE_UP_SLACK_MS = 750L
        const val CLOCK_TICK_MS = 5L
    }
}
