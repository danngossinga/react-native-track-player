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
    private val drivers = mutableListOf<StandardLoadDriver>()

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
            drivers.forEach { it.stop() }
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

    // Playlists and keys are a load's progress until its first segment is asked for (a slow proxy
    // answering them must not fail a healthy track), as on the crossfade path; every load counts
    // them again.

    @Test
    fun slowPlaylistsBeforeTheFirstSegmentDoNotMakeAHealthyStandardTrackGiveUp() {
        val slow = HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = STALL_TIMEOUT_MS * 3 / 4)
            .also { servers += it }
        val watched = watchedStandardPlayer()
        val startedAtMs = monotonicNowMs()
        load(watched.player, slow)
        awaitTrue("the track is ready") { runBlocking(playerThread) { watched.player.playbackState == Player.STATE_READY } }
        assertTrue("the playlists took longer than the stall timeout", monotonicNowMs() - startedAtMs > STALL_TIMEOUT_MS)
        assertEquals("no give-up", 0, watched.gaveUpAtMs.size)
    }

    @Test
    fun slowPlaylistsCountAgainForTheNextStandardTrack() {
        val first = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val watched = watchedStandardPlayer()
        load(watched.player, first)
        awaitTrue("the first track is ready") { runBlocking(playerThread) { watched.player.playbackState == Player.STATE_READY } }
        val slow = HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = STALL_TIMEOUT_MS * 3 / 4)
            .also { servers += it }
        // KotlinAudio's load: another item, prepared.
        runBlocking(playerThread) {
            watched.player.setMediaItem(hlsItem(slow))
            watched.player.prepare()
        }
        awaitTrue("the next track is ready") {
            runBlocking(playerThread) { watched.player.playbackState == Player.STATE_READY && watched.player.currentMediaItem?.localConfiguration?.uri.toString() == slow.masterUrl }
        }
        assertEquals("no give-up", 0, watched.gaveUpAtMs.size)
    }

    @Test
    fun aStalledStandardSeekGivesUpAtTheStallTimeoutAndStopsLoading() {
        // Segments from the fourth on (12 s) never come; the seek to 20 s stalls.
        val server = server(LADDER, segmentCount = 8, stalledFrom = 3)
        val watched = watchedStandardPlayer()
        load(watched.player, server)
        awaitTrue("the track is ready") { runBlocking(playerThread) { watched.player.playbackState == Player.STATE_READY } }
        val gate = watched.seekGate
        val seekPlayer = exoSeekPlayer(watched.player)
        val seekedAt = monotonicNowMs()
        val error = runBlocking(playerThread) {
            runCatching {
                try {
                    gate.seekOrGiveUp(seekPlayer, 20_000L) { watched.giveUp() }
                } finally {
                    watched.driver.poke()
                }
            }
        }.exceptionOrNull()
        assertEquals("standard_seek_timeout", (error as com.doublesymmetry.trackplayer.utils.RejectionException).code)
        assertTrue("gave up ${monotonicNowMs() - seekedAt}ms after the seek", monotonicNowMs() - seekedAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS)
        // The seek's give-up only: the load watch did not give up too (one report).
        watched.assertGivesUpAtTheStallTimeoutAndStopsLoading(server)
        // A failed seek keeps its target as the position (as the crossfade path and iOS).
        runBlocking(playerThread) { assertEquals(20_000L, watched.player.currentPosition) }
    }

    /** The seek gate's view of a plain ExoPlayer (KotlinAudio's adapter reads the same values). */
    private fun exoSeekPlayer(player: ExoPlayer) = object : StandardSeekPlayer {
        override val currentItem: Any? get() = player.currentMediaItem
        override val kotlinAudioState: com.doublesymmetry.kotlinaudio.models.AudioPlayerState
            get() = com.doublesymmetry.kotlinaudio.models.AudioPlayerState.READY
        override val exo: ExoSeekState = CapturedExoSeekState { player }
        override val positionMs: Long get() = player.currentPosition
        override val bufferedPositionMs: Long get() = player.bufferedPosition
        override val durationMs: Long get() = player.duration
        override val rate: Float get() = player.playbackParameters.speed
        override val autoTransitions: Long get() = 0L
        override fun prepare() = player.prepare()
        override fun seekTo(positionMs: Long) = player.seekTo(positionMs)
    }

    private inner class WatchedPlayer(val player: ExoPlayer, analytics: StandardPlayerAnalytics) {
        lateinit var driver: StandardLoadDriver
        val seekGate = StandardSeekGate(timeoutMs = { PREPARE_TIMEOUT_MS }, stallTimeoutMs = { STALL_TIMEOUT_MS })
        val gaveUpAtMs = java.util.Collections.synchronizedList(mutableListOf<Long>())
        /**
         * When ExoPlayer's playback thread had processed each give-up's stop (its clock): a
         * message sent right after stop() runs there after it (messages to a player run in order).
         */
        val stopProcessedAtMs = java.util.Collections.synchronizedList(mutableListOf<Long>())
        /** When the player started each media load (segment request), on its playback thread's clock. */
        val mediaLoadsStartedAtMs = java.util.Collections.synchronizedList(mutableListOf<Long>())
        /** When the player moved to another item (a natural advance): that item's load starts. */
        @Volatile
        var transitionAtMs = 0L

        init {
            analytics.addListener(object : com.google.android.exoplayer2.analytics.AnalyticsListener {
                override fun onLoadStarted(
                    eventTime: com.google.android.exoplayer2.analytics.AnalyticsListener.EventTime,
                    loadEventInfo: com.google.android.exoplayer2.source.LoadEventInfo,
                    mediaLoadData: com.google.android.exoplayer2.source.MediaLoadData
                ) {
                    if (mediaLoadData.dataType == com.google.android.exoplayer2.C.DATA_TYPE_MEDIA) mediaLoadsStartedAtMs += eventTime.realtimeMs
                }
            })
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
            player.createMessage { _, _ -> stopProcessedAtMs += android.os.SystemClock.elapsedRealtime() }.send()
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
            awaitTrue("the stop processed by the player") { stopProcessedAtMs.size > givenUpBefore }
            val stoppedAt = stopProcessedAtMs[givenUpBefore]
            // ExoPlayer's default policy retries a failed request after 0, 1, 2 s...: wait past those.
            Thread.sleep(3 * STALL_TIMEOUT_MS)
            // The player starts no load once it has stopped. (A stalled request's own read timeout
            // follows stallTimeoutMs, so it can expire at the give-up itself; ExoPlayer then starts
            // its immediate retry before it processes the stop, and that request reaches the server
            // a few milliseconds later: the server's arrival times cannot tell it from a request
            // made after the stop, the player's own load events can.)
            assertEquals(
                "media loads started after the stop (started ${mediaLoadsStartedAtMs.toList()}, stop processed at $stoppedAt; requests at ${server.stalledRequestTimesMs.map { it - gaveUpAt }} from the give-up)",
                0,
                mediaLoadsStartedAtMs.count { it > stoppedAt }
            )
            // No later request (a retry after a delay, another rendition): none arrives once the
            // stop's in-flight request could have.
            assertTrue(
                "stalled requests after the give-up: ${server.stalledRequestTimesMs.map { it - gaveUpAt }}",
                server.stalledRequestTimesMs.none { it - gaveUpAt > GIVE_UP_SLACK_MS }
            )
            assertEquals("every stalled request is closed", server.stalledRequestTimesMs.size, server.stalledRequestClosedTimesMs.size)
            // A request blocked in the network ends by its own read timeout, which follows
            // stallTimeoutMs (as on the crossfade path).
            assertTrue(
                "closed ${server.stalledRequestClosedTimesMs.map { it - gaveUpAt }}ms after the give-up",
                server.stalledRequestClosedTimesMs.all { it - gaveUpAt < STALL_TIMEOUT_MS + GIVE_UP_SLACK_MS }
            )
            assertEquals("one give-up per load", givenUpBefore + 1, gaveUpAtMs.size)
            runBlocking(playerThread) { assertEquals(Player.STATE_IDLE, player.playbackState) }
        }
    }

    /** A standard player as the service builds it, with its load watch running on its thread. */
    private fun watchedStandardPlayer(): WatchedPlayer = runBlocking(playerThread) {
        val context = RuntimeEnvironment.getApplication()
        val bytes = LoadedBytes()
        val http = standardHttpDataSourceFactory({ STALL_TIMEOUT_MS }).invoke { }
        // As vendored KotlinAudio with the service's transfer listeners: media bytes always,
        // playlists and keys until the first segment request, as the crossfade engines; each
        // item's own listeners, made when its source is built.
        val sources = object : com.google.android.exoplayer2.source.MediaSource.Factory {
            private val shared = CrossfadeMediaSourceFactory(playlistDataSourceFactory = http, mediaDataSourceFactory = http)
            override fun setDrmSessionManagerProvider(provider: com.google.android.exoplayer2.drm.DrmSessionManagerProvider) = this
            override fun setLoadErrorHandlingPolicy(policy: com.google.android.exoplayer2.upstream.LoadErrorHandlingPolicy) = this
            override fun getSupportedTypes(): IntArray = shared.supportedTypes
            override fun createMediaSource(mediaItem: MediaItem) =
                CrossfadeMediaSourceFactory(
                    playlistDataSourceFactory = http.countingBytes(bytes.playlists(mediaItem)),
                    mediaDataSourceFactory = http.countingBytes(bytes.media(mediaItem))
                ).createMediaSource(mediaItem)
        }
        val builder = ExoPlayer.Builder(context)
            .setLooper(thread.looper)
            .setMediaSourceFactory(sources)
        val analytics = StandardPlayerAnalytics()
        configureStandardExoPlayer(builder, context, { DEFAULT_INITIAL_BITRATE_ESTIMATE_BPS }, analytics)
        val player = builder.build().also { players += it }
        val watched = WatchedPlayer(player, analytics)
        val watch = StandardLoadWatch(stallTimeoutMs = { STALL_TIMEOUT_MS }, totalTimeoutMs = { PREPARE_TIMEOUT_MS }, onLoadStart = bytes::startLoad)
        // As KotlinAudioPlaybackBackend.startLoadWatch: the player's events and one timer while a
        // load is watched; a waited seek owns its loading.
        watched.driver = StandardLoadDriver(
            watch,
            Handler(thread.looper),
            observe = { standardLoadObservation(player, player.currentMediaItem, bytes, ownedElsewhere = watched.seekGate.isWaiting) },
            giveUp = { watched.giveUp() }
        ).also {
            drivers += it
            it.listenTo(analytics)
            it.poke()
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
