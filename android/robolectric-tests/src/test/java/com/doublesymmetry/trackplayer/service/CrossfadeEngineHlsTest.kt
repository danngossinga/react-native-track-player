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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.android.asCoroutineDispatcher
import kotlinx.coroutines.async
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
import java.util.concurrent.CountDownLatch
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource

/**
 * A crossfade engine with its real ExoPlayer, loading HLS from a local server ([HlsTestServer]):
 * what the player actually asks the network for, and when it gives up, not what the settings say.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CrossfadeEngineHlsTest {
    private val thread = HandlerThread("crossfade-engine-test").apply { start() }

    /**
     * The engine's thread: ExoPlayer is built and driven there, and the waits' delays are its
     * looper's, as on the service's main thread (Dispatchers.Main is a handler dispatcher too).
     */
    private val engineThread = Handler(thread.looper).asCoroutineDispatcher()
    private val servers = mutableListOf<HlsTestServer>()
    private val engines = mutableListOf<AndroidCrossfadeEngine>()
    /** Each engine's player's load starts, in order ([PlayerLoadLog]). */
    private val loadLogs = mutableMapOf<AndroidCrossfadeEngine, PlayerLoadLog>()
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

    @Test
    fun aHigherEstimateStartsAtTheHighestRenditionThatFitsAbout70PercentOfIt() {
        // 200 kbit/s: 70 % is 140 kbit/s, so the 128 kbit/s rendition (not the lowest, not the
        // highest) is the first one asked for.
        val server = server(listOf("v192" to 192_000, "v064" to 64_000, "v128" to 128_000))
        startLoading(engine(STALL_TIMEOUT_MS, initialBitrateEstimateBps = 200_000L), server)
        assertEquals("v128", awaitFirstSegmentRendition(server))
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
    fun failingSegmentsGiveUpAtTheStallTimeoutThoughThePlayerFallsBackToOtherRenditions() {
        // Each segment fails (503) shortly before the stall timeout: the player then loads another
        // rendition's playlist. Playlists are not media: those loads must not count as progress.
        val engine = engine(STALL_TIMEOUT_MS)
        val failing = server(LADDER, failingStatus = 503, failingAfterMs = STALL_TIMEOUT_MS * 4 / 5)
        val startedAtMs = monotonicNowMs()
        val error = runBlocking(engineThread) {
            runCatching {
                engine.prepare(hlsItem(failing), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS)
            }
        }.exceptionOrNull()
        val gaveUpAfterMs = monotonicNowMs() - startedAtMs
        assertTrue("the load must fail, got $error", error is RejectionException)
        assertEquals("crossfade_prepare_timeout", (error as RejectionException).code)
        assertTrue(
            "gave up after ${gaveUpAfterMs}ms (renditions asked: ${failing.segmentRenditions()}); stallTimeoutMs is $STALL_TIMEOUT_MS",
            gaveUpAfterMs < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS
        )
    }

    @Test
    fun slowPlaylistsBeforeTheFirstSegmentDoNotMakeAHealthyTrackGiveUp() {
        // Device case: a busy proxy answers the master and the media playlist slowly (each well
        // within the stall timeout, together past it); the segments then come at once. Until the
        // first segment is asked for, playlists arriving are the load's progress.
        val stall = SLOW_STALL_TIMEOUT_MS
        val engine = engine(stall)
        val slow = slowServer(playlistDelayMs = slowStage(stall))
        val result = runBlocking(engineThread) {
            runCatching { engine.prepare(hlsItem(slow), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stall) }
        }
        assertTrue("a healthy track loads, got $result", result.isSuccess)
        assertPlaylistsOutlastedTheStallTimeout(slow, stall)
    }

    @Test
    fun aSlowKeyBeforeTheFirstSegmentDoesNotMakeAHealthyTrackGiveUp() {
        // Encrypted track: playlists, then the key (slow), then the first segment (slow to start).
        // The key arriving is progress, since no segment was asked for yet; without it the gap from
        // the media playlist to the first segment bytes would exceed the stall timeout.
        val stall = SLOW_STALL_TIMEOUT_MS
        val engine = engine(stall)
        val encrypted = slowServer(keyDelayMs = slowStage(stall), segmentDelayMs = slowStage(stall))
        val result = runBlocking(engineThread) {
            runCatching { engine.prepare(hlsItem(encrypted), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stall) }
        }
        assertTrue("a healthy encrypted track loads, got $result (requests: ${encrypted.requests})", result.isSuccess)
        assertTrue("the key was asked for", encrypted.requests.any { it.endsWith("/key.bin") })
    }

    @Test
    fun aStaleSegmentRequestOfThePreviousTrackDoesNotStopTheNextTracksPlaylistsCounting() {
        // Device case: the fan taps an uncached track while another loads, behind a slow proxy.
        // The previous track's segment request is already on its way when the engine resets; it
        // starts while the next track's playlists are still coming. It belongs to the previous
        // load: the next track's playlists must still count as its progress.
        val stall = SLOW_STALL_TIMEOUT_MS
        val previous = server(LADDER)
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val engine = engine(stall, requestSource = { factory, timeoutMs ->
            GatedDataSource(
                httpSourceWithTimeouts(factory, timeoutMs),
                isHeld = { it.uri.port == previous.port && it.uri.path.orEmpty().endsWith(".aac") },
                held = held,
                release = release
            )
        })
        startLoading(engine, previous, stall)
        awaitTrue("the previous track's first segment request is held") { held.count == 0L }

        val next = HlsTestServer(
            LADDER,
            segmentCount = 8,
            stalledFrom = 8,
            playlistDelayMs = slowStage(stall)
        ).also { servers += it }
        val result = CoroutineScope(engineThread).async {
            loads.forEach { it.cancel() }
            engine.reset()
            runCatching { engine.prepare(hlsItem(next), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stall) }
        }
        // The stale request starts once the next track has asked for its master playlist.
        awaitTrue("the next track's master playlist request") { next.requests.contains("/master.m3u8") }
        release.countDown()
        val outcome = runBlocking { result.await() }
        assertTrue("the next healthy track loads, got $outcome", outcome.isSuccess)
    }

    @Test
    fun slowPlaylistsCountAgainForTheNextTrackOnTheSameEngine() {
        // The previous track asked for segments; the next one's playlists are progress again.
        val stall = SLOW_STALL_TIMEOUT_MS
        val engine = engine(stall)
        val first = server(LADDER, segmentCount = 8, stalledFrom = 8)
        runBlocking(engineThread) {
            engine.prepare(hlsItem(first), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stall)
        }
        val slow = slowServer(playlistDelayMs = slowStage(stall))
        val result = runBlocking(engineThread) {
            engine.reset()
            runCatching { engine.prepare(hlsItem(slow), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stall) }
        }
        assertTrue("the next healthy track loads, got $result", result.isSuccess)
        assertPlaylistsOutlastedTheStallTimeout(slow, stall)
    }

    @Test
    fun aPlayerErrorDuringALoadAlsoStopsLoadingAsOnIos() {
        // The master playlist is not a playlist: the player fails at once. As on iOS, whatever
        // ends a load (stall, limit, player error), the engine stops and forgets the track.
        val engine = engine(STALL_TIMEOUT_MS)
        val broken = HlsTestServer(LADDER, masterBody = "not a playlist").also { servers += it }
        val item = hlsItem(broken)
        val error = runBlocking(engineThread) {
            runCatching { engine.prepare(item, 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS) }
        }.exceptionOrNull()
        assertTrue("the load must fail, got $error", error is RejectionException)
        assertEquals("crossfade_engine_error", (error as RejectionException).code)
        runBlocking(engineThread) {
            assertFalse("a track that failed is not prepared", engine.isPreparedFor(item))
            assertEquals(Player.STATE_IDLE, engine.playbackState)
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
        val operations = PlaybackOperationController()
        assertGivesUpAtTheStallTimeoutAndStopsLoading(engine, stalled) { item ->
            // As the orchestrator starts a track: a playback operation, reset, then load.
            val ticket = operations.begin()
            engine.reset()
            engine.prepare(item, 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS, ticket = ticket)
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
            runCatching { engine.seekTo(SEEK_TARGET_MS, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = STALL_TIMEOUT_MS) }
        }.exceptionOrNull()
        val gaveUpAtMs = monotonicNowMs()
        assertTrue("the seek must fail, got $error", error is RejectionException)
        assertEquals("crossfade_seek_timeout", (error as RejectionException).code)
        assertTrue(
            "gave up ${gaveUpAtMs - seekedAtMs}ms after the seek; stallTimeoutMs is $STALL_TIMEOUT_MS",
            gaveUpAtMs - seekedAtMs < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS
        )
        assertStopsLoading(engine, item, server, gaveUpAtMs)
        // The position reported after a failed seek is its target (as iOS), where the next play
        // loads the track again.
        assertEquals(SEEK_TARGET_MS, runBlocking(engineThread) { engine.positionMs })
    }

    @Test
    fun aSeekThatFailsWithAPlayerErrorAlsoStopsLoadingAsOnIos() {
        // The segments the seek lands in are gone (404 on every rendition): after its retries the
        // player fails. As for a load, the seek reports it (not "finished") and the engine stops
        // and forgets the track. The stall timeout is long here, so the player error comes first.
        val stallTimeoutMs = PREPARE_TIMEOUT_MS / 2
        val engine = engine(stallTimeoutMs)
        val server = server(LADDER, segmentCount = 8, stalledFrom = 3, failingStatus = 404)
        val item = hlsItem(server)
        runBlocking(engineThread) {
            engine.prepare(item, 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stallTimeoutMs)
        }
        val error = runBlocking(engineThread) {
            runCatching { engine.seekTo(SEEK_TARGET_MS, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stallTimeoutMs) }
        }.exceptionOrNull()
        assertTrue("the seek must fail, got $error", error is RejectionException)
        assertEquals("crossfade_engine_error", (error as RejectionException).code)
        runBlocking(engineThread) {
            assertFalse("a track whose seek failed is not prepared", engine.isPreparedFor(item))
            assertEquals(Player.STATE_IDLE, engine.playbackState)
        }
    }

    @Test
    fun aSlowButSteadySeekIsNotAStall() {
        // The segments the seek lands in come slowly: bytes arrive every 60 % of the stall timeout,
        // but no full audio frame until the end (nothing buffered meanwhile). The seek's media bytes
        // are its progress: it finishes, though the whole download outlasts the stall timeout.
        val stall = SLOW_STALL_TIMEOUT_MS
        val engine = engine(stall)
        val server = HlsTestServer(
            LADDER,
            segmentCount = 8,
            stalledFrom = 8,
            trickleFrom = 3,
            trickleGapMs = slowStage(stall)
        ).also { servers += it }
        runBlocking(engineThread) {
            engine.prepare(hlsItem(server), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stall)
        }
        val seekedAtMs = monotonicNowMs()
        val result = runBlocking(engineThread) {
            runCatching { engine.seekTo(SEEK_TARGET_MS, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stall) }
        }
        assertTrue("a slow but steady seek finishes, got $result", result.isSuccess)
        assertTrue("the seek's download outlasted the stall timeout", monotonicNowMs() - seekedAtMs > stall)
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
        assertEquals("Crossfade engine did not become ready (no progress for $STALL_TIMEOUT_MS ms).", error.message)
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
        // The give-up stopped the player before the operation failed: a marker sent now runs on
        // its playback thread after that stop.
        val log = loadLogs.getValue(engine)
        val stopped = runBlocking(engineThread) { log.mark(engine.player) }
        // The open requests end by their read timeout (stallTimeoutMs). Then watch as long again:
        // ExoPlayer's default policy would retry within 1 s of such a failure.
        waitUntil(STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS) {
            server.stalledRequestClosedTimesMs.size == server.stalledRequestTimesMs.size
        }
        waitUntil(STALL_TIMEOUT_MS) { server.stalledRequestTimesMs.size > requestsAtGiveUp }
        assertEquals(
            "stalled requests after the give-up (times ${server.stalledRequestTimesMs.map { it - gaveUpAtMs }})",
            requestsAtGiveUp,
            server.stalledRequestTimesMs.size
        )
        // Nor does the stopped player start a load (its own load order, as StandardPlayerHlsTest).
        awaitTrue("the stop processed by the player") { stopped.reached }
        assertEquals("media loads started after the stop", emptyList<PlayerLoadLog.LoadStart>(), log.mediaLoadsAfter(stopped))
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

    /**
     * One slow stage of a healthy load: well within the stall timeout (a loaded machine has 40 %
     * of it to spare), while two stages together outlast it.
     */
    private fun slowStage(stallTimeoutMs: Long) = stallTimeoutMs * 3 / 5

    /** A healthy track (all segments served) behind a slow server. */
    private fun slowServer(playlistDelayMs: Long = 0L, keyDelayMs: Long? = null, segmentDelayMs: Long = 0L) =
        HlsTestServer(
            LADDER,
            segmentCount = 8,
            stalledFrom = 8,
            playlistDelayMs = playlistDelayMs,
            keyDelayMs = keyDelayMs,
            segmentDelayMs = segmentDelayMs
        ).also { servers += it }

    /** The playlists came in over more than the stall timeout (the server's own clock). */
    private fun assertPlaylistsOutlastedTheStallTimeout(server: HlsTestServer, stallTimeoutMs: Long) {
        val masterAt = server.firstRequestAtMs { it == "/master.m3u8" }!!
        val firstSegmentAt = server.firstRequestAtMs { it.endsWith(".aac") }!!
        assertTrue(
            "the first segment was asked for ${firstSegmentAt - masterAt}ms after the master playlist",
            firstSegmentAt - masterAt > stallTimeoutMs
        )
    }

    private fun server(
        renditions: List<Pair<String, Int>>,
        segmentCount: Int = 2,
        stalledFrom: Int = 0,
        failingStatus: Int? = null,
        failingAfterMs: Long = 0L
    ): HlsTestServer =
        HlsTestServer(renditions, segmentCount, stalledFrom, failingStatus, failingAfterMs).also { servers += it }

    private fun engine(
        stallTimeoutMs: Long,
        initialBitrateEstimateBps: Long = DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS,
        requestSource: (DefaultHttpDataSource.Factory, Int) -> DataSource = ::httpSourceWithTimeouts
    ): AndroidCrossfadeEngine = runBlocking(engineThread) {
        AndroidCrossfadeEngine(
            RuntimeEnvironment.getApplication(),
            "engineA",
            C.AUDIO_CONTENT_TYPE_MUSIC,
            /* handleAudioFocus= */ false,
            initialBitrateEstimateBps = { initialBitrateEstimateBps },
            stallTimeoutMs = { stallTimeoutMs },
            requestSource = requestSource
        ).also {
            engines += it
            loadLogs[it] = PlayerLoadLog().also(it.player::addAnalyticsListener)
        }
    }

    /** Starts loading the server's track; the load goes on in the background. */
    private fun startLoading(engine: AndroidCrossfadeEngine, server: HlsTestServer, stallTimeoutMs: Long = STALL_TIMEOUT_MS) {
        loads += CoroutineScope(engineThread).launch {
            runCatching {
                engine.prepare(hlsItem(server), 0L, timeoutMs = PREPARE_TIMEOUT_MS, stallTimeoutMs = stallTimeoutMs)
            }
        }
    }

    private fun awaitFirstSegmentRendition(server: HlsTestServer): String {
        awaitTrue("a segment request; requests: ${server.requests}") { server.segmentRenditions().isNotEmpty() }
        return server.segmentRenditions().first()
    }

    /** Waits until [condition] holds or [timeoutMs] passes (the caller asserts what it needs). */
    private fun waitUntil(timeoutMs: Long, condition: () -> Boolean) {
        val deadline = monotonicNowMs() + timeoutMs
        while (monotonicNowMs() < deadline && !condition()) Thread.sleep(POLL_MS)
    }

    private fun awaitTrue(what: String, condition: () -> Boolean) {
        val deadline = monotonicNowMs() + AWAIT_MS
        while (monotonicNowMs() < deadline) {
            if (condition()) return
            Thread.sleep(POLL_MS)
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
        const val STALL_TIMEOUT_MS = 2_000L
        /** For the slow-but-healthy loads: long enough that each slow stage has a wide margin. */
        const val SLOW_STALL_TIMEOUT_MS = 4_000L
        const val PREPARE_TIMEOUT_MS = 60_000L
        const val PLAYED_MS = 1_000L
        const val SEEK_TARGET_MS = 20_000L
        /** Time for the wait's poll and the threads around a give-up: half the stall timeout. */
        const val GIVE_UP_SLACK_MS = STALL_TIMEOUT_MS / 2
        const val AWAIT_MS = 15_000L
        const val CLOCK_TICK_MS = 5L
        const val POLL_MS = 20L
    }
}
