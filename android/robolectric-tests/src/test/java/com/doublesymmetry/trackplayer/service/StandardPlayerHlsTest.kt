package com.doublesymmetry.trackplayer.service

import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.util.MimeTypes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.android.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
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

/**
 * The standard player's ExoPlayer, built with the configuration the service gives vendored
 * KotlinAudio ([configureStandardExoPlayer]), loading HLS from a local server ([HlsTestServer]):
 * the rendition it actually asks the network for, not what the bandwidth estimate says.
 * KotlinAudio's own HLS source is ExoPlayer's HlsMediaSource, as here.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class StandardPlayerHlsTest {
    private val thread = HandlerThread("standard-player-test").apply { start() }
    private val playerThread = Handler(thread.looper).asCoroutineDispatcher()
    private val servers = mutableListOf<HlsTestServer>()
    private val players = mutableListOf<ExoPlayer>()
    private val watches = mutableListOf<Job>()

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
        // CrossfadeEngineHlsTest).
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
        runBlocking(playerThread) {
            watches.forEach { it.cancel() }
            players.forEach { it.release() }
        }
        servers.forEach { it.close() }
        thread.quitSafely()
        clock.interrupt()
    }

    // An uncached track starts at its lowest rendition (initialBitrateEstimateBps, 96 kbit/s by
    // default, fits none of the three), in whichever order the master playlist lists them; so
    // does the next track, prepared ahead while the first one plays. (The test segments are too
    // small for the meter to measure: per-track start-low after a measurement is
    // StartLowTrackSelectionTest's.)

    @Test
    fun theStandardPlayerAsksForTheFirstSegmentAtTheLowestRenditionHighestListedFirst() {
        val server = server(listOf("v192" to 192_000, "v128" to 128_000, "v064" to 64_000))
        load(standardPlayer(), server)
        assertEquals("v064", awaitFirstSegmentRendition(server))
    }

    @Test
    fun theStandardPlayerAsksForTheFirstSegmentAtTheLowestRenditionLowestListedFirst() {
        val server = server(listOf("v064" to 64_000, "v128" to 128_000, "v192" to 192_000))
        load(standardPlayer(), server)
        assertEquals("v064", awaitFirstSegmentRendition(server))
    }

    @Test
    fun theNextTrackPreparedAheadAlsoAsksForItsFirstSegmentAtTheLowestRendition() {
        // Every segment of the first track arrives, so the player goes on to the next one.
        val first = server(LADDER, segmentCount = 2, stalledFrom = 2)
        val second = server(LADDER)
        // The first track plays.
        load(standardPlayer(), first, second, play = true)
        assertEquals("v064", awaitFirstSegmentRendition(first))
        assertEquals("v064", awaitFirstSegmentRendition(second))
    }

    /** Segments from [stalledFrom] on never arrive (by default, none does arrive). */
    // The stall rule on the standard player (no command waits for its loads): a load whose media
    // never comes gives up at stallTimeoutMs, as a crossfade load does (ExoPlayer alone retried for
    // about 38 s), and the player stops asking for it. Load from idle, load while a track plays,
    // natural advance, and a retry after a give-up.

    @Test
    fun aStalledStandardLoadGivesUpAtTheStallTimeoutAndStopsLoading() {
        val stalled = server(LADDER)
        val watched = watchedStandardPlayer()
        load(watched.player, stalled, play = true)
        watched.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled)
    }

    @Test
    fun aStalledStandardLoadWhileATrackPlaysGivesUpAtTheStallTimeout() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val watched = watchedStandardPlayer()
        load(watched.player, playable, play = true)
        awaitTrue("the first track plays") { runBlocking(playerThread) { watched.player.currentPosition } >= PLAYED_MS }
        // The fan taps an uncached track (KotlinAudio's load replaces the item and prepares).
        runBlocking(playerThread) {
            watched.player.setMediaItem(hlsItem(stalled))
            watched.player.prepare()
        }
        watched.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled)
    }

    @Test
    fun aStalledNaturalAdvanceGivesUpAtTheStallTimeout() {
        // A one-segment track plays to its end; the next one's media never comes.
        val playable = server(LADDER, segmentCount = 1, stalledFrom = 1)
        val stalled = server(LADDER)
        val watched = watchedStandardPlayer()
        load(watched.player, playable, stalled, play = true)
        watched.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled)
        runBlocking(playerThread) { assertEquals(1, watched.player.currentMediaItemIndex) }
    }

    @Test
    fun aRetryAfterAGiveUpThatStallsAgainGivesUpAgain() {
        val stalled = server(LADDER)
        val watched = watchedStandardPlayer()
        load(watched.player, stalled, play = true)
        watched.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled)
        val requestsBefore = stalled.stalledRequestTimesMs.size
        // retry(): KotlinAudio prepares the same item again.
        runBlocking(playerThread) { watched.player.prepare() }
        awaitTrue("the retry asks for the segment again") { stalled.stalledRequestTimesMs.size > requestsBefore }
        watched.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled, givenUpBefore = 1)
    }

    private inner class WatchedPlayer(val player: ExoPlayer) {
        val gaveUpAtMs = java.util.Collections.synchronizedList(mutableListOf<Long>())
        /** When the player moved to another item (a natural advance): that item's load starts. */
        @Volatile
        var transitionAtMs = 0L

        init {
            player.addListener(object : Player.Listener {
                override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                    transitionAtMs = monotonicNowMs()
                }
            })
        }

        /** As KotlinAudioPlaybackBackend's give-up: the player stops (and reports, not here). */
        fun giveUp() {
            gaveUpAtMs += monotonicNowMs()
            player.playWhenReady = false
            player.stop()
        }

        fun assertGivesUpAtTheStallTimeoutAndStopsLoading(server: HlsTestServer, givenUpBefore: Int = 0) {
            awaitTrue("a give-up; requests ${server.requests}", AWAIT_MS) { gaveUpAtMs.size > givenUpBefore }
            val gaveUpAt = gaveUpAtMs[givenUpBefore]
            // The load starts at the stalled request, or at the item change when the request
            // went out earlier (the next item buffered ahead while the first one played).
            val requestAt = server.stalledRequestTimesMs.last { it <= gaveUpAt }
            val loadAt = maxOf(requestAt, transitionAtMs)
            assertTrue(
                "gave up ${gaveUpAt - loadAt}ms after the load began; stallTimeoutMs is $STALL_TIMEOUT_MS",
                gaveUpAt - loadAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS
            )
            val requestsAtGiveUp = server.stalledRequestTimesMs.size
            // ExoPlayer's default policy retries a failed request after 0, 1, 2 s...: wait past those.
            Thread.sleep(3 * STALL_TIMEOUT_MS)
            assertEquals("stalled requests after the give-up", requestsAtGiveUp, server.stalledRequestTimesMs.size)
            assertEquals("every stalled request is closed", server.stalledRequestTimesMs.size, server.stalledRequestClosedTimesMs.size)
            assertEquals("one give-up per load", givenUpBefore + 1, gaveUpAtMs.size)
            runBlocking(playerThread) { assertEquals(Player.STATE_IDLE, player.playbackState) }
        }
    }

    /** A standard player as the service builds it, with its load watch running on its thread. */
    private fun watchedStandardPlayer(): WatchedPlayer = runBlocking(playerThread) {
        val context = RuntimeEnvironment.getApplication()
        val bytes = LoadedBytes()
        val http = standardHttpDataSourceFactory({ STALL_TIMEOUT_MS }).invoke { }
        // As vendored KotlinAudio with the service's mediaTransferListener: only media requests
        // count their bytes (playlists and keys do not), the same split as the crossfade engines.
        val builder = ExoPlayer.Builder(context)
            .setLooper(thread.looper)
            .setMediaSourceFactory(CrossfadeMediaSourceFactory(playlistDataSourceFactory = http, mediaDataSourceFactory = http.countingBytes(bytes)))
        configureStandardExoPlayer(builder, context, { DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, StandardPlayerAnalytics())
        val player = builder.build().also { players += it }
        val watched = WatchedPlayer(player)
        val watch = StandardLoadWatch(stallTimeoutMs = { STALL_TIMEOUT_MS }, totalTimeoutMs = { PREPARE_TIMEOUT_MS })
        watches += CoroutineScope(playerThread).launch {
            watch.supervise(
                observe = { standardLoadObservation(player, player.currentMediaItem, bytes) },
                giveUp = { watched.giveUp() }
            )
        }
        watched
    }

    private fun hlsItem(server: HlsTestServer): MediaItem =
        MediaItem.Builder().setUri(server.masterUrl).setMimeType(MimeTypes.APPLICATION_M3U8).build()

    private fun awaitTrue(what: String, timeoutMs: Long = AWAIT_MS, condition: () -> Boolean) {
        val deadline = monotonicNowMs() + timeoutMs
        while (monotonicNowMs() < deadline) {
            if (condition()) return
            Thread.sleep(20)
        }
        fail("timed out waiting for $what")
    }

    private fun server(renditions: List<Pair<String, Int>>, segmentCount: Int = 2, stalledFrom: Int = 0): HlsTestServer =
        HlsTestServer(renditions, segmentCount, stalledFrom).also { servers += it }

    private fun standardPlayer(): ExoPlayer = runBlocking(playerThread) {
        val context = RuntimeEnvironment.getApplication()
        val builder = ExoPlayer.Builder(context).setLooper(thread.looper)
        configureStandardExoPlayer(builder, context, { DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, StandardPlayerAnalytics())
        builder.build().also { players += it }
    }

    private fun load(player: ExoPlayer, vararg servers: HlsTestServer, play: Boolean = false) = runBlocking(playerThread) {
        player.setMediaItems(servers.map(::hlsItem))
        player.playWhenReady = play
        player.prepare()
    }

    private fun awaitFirstSegmentRendition(server: HlsTestServer): String {
        val deadline = monotonicNowMs() + AWAIT_MS
        while (monotonicNowMs() < deadline) {
            server.segmentRenditions().firstOrNull()?.let { return it }
            Thread.sleep(20)
        }
        fail("timed out waiting for a segment request; requests: ${server.requests}")
        error("unreachable")
    }

    private companion object {
        const val TEST_DECODER = "test.aac.decoder"
        const val CODEC_BUFFER_BYTES = 100 * 1024
        val LADDER = listOf("v192" to 192_000, "v128" to 128_000, "v064" to 64_000)
        const val AWAIT_MS = 15_000L
        const val STALL_TIMEOUT_MS = 1_500L
        const val PREPARE_TIMEOUT_MS = 60_000L
        const val PLAYED_MS = 1_000L
        /** Time for the wait's poll and the threads around a give-up. */
        const val GIVE_UP_SLACK_MS = 750L
        const val CLOCK_TICK_MS = 5L
    }
}
