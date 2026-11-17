package com.doublesymmetry.trackplayer.service

import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import com.doublesymmetry.kotlinaudio.models.MediaType
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.utils.RejectionException
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.util.MimeTypes
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.MediaCodecInfoBuilder
import org.robolectric.shadows.ShadowMediaCodec
import org.robolectric.shadows.ShadowMediaCodecList
import org.robolectric.shadows.ShadowSystemClock
import java.time.Duration
import kotlin.coroutines.CoroutineContext

/**
 * A crossfade engine with its real ExoPlayer, loading HLS from a local server ([HlsTestServer]):
 * what the player actually asks the network for, and when it gives up, not what the settings say.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CrossfadeEngineHlsTest {
    private val thread = HandlerThread("crossfade-engine-test").apply { start() }

    /** The engine's thread: ExoPlayer is built and driven there, as on the service's main thread. */
    private val engineThread = object : CoroutineDispatcher() {
        private val handler = Handler(thread.looper)
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            handler.post(block)
        }
    }
    private val servers = mutableListOf<HlsTestServer>()
    private val engines = mutableListOf<AndroidCrossfadeEngine>()
    private val loads = mutableListOf<Job>()

    /**
     * Robolectric's SystemClock stands still unless a test moves it, and the players' threads
     * (ExoPlayer's playback loop, the engine's waits) run on it: move it with real time.
     */
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
        // Robolectric has no codecs: an AAC decoder that copies its input, so tracks are selected
        // and played (nothing is decoded; the tests look at the network and the player's state).
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
        runBlocking(engineThread) {
            loads.forEach { it.cancel() }
            engines.forEach { it.release() }
        }
        servers.forEach { it.close() }
        thread.quitSafely()
        clock.interrupt()
    }

    // An uncached track starts at its lowest rendition (initialBitrateEstimateBps, 96 kbit/s by
    // default, fits none of the three): the first segment the player asks for is the 64 kbit/s one,
    // in whichever order the master playlist lists them.

    @Test
    fun anUncachedTrackAsksForItsFirstSegmentAtTheLowestRenditionHighestListedFirst() {
        val server = server(listOf("v192" to 192_000, "v128" to 128_000, "v064" to 64_000))
        startLoading(engine(STALL_TIMEOUT_MS), server)
        assertEquals("v064", awaitFirstSegmentRendition(server))
    }

    @Test
    fun anUncachedTrackAsksForItsFirstSegmentAtTheLowestRenditionLowestListedFirst() {
        val server = server(listOf("v064" to 64_000, "v128" to 128_000, "v192" to 192_000))
        startLoading(engine(STALL_TIMEOUT_MS), server)
        assertEquals("v064", awaitFirstSegmentRendition(server))
    }

    // A segment that never comes: the load fails at stallTimeoutMs (ExoPlayer's own retries do not
    // extend it), and the player stops asking for it (the abandoned request closed, no retry).

    @Test
    fun aStalledLoadGivesUpAtTheStallTimeoutAndStopsLoading() {
        val engine = engine(STALL_TIMEOUT_MS)
        val stalled = server(LADDER)
        assertGivesUpAtTheStallTimeoutAndStopsLoading(engine, stalled) { item ->
            engine.prepare(item, 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS)
        }
    }

    @Test
    fun aStalledLoadAfterAPlayingTrackGivesUpAtTheStallTimeoutAndStopsLoading() {
        // Device case: a track plays, the fan taps an uncached track whose segment never comes.
        val engine = engine(STALL_TIMEOUT_MS)
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        runBlocking(engineThread) {
            engine.prepare(hlsItem(playable), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS)
            engine.play()
        }
        awaitTrue("the first track plays") { runBlocking(engineThread) { engine.positionMs } >= PLAYED_MS }

        val stalled = server(LADDER)
        assertGivesUpAtTheStallTimeoutAndStopsLoading(engine, stalled) { item ->
            // As the orchestrator starts a track: reset, then load.
            engine.reset()
            engine.prepare(item, 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS)
        }
    }

    @Test
    fun aStalledSeekGivesUpAtTheStallTimeoutAndStopsLoading() {
        val engine = engine(STALL_TIMEOUT_MS)
        // Segments from the fourth on (12 s) never come.
        val server = server(LADDER, segmentCount = 8, stalledFrom = 3)
        val item = hlsItem(server)
        runBlocking(engineThread) {
            engine.prepare(item, 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS)
        }
        val seekedAtMs = monotonicNowMs()
        val error = runBlocking(engineThread) {
            runCatching { engine.seekTo(20_000L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS) }
        }.exceptionOrNull()
        val gaveUpAtMs = monotonicNowMs()
        assertTrue("the seek must fail, got $error", error is RejectionException)
        assertEquals("crossfade_seek_timeout", (error as RejectionException).code)
        assertTrue(
            "gave up ${gaveUpAtMs - seekedAtMs}ms after the seek; stallTimeoutMs is $STALL_TIMEOUT_MS",
            gaveUpAtMs - seekedAtMs < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS
        )
        assertStopsLoading(engine, item, server, gaveUpAtMs)
    }

    private fun assertGivesUpAtTheStallTimeoutAndStopsLoading(
        engine: AndroidCrossfadeEngine,
        stalled: HlsTestServer,
        load: suspend (TrackAudioItem) -> Unit
    ) {
        val item = hlsItem(stalled)
        val error = runBlocking(engineThread) { runCatching { load(item) } }.exceptionOrNull()
        val gaveUpAtMs = monotonicNowMs()
        assertTrue("the load must fail, got $error", error is RejectionException)
        assertEquals("crossfade_prepare_timeout", (error as RejectionException).code)
        val firstRequestAtMs = stalled.stalledRequestTimesMs.first()
        assertTrue(
            "gave up ${gaveUpAtMs - firstRequestAtMs}ms after the segment request; stallTimeoutMs is $STALL_TIMEOUT_MS",
            gaveUpAtMs - firstRequestAtMs < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS
        )
        assertStopsLoading(engine, item, stalled, gaveUpAtMs)
    }

    /**
     * After a give-up: no request is retried, the open ones end, and the track is no longer
     * prepared (the next play loads it again).
     */
    private fun assertStopsLoading(
        engine: AndroidCrossfadeEngine,
        item: TrackAudioItem,
        server: HlsTestServer,
        gaveUpAtMs: Long
    ) {
        val requestsAtGiveUp = server.stalledRequestTimesMs.size
        // ExoPlayer's default policy retries a failed request after 0, 1, 2 s...: wait past those.
        Thread.sleep(3 * STALL_TIMEOUT_MS)
        assertEquals(
            "stalled requests after the give-up (times ${server.stalledRequestTimesMs.map { it - gaveUpAtMs }})",
            requestsAtGiveUp,
            server.stalledRequestTimesMs.size
        )
        assertEquals(
            "every stalled request is closed by the player (closed at ${server.stalledRequestClosedTimesMs.map { it - gaveUpAtMs }})",
            server.stalledRequestTimesMs.size,
            server.stalledRequestClosedTimesMs.size
        )
        // A request blocked in the network ends by its own read timeout, which follows
        // stallTimeoutMs; none is retried.
        assertTrue(
            "closed ${server.stalledRequestClosedTimesMs.map { it - gaveUpAtMs }}ms after the give-up",
            server.stalledRequestClosedTimesMs.all { it - gaveUpAtMs < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS }
        )
        runBlocking(engineThread) {
            assertFalse("a track that failed is not prepared", engine.isPreparedFor(item))
            assertEquals(Player.STATE_IDLE, engine.playbackState)
        }
    }

    private fun server(
        renditions: List<Pair<String, Int>>,
        segmentCount: Int = 2,
        stalledFrom: Int = 0
    ): HlsTestServer = HlsTestServer(renditions, segmentCount, stalledFrom).also { servers += it }

    private fun engine(stallTimeoutMs: Long): AndroidCrossfadeEngine = runBlocking(engineThread) {
        AndroidCrossfadeEngine(
            RuntimeEnvironment.getApplication(),
            "engineA",
            C.AUDIO_CONTENT_TYPE_MUSIC,
            /* handleAudioFocus= */ false,
            initialBitrateEstimateBps = { DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS },
            stallTimeoutMs = { stallTimeoutMs }
        ).also { engines += it }
    }

    /** Starts loading the server's track; the load goes on in the background. */
    private fun startLoading(engine: AndroidCrossfadeEngine, server: HlsTestServer) {
        loads += CoroutineScope(engineThread).launch {
            runCatching {
                engine.prepare(hlsItem(server), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS)
            }
        }
    }

    private fun awaitFirstSegmentRendition(server: HlsTestServer): String {
        awaitTrue("a segment request; requests: ${server.requests}") { server.segmentRenditions().isNotEmpty() }
        return server.segmentRenditions().first()
    }

    private fun awaitTrue(what: String, condition: () -> Boolean) {
        val deadline = monotonicNowMs() + AWAIT_MS
        while (monotonicNowMs() < deadline) {
            if (condition()) return
            Thread.sleep(20)
        }
        fail("timed out waiting for $what")
    }

    private fun hlsItem(server: HlsTestServer) = TrackAudioItem(
        track = Track(),
        type = MediaType.HLS,
        audioUrl = server.masterUrl,
        title = "Test track",
        duration = 32_000L
    )

    private companion object {
        const val TEST_DECODER = "test.aac.decoder"
        const val CODEC_BUFFER_BYTES = 100 * 1024
        val LADDER = listOf("v064" to 64_000, "v128" to 128_000, "v192" to 192_000)
        const val STALL_TIMEOUT_MS = 1_500L
        const val PREPARE_TIMEOUT_MS = 60_000L
        const val PLAYED_MS = 1_000L
        /** Time for the wait's poll and the threads around a give-up. */
        const val GIVE_UP_SLACK_MS = 750L
        const val AWAIT_MS = 15_000L
        const val CLOCK_TICK_MS = 5L
    }
}
