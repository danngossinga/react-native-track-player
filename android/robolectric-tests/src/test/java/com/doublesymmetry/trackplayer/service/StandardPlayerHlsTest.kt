package com.doublesymmetry.trackplayer.service

import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.util.MimeTypes
import kotlinx.coroutines.android.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
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
        runBlocking(playerThread) { players.forEach { it.release() } }
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
    private fun server(renditions: List<Pair<String, Int>>, segmentCount: Int = 2, stalledFrom: Int = 0): HlsTestServer =
        HlsTestServer(renditions, segmentCount, stalledFrom).also { servers += it }

    private fun standardPlayer(): ExoPlayer = runBlocking(playerThread) {
        val context = RuntimeEnvironment.getApplication()
        val builder = ExoPlayer.Builder(context).setLooper(thread.looper)
        configureStandardExoPlayer(builder, context, { DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, StandardPlayerAnalytics())
        builder.build().also { players += it }
    }

    private fun load(player: ExoPlayer, vararg servers: HlsTestServer, play: Boolean = false) = runBlocking(playerThread) {
        player.setMediaItems(servers.map { MediaItem.Builder().setUri(it.masterUrl).setMimeType(MimeTypes.APPLICATION_M3U8).build() })
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
        const val CLOCK_TICK_MS = 5L
    }
}
