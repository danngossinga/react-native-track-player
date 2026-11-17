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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
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
        backends.forEach {
            it.eventScope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
            runCatching { it.player.destroy() }
        }
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
        // The fan taps an uncached track while the first one plays: the skip waits for its load
        // and, as a crossfade skip, rejects with the give-up (the rejection is the report: no
        // playback error event on top of it).
        backed.loadStartedAtMs = monotonicNowMs()
        var indexAtRejection: Int? = null
        val error = command {
            try {
                backed.backend.skip(1)
            } finally {
                indexAtRejection = backed.backend.currentIndex
            }
        } as RejectionException
        assertEquals(PREPARE_TIMEOUT_CODE, error.code)
        assertTrue("${error.message}", error.message!!.startsWith("The track did not become ready (no progress for $STALL_TIMEOUT_MS ms"))
        assertEquals("the active track when the skip rejected", 0, indexAtRejection)
        backed.assertGivesUpAtTheStallTimeoutAndStopsLoading(stalled)
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
        // The error the app reads (the backend's): the host's code as is, not
        // android-crossfade_prepare_timeout.
        assertEquals(PREPARE_TIMEOUT_CODE, backed.backend.playbackError?.code)
        assertEquals(PREPARE_TIMEOUT_CODE, standardPlaybackErrorCode(backed.player.playbackError!!))
        assertTrue("no playback error event", backed.player.event.playbackError.replayCache.isEmpty())
        // FailedLoadRule: the previous track is active again, and the failed one never reported.
        assertEquals("the active track", 0, backed.backend.currentIndex)
        assertEquals("the load failure names the active track", listOf<Int?>(0), backed.loadFailures)
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
        // The player itself is on the failed track, stopped there.
        assertEquals(1, backed.player.currentIndex)
    }

    // Skip, next, previous and load end as crossfade's: once the track loaded and is the active
    // one, or with the load's failure. Smart-music-player's sequence: set the queue, skip to the
    // selected track, then read the active index (paused: the load still happens).

    @Test
    fun aSkipAfterSettingTheQueueResolvesOnceTheTargetLoadedAndIsTheActiveTrack() {
        val backed = backed()
        backed.backend.replaceQueue(listOf(item(slowServer(), 1L), item(slowServer(), 2L), item(slowServer(), 3L)))
        val returned = backed.commandReading { backed.backend.skip(2) }
        assertEquals("the active track when skip returned", 2, returned.index)
        assertEquals("the player was ready when skip returned", com.google.android.exoplayer2.Player.STATE_READY, returned.exoState)
        assertEquals("reported before skip returned", 2, returned.reported.last())
        // Previous and next, as the music player's own previous and next.
        assertEquals("the active track when previous returned", 1, backed.commandReading { backed.backend.skipToPrevious() }.index)
        val next = backed.commandReading { backed.backend.skipToNext() }
        assertEquals("the active track when next returned", 2, next.index)
        assertEquals(com.google.android.exoplayer2.Player.STATE_READY, next.exoState)
        assertTrue(backed.gaveUpAtMs.isEmpty())
    }

    @Test
    fun whileATrackLoadsEveryReaderAgreesWithTheReportedTrack() {
        // Rule 13: while C loads, getActiveTrack is A, and so are the progress (A's last position
        // and duration, not C's) and the notification (KotlinAudio shows C at its transition).
        // C, not B: ExoPlayer buffers the next item ahead.
        val backed = backed()
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        backed.backend.add(listOf(item(playable, 1L), item(slowServer(), 2L), item(slowServer(), 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val durationOfA = backed.backend.durationMs
        assertTrue("A's duration is known", durationOfA > 0L)
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the player moved to C") { backed.player.currentIndex == 2 }
        val positionOfA = backed.backend.positionMs
        assertTrue("A's last position, $positionOfA ms", positionOfA >= PLAYED_MS)
        var sawLoading = false
        val deadline = monotonicNowMs() + AWAIT_MS
        while (skip() == null) {
            if (monotonicNowMs() >= deadline) fail("timed out waiting for the skip to C to end")
            shadowOf(Looper.getMainLooper()).idle()
            if (skip() != null) break
            if (backed.analytics.player?.playbackState == com.google.android.exoplayer2.Player.STATE_BUFFERING && backed.player.currentIndex == 2) {
                sawLoading = true
                assertEquals("the active track", 0, backed.backend.currentIndex)
                assertEquals("the position is A's last", positionOfA, backed.backend.positionMs)
                assertEquals("the duration is A's", durationOfA, backed.backend.durationMs)
                assertTrue("the buffered position is A's", backed.backend.bufferedMs >= positionOfA)
                assertSame("the notification shows A", backed.player.items[0], backed.player.notificationManager.overrideAudioItem)
            }
            Thread.sleep(CLOCK_TICK_MS)
        }
        assertTrue("C's load was seen", sawLoading)
        assertTrue(skip()!!.isSuccess)
        assertEquals(2, backed.backend.currentIndex)
        assertSame("the notification shows C once reported", backed.player.items[2], backed.player.notificationManager.overrideAudioItem)
        assertEquals(listOf<Pair<Int?, Boolean>>(0 to true, 2 to false), backed.nowPlayingShown)
        assertTrue("C's own position", backed.backend.positionMs < positionOfA)
    }

    @Test
    fun aSkipToTheFirstTrackOfANewQueueResolvesOnceItLoaded() {
        val backed = backed()
        backed.backend.replaceQueue(listOf(item(slowServer(), 1L), item(slowServer(), 2L)))
        // The new queue's first track is selected at once; the skip still waits for its load.
        val returned = backed.commandReading { backed.backend.skip(0) }
        assertEquals(0, returned.index)
        assertEquals("the player was ready when skip returned", com.google.android.exoplayer2.Player.STATE_READY, returned.exoState)
    }

    @Test
    fun aLoadIntoAnEmptyQueueResolvesOnceTheTrackLoaded() {
        val backed = backed()
        val returned = backed.commandReading { backed.backend.load(item(slowServer(), 1L)) }
        assertEquals(0, returned.index)
        assertEquals("the player was ready when load returned", com.google.android.exoplayer2.Player.STATE_READY, returned.exoState)
    }

    @Test
    fun aSkipToATrackThatFailsToLoadRejectsWithTheEngineErrorAndThePreviousTrackStaysActive() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val broken = HlsTestServer(LADDER, masterBody = "not a playlist").also { servers += it }
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(broken, 2L)))
        command { backed.backend.play() }
        awaitTrue("the first track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        var indexAtRejection: Int? = null
        val error = command {
            try {
                backed.backend.skip(1)
            } finally {
                indexAtRejection = backed.backend.currentIndex
            }
        } as RejectionException
        assertEquals("crossfade_engine_error", error.code)
        assertEquals(0, indexAtRejection)
        // The rejection is the report: the player's own error event is not the app's.
        assertTrue("the command reports the player's error", backed.backend.reportsPlayerErrorThroughCommand())
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
    }

    @Test
    fun aStopOrANewQueueEndsAWaitingSkipCancelled() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("the first track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        val stopped = launchCommand { backed.backend.skip(1) }
        awaitTrue("the stalled track loads") { stalled.stalledRequestTimesMs.isNotEmpty() }
        backed.backend.stop()
        awaitTrue("the skip ends") { stopped() != null }
        assertEquals("cancelled", (stopped()!!.exceptionOrNull() as RejectionException).code)
        val requests = stalled.stalledRequestTimesMs.size
        val replaced = launchCommand { backed.backend.skip(1) }
        awaitTrue("the stalled track loads again") { stalled.stalledRequestTimesMs.size > requests }
        backed.backend.replaceQueue(listOf(item(playable, 3L)))
        awaitTrue("the skip ends") { replaced() != null }
        assertEquals("cancelled", (replaced()!!.exceptionOrNull() as RejectionException).code)
        assertTrue("no give-up", backed.gaveUpAtMs.isEmpty())
    }

    @Test
    fun aGiveUpThatNoCommandWaitsForIsReportedAfterARejectedSkip() {
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.replaceQueue(listOf(item(stalled, 1L)))
        // The skip to the selected first track waits for its load, which gives up: the
        // rejection is the report.
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(0) } as RejectionException).code)
        assertTrue("no playback error event", backed.player.event.playbackError.replayCache.isEmpty())
        // A play retries the track that failed (none is active); nobody waits: a playback error.
        command { backed.backend.play() }
        awaitTrue("a second give-up", AWAIT_MS) { backed.gaveUpAtMs.size == 2 }
        assertEquals(PREPARE_TIMEOUT_CODE, backed.player.event.playbackError.replayCache.single().code)
        assertFalse("the app is told", backed.backend.reportsPlayerErrorThroughCommand())
    }

    @Test
    fun aNewerSkipCancelsTheWaitOfTheOlderOne() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L), item(slowServer(), 3L)))
        command { backed.backend.play() }
        awaitTrue("the first track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        val older = launchCommand { backed.backend.skip(1) }
        awaitTrue("the stalled track loads") { stalled.stalledRequestTimesMs.isNotEmpty() }
        assertNull("the older skip still waits", older())
        val newer = backed.commandReading { backed.backend.skip(2) }
        assertEquals(2, newer.index)
        assertEquals("cancelled", (older()!!.exceptionOrNull() as RejectionException).code)
        assertTrue("no give-up", backed.gaveUpAtMs.isEmpty())
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

    @Test
    fun aSeekEndsAtThePlayersEventNotAtItsNextSample() {
        // The seek samples the player every stallTimeoutMs / 10 (2 s here); the player's own
        // events (the backend's analytics listener) end it once it is at its target.
        val server = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val backed = backed(seekStallMs = 20_000L)
        backed.backend.add(listOf(item(server, 1L)))
        command { backed.backend.play() }
        awaitTrue("the track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        val started = monotonicNowMs()
        assertNull(command { backed.backend.seekTo(LOADABLE_TARGET_MS) })
        val tookMs = monotonicNowMs() - started
        assertTrue("the seek took $tookMs ms; it samples every 2000 ms", tookMs < 1_000L)
        assertTrue(backed.player.position >= LOADABLE_TARGET_MS)
    }

    // A track ExoPlayer cannot seek in (a raw ADTS stream with no length, as an internet radio's):
    // ExoPlayer lands its seek at the start and completes it there; the standard seek completes
    // where the player landed too (iOS: at AVPlayer's own seek completion), instead of waiting
    // for a target the player never reaches and giving up.

    @Test
    fun aSeekInATrackThePlayerCannotSeekInCompletesWhereThePlayerLands() {
        val server = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(TrackAudioItem(track = Track(queueId = 1L), type = MediaType.DEFAULT, audioUrl = server.streamUrl)))
        command { backed.backend.play() }
        awaitTrue("the stream plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        // Paused: the stream does not reach its end while the seek waits.
        backed.backend.pause()
        assertFalse("ExoPlayer cannot seek in the stream", backed.analytics.player!!.isCurrentMediaItemSeekable)
        val error = command { backed.backend.seekTo(STREAM_SEEK_TARGET_MS) }
        assertNull("the seek completes: $error", error)
        assertTrue("where ExoPlayer landed (the start): ${backed.player.position} ms", backed.player.position < PLAYED_MS)
        pump(STALL_TIMEOUT_MS)
        assertTrue("no give-up", backed.gaveUpAtMs.isEmpty())
        assertNull(backed.backend.playbackError)
        assertEquals(AudioPlayerState.READY, backed.backend.playbackState)
    }

    @Test
    fun clearingTheQueueAfterAGiveUpEndsTheError() {
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(stalled, 1L)))
        command { backed.backend.play() }
        awaitTrue("a give-up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
        // iOS: clearQueue clears hostFailure; no track, no error.
        backed.backend.clearQueue()
        pump(STALL_TIMEOUT_MS)
        assertEquals(AudioPlayerState.IDLE, backed.backend.playbackState)
        assertNull(backed.backend.playbackError)
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

    // A load's progress is the requests of the source ExoPlayer loads: new metadata for a track
    // (replace) gives KotlinAudio's queue another item, while ExoPlayer keeps loading the source
    // built for the first one.

    @Test
    fun aTrackWhoseMetadataWasReplacedStillCountsItsSlowPlaylists() {
        val slow = HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = STALL_TIMEOUT_MS * 3 / 4)
            .also { servers += it }
        val backed = backed()
        val first = item(slow, 1L)
        backed.backend.add(listOf(first))
        backed.backend.replace(0, first.copy(title = "New title"))
        val startedAtMs = monotonicNowMs()
        command { backed.backend.play() }
        awaitTrue("the track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertTrue("the playlists took longer than the stall timeout", monotonicNowMs() - startedAtMs > STALL_TIMEOUT_MS)
        assertTrue("no give-up", backed.gaveUpAtMs.isEmpty())
        assertNull(backed.backend.playbackError)
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

    // Smart-music-player's rollback after a skip that failed (skipWithRollback, then
    // restorePlaybackIntent): it seeks to the position it captured, then plays. Owner decision,
    // 2026-11-17 (LOAD-06 flipped, changed deliberately; it acted on the player's own, failed
    // track before): the seek acts on the active track, the one the app reads (getActiveTrack
    // and its position), as crossfade's: the player goes back to A, paused, at the seek's target;
    // the play plays A from there. iOS: StandardLoadCoordinator.beginSeek, stop.

    @Test
    fun aSeekAfterASkipThatGaveUpActsOnThePreviousTrackAndThePlayPlaysIt() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        // SMP reads the position before the skip's bridge hop; playing, the track moved on since.
        val captured = backed.backend.positionMs - CAPTURE_LAG_MS
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        assertEquals(0, backed.backend.currentIndex)
        assertEquals(1, backed.player.currentIndex)
        assertNull("the seek acts on A, which loads", command { backed.backend.seekTo(captured) })
        // Changed deliberately (owner decision, 2026-11-17): 1 (the failed track) -> 0.
        assertEquals("the track the seek acted on", 0, backed.player.currentIndex)
        assertEquals("the active track after the seek", 0, backed.backend.currentIndex)
        assertTrue("at the seek's target: ${backed.player.position}", backed.player.position >= captured)
        assertFalse("paused, as a crossfade operation that went back", backed.backend.playWhenReady)
        assertNull("the give-up's error ended", backed.backend.playbackError)
        val playableRequests = playable.requests.size
        assertNull(command { backed.backend.play() })
        awaitTrue("A plays") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        pump(STALL_TIMEOUT_MS * 2)
        assertEquals(0, backed.player.currentIndex)
        assertEquals(0, backed.backend.currentIndex)
        assertEquals(AudioPlayerState.PLAYING, backed.backend.playbackState)
        assertTrue("from the seek's target: ${backed.player.position}", backed.player.position >= captured)
        assertTrue("A loaded", playable.requests.size >= playableRequests)
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
    }

    @Test
    fun aStopAfterASkipThatGaveUpStopsOnThePreviousTrackAndThePlayReloadsIt() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        val positionOfA = backed.backend.positionMs
        backed.backend.stop()
        assertEquals("the stop goes back to A", 0, backed.player.currentIndex)
        pump(STALL_TIMEOUT_MS)
        // Every reader agrees with the stop (rule 13; iOS: stopped): the state the app was told last.
        assertEquals(AudioPlayerState.STOPPED, backed.backend.playbackState)
        assertEquals("state:STOPPED", backed.events.last { it.startsWith("state:") })
        assertEquals(0, backed.backend.currentIndex)
        val playableRequests = playable.requests.size
        assertNull(command { backed.backend.play() })
        awaitTrue("the play reloads A") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        assertTrue("A loaded again", playable.requests.size > playableRequests)
        assertTrue("from A's last position (${backed.player.position} ms, left at $positionOfA ms)", backed.player.position >= positionOfA)
        pump(STALL_TIMEOUT_MS)
        assertEquals(0, backed.player.currentIndex)
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
    }

    // A skip or next to the track that failed, which the player is still on (no move: ExoPlayer
    // stays on its item), loads it again and ends once it loaded and is reported (FailedLoadRule
    // .skipped, LOAD-16); a seek or stop goes back to the active track instead (command).

    @Test
    fun aNextToTheTrackThatFailedLoadsItAgainAndReportsIt() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val flaky = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(flaky, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skipToNext() } as RejectionException).code)
        assertEquals(1, backed.player.currentIndex)
        assertEquals(0, backed.backend.currentIndex)
        flaky.recovered = true
        // Next from the active track A: B again, the player's own item (no move).
        val returned = backed.commandReading { backed.backend.skipToNext() }
        assertEquals("the active track when next returned", 1, returned.index)
        assertEquals("the player was ready when next returned", com.google.android.exoplayer2.Player.STATE_READY, returned.exoState)
        assertEquals("B reported once it loaded", listOf<Int?>(0, 1), returned.reported)
    }

    // A seek that acts on a track that failed to load (none active: the failed first track,
    // retried) and whose playlists never answer (no item, nothing loaded): the seek is never at
    // its target and gives up by its own limits, whichever ends first (stallTimeoutMs, or
    // standardSeekTimeoutMs set apart from prepareTimeoutMs, shorter or longer): it stops the
    // track's load, fails it again, and the player is in error, reported by the seek's rejection
    // only (no playback error, then or once prepareTimeoutMs passed); the play retries it.
    // Changed deliberately (owner decision, 2026-11-17): after a failed skip the seek acts on the
    // active track (above), so these run on a failed first track. iOS:
    // StandardLoadCoordinator.seekTimedOut (the same, the seek issued or not).

    @Test
    fun aSeekOnATrackWhosePlaylistsNeverAnswerGivesUpAtTheStallTimeoutAndLeavesThePlayToRetryIt() {
        assertASeekOnATrackWhosePlaylistsNeverAnswerGivesUp(backed(), "The native seek made no progress for $STALL_TIMEOUT_MS ms.")
    }

    @Test
    fun aSeekWithALimitShorterThanTheStallTimeoutGivesUpAtItsLimit() {
        val seekTimeoutMs = STALL_TIMEOUT_MS / 2
        assertASeekOnATrackWhosePlaylistsNeverAnswerGivesUp(
            backed(seekTimeoutMs = seekTimeoutMs),
            "The native seek did not complete within $seekTimeoutMs ms."
        )
    }

    @Test
    fun aSeekWithALimitLongerThanTheLoadsGivesUpByItsOwnAndTheLoadLimitAddsNothing() {
        // The load's total limit (shorter than the seek's limits, and than stallTimeoutMs: the
        // first load gives up by it) ends neither the seek, which owns the track's loading, nor,
        // later, the track the seek gave up on.
        assertASeekOnATrackWhosePlaylistsNeverAnswerGivesUp(
            backed(seekTimeoutMs = PREPARE_TIMEOUT_MS, loadTimeoutMs = STALL_TIMEOUT_MS * 2 / 3),
            "The native seek made no progress for $STALL_TIMEOUT_MS ms."
        )
    }

    private fun assertASeekOnATrackWhosePlaylistsNeverAnswerGivesUp(backed: Backed, message: String) {
        val silent = HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = 600_000L).also { servers += it }
        backed.backend.add(listOf(item(silent, 1L)))
        command { backed.backend.play() }
        awaitTrue("the first load gives up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        assertEquals("none active", -1, backed.backend.currentIndex)
        val beforeSeek = backed.events.size
        val seekError = command { backed.backend.seekTo(LOADABLE_TARGET_MS) } as? RejectionException
        assertEquals("standard_seek_timeout", seekError?.code)
        assertEquals(message, seekError?.message)
        assertEquals("the track the seek acted on (none active: the failed one)", 0, backed.player.currentIndex)
        // Its load stopped, in error with the seek's failure until the next command.
        backed.assertStaysInError("standard_seek_timeout")
        assertEquals(com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
        pump(STALL_TIMEOUT_MS * 3)
        val emitted = backed.events.drop(beforeSeek).filter { it == "state:ERROR" || it.startsWith("error:") }
        assertEquals("one error state, no playback error", listOf("state:ERROR"), emitted)
        assertEquals(-1, backed.backend.currentIndex)
        val requests = silent.requests.size
        assertNull(command { backed.backend.play() })
        awaitTrue("the play retries it") { silent.requests.size > requests }
        assertEquals(0, backed.player.currentIndex)
        assertEquals("never reported but at its selection", listOf<Int?>(0, null), backed.activeTrackChanges.map { it.first })
    }

    @Test
    fun aSeekAfterASkipThatFailedWithAPlayerErrorActsOnThePreviousTrack() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val broken = HlsTestServer(LADDER, masterBody = "not a playlist").also { servers += it }
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(broken, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val captured = backed.backend.positionMs - CAPTURE_LAG_MS
        assertEquals(STANDARD_LOAD_ERROR_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        // Changed deliberately (owner decision, 2026-11-17): the seek rejected
        // standard_seek_unavailable on the failed track (1); it now acts on A (0) and succeeds.
        assertNull("the seek acts on A", command { backed.backend.seekTo(captured) })
        assertEquals("the track the seek acted on", 0, backed.player.currentIndex)
        assertTrue("at the seek's target: ${backed.player.position}", backed.player.position >= captured)
        assertFalse("paused", backed.backend.playWhenReady)
        assertNull(command { backed.backend.play() })
        awaitTrue("A plays") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals(0, backed.backend.currentIndex)
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
    }

    // A seek, pause or stop while a skip's track loads cancels the skip (it rejects `cancelled`)
    // and, as crossfade's operation cancelled while it loads, the rejected skip does not take
    // effect: the player goes back to the active track, paused (the seek acts there), and the
    // skip's track is never reported.

    @Test
    fun aSeekDuringASkipsLoadCancelsTheSkipAndActsOnTheActiveTrack() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val target = slowServer()
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(slowServer(), 2L), item(target, 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the player moved to C") { backed.player.currentIndex == 2 }
        // The seek goes back to A at once (then waits for its target there).
        val seek = launchCommand { backed.backend.seekTo(LOADABLE_TARGET_MS) }
        val jumpedBack = backed.markProcessed()
        awaitTrue("the seek ends") { seek() != null }
        assertTrue("the seek succeeded: ${seek()}", seek()!!.isSuccess)
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        backed.assertTheSkipsLoadEnded(target, jumpedBack)
        assertEquals("the track the seek acted on", 0, backed.player.currentIndex)
        assertEquals(0, backed.backend.currentIndex)
        assertTrue("at the seek's target: ${backed.player.position}", backed.player.position >= LOADABLE_TARGET_MS)
        assertFalse("paused, as a crossfade operation cancelled while it loads", backed.backend.playWhenReady)
        assertEquals("C is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
        assertEquals(0, backed.backend.currentIndex)
    }

    @Test
    fun aPauseDuringASkipsLoadCancelsTheSkipAndThePlayResumesTheActiveTrack() {
        assertACommandDuringASkipsLoadLeavesTheActiveTrack { it.pause() }
    }

    @Test
    fun aStopDuringASkipsLoadCancelsTheSkipAndThePlayResumesTheActiveTrack() {
        assertACommandDuringASkipsLoadLeavesTheActiveTrack { it.stop() }
    }

    // The race behind the earlier flake, made certain: the pause lands while the skip's track is
    // still fetching its playlists (ExoPlayer started that fetch before it processed the jump back).
    @Test
    fun aPauseWhileTheSkipsTrackFetchesItsPlaylistsLoadsNoneOfItsMedia() {
        val target = HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = STALL_TIMEOUT_MS / 4)
            .also { servers += it }
        assertACommandDuringASkipsLoadLeavesTheActiveTrack(target, interruptOnceRequested = true) { it.pause() }
    }

    @Test
    fun aStopWhileTheSkipsTrackFetchesItsPlaylistsLoadsNoneOfItsMedia() {
        val target = HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = STALL_TIMEOUT_MS / 4)
            .also { servers += it }
        assertACommandDuringASkipsLoadLeavesTheActiveTrack(target, interruptOnceRequested = true) { it.stop() }
    }

    // The cancelled track's source is released when the player goes back to the active track: a
    // playlist request under way at the pause or seek is the last request of that track (no
    // media playlist follows it), as iOS and crossfade.

    @Test
    fun aPauseWhileTheSkipsTrackFetchesItsPlaylistsFetchesNothingMoreOfIt() {
        assertTheSkipsTrackFetchesNothingMore { backend -> backend.pause(); null }
    }

    @Test
    fun aSeekWhileTheSkipsTrackFetchesItsPlaylistsFetchesNothingMoreOfIt() {
        assertTheSkipsTrackFetchesNothingMore { backend -> launchCommand { backend.seekTo(LOADABLE_TARGET_MS) } }
    }

    private fun assertTheSkipsTrackFetchesNothingMore(interrupt: (KotlinAudioPlaybackBackend) -> (() -> Result<Unit>?)?) {
        val target = HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = STALL_TIMEOUT_MS / 4).also { servers += it }
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(slowServer(), 2L), item(target, 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the player moved to C") { backed.player.currentIndex == 2 }
        awaitTrue("C asked for its master playlist") { target.requests.isNotEmpty() }
        val atInterrupt = target.requests.toList()
        val seek = interrupt(backed.backend)
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        if (seek != null) awaitTrue("the seek ends") { seek() != null }
        pump(STALL_TIMEOUT_MS * 4)
        assertEquals("C's requests after the interrupt (C's segments: ${target.segmentRenditions()})", atInterrupt, target.requests.toList())
        assertEquals("only its master playlist was asked for", listOf("/master.m3u8"), atInterrupt)
        assertEquals("the player's track", 0, backed.player.currentIndex)
        assertEquals("C is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
        assertEquals("the queue is unchanged", listOf(1L, 2L, 3L), backed.player.items.map { (it as TrackAudioItem).track.queueId })
    }

    // With no reported track (the first track's load failed): the command that cancels the skip
    // stops the skip's load and leaves no active track, as crossfade's operation cancelled with
    // no current track (active index -1): the skip's track is never loaded on or reported, and
    // a play starts the first track, as crossfade's play from idle.

    @Test
    fun aPauseCancellingASkipWithNoActiveTrackStopsItsLoadAndNeverReportsIt() {
        val stalled = server(LADDER)
        val b = slowServer()
        val backed = backed()
        backed.backend.add(listOf(item(stalled, 1L), item(b, 2L)))
        command { backed.backend.play() }
        awaitTrue("a give-up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        assertEquals(-1, backed.backend.currentIndex)
        val skip = launchCommand { backed.backend.skip(1) }
        awaitTrue("the player moved to B") { backed.player.currentIndex == 1 }
        awaitTrue("B requested") { b.requests.isNotEmpty() }
        assertNull("the skip still waits", skip())
        backed.backend.pause()
        val stopped = backed.markProcessed()
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        backed.assertTheSkipsLoadEnded(b, stopped)
        pump(STALL_TIMEOUT_MS * 3)
        assertEquals("the cancelled skip's track is never reported", listOf<Int?>(0, null), backed.activeTrackChanges.map { it.first })
        assertEquals(-1, backed.backend.currentIndex)
        assertEquals("B's load stopped", com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
        // Every reader agrees with the state event the stop emitted (rule 13): stopped.
        assertEquals(AudioPlayerState.STOPPED, backed.backend.playbackState)
        assertEquals("state:STOPPED", backed.events.last { it.startsWith("state:") })
        assertFalse(backed.backend.playWhenReady)
        assertEquals(0L, backed.backend.positionMs)
    }

    @Test
    fun aStopCancellingASkipWithNoActiveTrackThenAPlayStartsTheFirstTrack() {
        // A's load fails (none active), a skip to B fails too, a skip to C waits: the stop cancels
        // it. The play then starts the first track (crossfade's play with no active track, on
        // both platforms), not C, nor B (the last track that failed).
        val stalledA = server(LADDER)
        val stalledB = server(LADDER)
        val c = slowServer()
        val backed = backed()
        backed.backend.add(listOf(item(stalledA, 1L), item(stalledB, 2L), item(c, 3L)))
        command { backed.backend.play() }
        awaitTrue("a give-up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        assertEquals(-1, backed.backend.currentIndex)
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the player moved to C") { backed.player.currentIndex == 2 }
        awaitTrue("C requested") { c.requests.isNotEmpty() }
        backed.backend.stop()
        val stopped = backed.markProcessed()
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        backed.assertTheSkipsLoadEnded(c, stopped)
        assertEquals(-1, backed.backend.currentIndex)
        val beforePlay = backed.activeTrackChanges.size
        assertNull(command { backed.backend.play() })
        assertEquals("the play starts the first track", 0, backed.player.currentIndex)
        pump(STALL_TIMEOUT_MS * 3)
        assertEquals(listOf<Int?>(0, null), backed.activeTrackChanges.take(beforePlay).map { it.first })
        assertFalse(
            "the cancelled skip's track (and the one that failed) is never reported: ${backed.activeTrackChanges}",
            backed.activeTrackChanges.any { it.first == 1 || it.first == 2 }
        )
        backed.assertTheSkipsLoadEnded(c, stopped)
    }

    @Test
    fun aSeekCancellingASkipWithNoActiveTrackRejectsAndLoadsNothing() {
        val stalled = server(LADDER)
        val b = slowServer()
        val backed = backed()
        backed.backend.add(listOf(item(stalled, 1L), item(b, 2L)))
        command { backed.backend.play() }
        awaitTrue("a give-up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        val skip = launchCommand { backed.backend.skip(1) }
        awaitTrue("the player moved to B") { backed.player.currentIndex == 1 }
        awaitTrue("B requested") { b.requests.isNotEmpty() }
        val seekError = command { backed.backend.seekTo(LOADABLE_TARGET_MS) }
        val stopped = backed.markProcessed()
        assertEquals("no active track to seek in", STANDARD_SEEK_UNAVAILABLE_CODE, (seekError as RejectionException).code)
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        backed.assertTheSkipsLoadEnded(b, stopped)
        pump(STALL_TIMEOUT_MS * 3)
        assertEquals("the cancelled skip's track is never reported", listOf<Int?>(0, null), backed.activeTrackChanges.map { it.first })
        assertEquals(-1, backed.backend.currentIndex)
        assertEquals(com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
    }

    // A relative seek while a skip's track loads is relative to the position the app reads: the
    // active track's (rule 13), where the seek acts (the skip cancelled), as crossfade's seekBy.

    @Test
    fun aSeekByDuringASkipsLoadIsRelativeToTheActiveTracksPosition() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(slowServer(), 2L), item(slowServer(), 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays past 3 s") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= 3_000L }
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the player moved to C") { backed.player.currentIndex == 2 }
        val positionOfA = backed.backend.positionMs
        assertTrue("A's position is read while C loads: $positionOfA", positionOfA >= 3_000L)
        val seek = launchCommand { backed.backend.seekBy(SEEK_BY_MS) }
        awaitTrue("the seek ends") { seek() != null }
        assertTrue("the seek succeeded: ${seek()}", seek()!!.isSuccess)
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        assertEquals("the track the seek acted on", 0, backed.player.currentIndex)
        assertFalse("paused", backed.backend.playWhenReady)
        assertEquals("relative to A's $positionOfA ms", positionOfA + SEEK_BY_MS, backed.player.position)
        assertEquals(positionOfA + SEEK_BY_MS, backed.backend.positionMs)
    }

    private fun assertACommandDuringASkipsLoadLeavesTheActiveTrack(
        target: HlsTestServer = slowServer(),
        /** Interrupt once the skip's track asked for its master playlist (still answering). */
        interruptOnceRequested: Boolean = false,
        interrupt: (KotlinAudioPlaybackBackend) -> Unit
    ) {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(slowServer(), 2L), item(target, 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the player moved to C") { backed.player.currentIndex == 2 }
        if (interruptOnceRequested) awaitTrue("C asked for its master playlist") { target.requests.isNotEmpty() }
        val positionOfA = backed.backend.positionMs
        interrupt(backed.backend)
        val jumpedBack = backed.markProcessed()
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        backed.assertTheSkipsLoadEnded(target, jumpedBack)
        if (interruptOnceRequested) {
            // The race made certain: only C's master playlist had been asked for at the jump back.
            assertEquals(
                listOf(target.masterUrl),
                backed.loads.loadsBefore(jumpedBack, target).map { it.uri }
            )
        }
        assertEquals("the player's track", 0, backed.player.currentIndex)
        assertEquals(0, backed.backend.currentIndex)
        assertFalse(backed.backend.playWhenReady)
        assertNull(command { backed.backend.play() })
        awaitTrue("A plays again") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        assertTrue("from A's last position (${backed.player.position} ms, left at $positionOfA ms)", backed.player.position >= positionOfA)
        pump(STALL_TIMEOUT_MS)
        assertEquals("C is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
        assertEquals(0, backed.backend.currentIndex)
    }

    // After a give-up (iOS: the same, StandardGiveUps): a pause keeps the error, a stop ends it
    // with the stopped state, which the app is told. A give-up no command waits for emits the
    // error state, then the playback error (as the crossfade path on both platforms).

    @Test
    fun afterAGiveUpAPauseKeepsTheErrorAndAStopEndsItStopped() {
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(stalled, 1L)))
        command { backed.backend.play() }
        awaitTrue("a give-up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
        val beforePause = backed.events.size
        backed.backend.pause()
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
        assertEquals("no state event at the pause", emptyList<String>(), backed.events.drop(beforePause).filter { it.startsWith("state") })
        val beforeStop = backed.events.size
        backed.backend.stop()
        pump(STALL_TIMEOUT_MS)
        assertEquals(AudioPlayerState.STOPPED, backed.player.playerState)
        assertEquals(AudioPlayerState.STOPPED, backed.backend.playbackState)
        assertEquals("the stop is emitted", listOf("state:STOPPED"), backed.events.drop(beforeStop).filter { it.startsWith("state") })
    }

    @Test
    fun aPlayerErrorNoCommandWaitsForEmitsTheErrorStateThenThePlaybackError() {
        // ExoPlayer's own error (a master playlist it cannot parse), as a give-up: state, then
        // error (KotlinAudio emitted the error first; iOS and the crossfade path: state first).
        val broken = HlsTestServer(LADDER, masterBody = "not a playlist").also { servers += it }
        val backed = backed()
        backed.backend.add(listOf(item(broken, 1L)))
        val before = backed.events.size
        command { backed.backend.play() }
        awaitTrue("a player error") { backed.player.playerState == AudioPlayerState.ERROR }
        pump(STALL_TIMEOUT_MS)
        assertFalse("no command waits for the load", backed.backend.reportsPlayerErrorThroughCommand())
        val emitted = backed.events.drop(before).filter { it == "state:ERROR" || it.startsWith("error:") }
        assertEquals(listOf("state:ERROR", "error:parsing-manifest-malformed"), emitted)
    }

    @Test
    fun aGiveUpEmitsTheErrorStateThenThePlaybackError() {
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(stalled, 1L)))
        val before = backed.events.size
        command { backed.backend.play() }
        awaitTrue("a give-up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        pump(STALL_TIMEOUT_MS)
        val emitted = backed.events.drop(before).filter { it == "state:ERROR" || it.startsWith("error:") }
        assertEquals(listOf("state:ERROR", "error:$PREPARE_TIMEOUT_CODE"), emitted)
    }

    /** The standard backend and its player, as MusicService.createPlaybackBackend builds them. */
    private inner class Backed(
        seekStallMs: Long = STALL_TIMEOUT_MS,
        /** standardSeekTimeoutMs (the app sets it apart from prepareTimeoutMs). */
        seekTimeoutMs: Long = PREPARE_TIMEOUT_MS,
        /** prepareTimeoutMs: a load's total limit. */
        loadTimeoutMs: Long = PREPARE_TIMEOUT_MS
    ) {
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
        /** The player's load starts in order, with where it had processed each give-up's stop. */
        val loads = PlayerLoadLog().also(analytics::addListener)
        val stopsProcessed = java.util.Collections.synchronizedList(mutableListOf<PlayerLoadLog.Marker>())
        val activeTrackChanges = mutableListOf<Pair<Int?, Int?>>()
        val loadFailures = mutableListOf<Int?>()
        /** What the notification was told to show (MusicService's onNowPlaying), in order. */
        val nowPlayingShown = mutableListOf<Pair<Int?, Boolean>>()
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
            seekGate = StandardSeekGate(timeoutMs = { seekTimeoutMs }, stallTimeoutMs = { seekStallMs }),
            analytics = { analytics },
            onActiveTrackChanged = { index, lastIndex, _, _ -> activeTrackChanges += index to lastIndex },
            onLoadFailed = { activeIndex ->
                // Called right after the give-up stopped the player (a load the watch gave up).
                gaveUpAtMs += monotonicNowMs()
                loadFailures += activeIndex
                markStopProcessed()
            },
            // As MusicService: the notification shows the reported track (KotlinAudio's override).
            onNowPlaying = { index, held ->
                nowPlayingShown += index to held
                if (index != null) player.notificationManager.overrideMetadata(player.items[index])
                else player.notificationManager.overrideAudioItem = null
            },
            loadWatch = StandardLoadWatch(
                stallTimeoutMs = { STALL_TIMEOUT_MS },
                totalTimeoutMs = { loadTimeoutMs },
                onLoadStart = analytics::startLoad
            ),
            initiallyAuthoritative = true
        ).also { it.startLoadWatch(Handler(Looper.getMainLooper())) }

        /**
         * KotlinAudio's state and playback-error events in the order MusicService emits them to
         * JS (PLAYBACK_STATE, PLAYBACK_ERROR): "state:<state>", "error:<code>". Collected as
         * MusicService's observeEvents does (its MainScope, collectWithAdmission, admitted);
         * both flows replay their last value at subscription, recorded too.
         */
        val events: MutableList<String> = java.util.Collections.synchronizedList(mutableListOf())
        val eventScope = kotlinx.coroutines.MainScope()

        init {
            val admission = SharedFlowAdmissionGate().also { it.admit() }
            eventScope.collectWithAdmission(player.event.stateChange, admission) { events += "state:$it" }
            eventScope.collectWithAdmission(player.event.playbackError, admission) { events += "error:${it.code}" }
        }

        /** What a command left when it returned (or threw), read at that moment. */
        inner class Returned(val index: Int, val exoState: Int, val reported: List<Int?>)

        /** Runs a command that must succeed; what it left when it returned. */
        fun commandReading(block: suspend () -> Unit): Returned {
            var returned: Returned? = null
            val error = command {
                block()
                returned = Returned(backend.currentIndex, analytics.player!!.playbackState, activeTrackChanges.map { it.first })
            }
            assertNull("the command failed: $error", error)
            return returned!!
        }

        /** Marks where the player had processed the commands issued so far (a stop, a jump). */
        fun markProcessed(): PlayerLoadLog.Marker = loads.mark(analytics.player as ExoPlayer)

        fun markStopProcessed() {
            stopsProcessed += markProcessed()
        }

        /**
         * A command that cancelled a skip while its track ([server]) loads made the player go
         * back to the active track ([jumpedBack]: marked right after the command): from the point
         * where the player processed that, no load of the skip's track is part of its playback (a segment, or any
         * load of one of its media periods), and the server got no segment request for it that
         * the player had not started before. The cancelled track's source is released (a stop
         * releases every source; a pause or seek, KotlinAudio's releaseSource), so not even its
         * playlists are fetched any more (a*FetchesNothingMoreOfIt); iOS: SwiftAudioEx's load of
         * the active track cancels the skip's asset loading and removes its item.
         */
        fun assertTheSkipsLoadEnded(server: HlsTestServer, jumpedBack: PlayerLoadLog.Marker) {
            awaitTrue("the jump back processed by the player") { jumpedBack.reached }
            // Past the slow server's segment delay: a period still loading would ask for more.
            pump(STALL_TIMEOUT_MS)
            val after = loads.loadsAfter(jumpedBack, server)
            assertEquals(
                "loads of the skip's track by a media period or for media after the jump back: $after (before: ${loads.loadsBefore(jumpedBack, server)}; requests ${server.requests})",
                emptyList<PlayerLoadLog.LoadStart>(),
                after.filter { it.isMedia || it.ofAMediaPeriod }
            )
            assertTrue(
                "segment requests ${server.segmentRenditions()} vs media loads started before the jump back ${loads.loadsBefore(jumpedBack, server).filter { it.isMedia }}",
                server.segmentRenditions().size <= loads.loadsBefore(jumpedBack, server).count { it.isMedia }
            )
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
            awaitTrue("the stop processed by the player") { stopsProcessed.firstOrNull()?.reached == true }
            val stopped = stopsProcessed.first()
            // ExoPlayer's default policy retries a failed request after 0, 1, 2 s...: wait past those.
            pump(3 * STALL_TIMEOUT_MS)
            assertEquals(
                "media loads started after the stop (requests at ${server.stalledRequestTimesMs.map { it - gaveUpAt }} from the give-up)",
                emptyList<PlayerLoadLog.LoadStart>(),
                loads.mediaLoadsAfter(stopped)
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

    private fun backed(
        seekStallMs: Long = STALL_TIMEOUT_MS,
        seekTimeoutMs: Long = PREPARE_TIMEOUT_MS,
        loadTimeoutMs: Long = PREPARE_TIMEOUT_MS
    ): Backed = Backed(seekStallMs, seekTimeoutMs, loadTimeoutMs).also { backends += it }

    private fun item(server: HlsTestServer, queueId: Long) =
        TrackAudioItem(track = Track(queueId = queueId), type = MediaType.HLS, audioUrl = server.masterUrl)

    /** Runs a backend command on the main thread (the service's), to its end; its error, if any. */
    private fun command(block: suspend () -> Unit): Throwable? {
        var result: Result<Unit>? = null
        CoroutineScope(Dispatchers.Main.immediate).launch { result = runCatching { block() } }
        awaitTrue("the command ends", AWAIT_MS) { result != null }
        return result!!.exceptionOrNull()
    }

    /** Starts a backend command on the main thread; its result once it ended (null before). */
    private fun launchCommand(block: suspend () -> Unit): () -> Result<Unit>? {
        var result: Result<Unit>? = null
        CoroutineScope(Dispatchers.Main.immediate).launch { result = runCatching { block() } }
        return { result }
    }

    /** A track whose segments each take a while (well under stallTimeoutMs): its load is seen. */
    private fun slowServer(): HlsTestServer =
        HlsTestServer(LADDER, segmentCount = 8, stalledFrom = 8, segmentDelayMs = STALL_TIMEOUT_MS / 3).also { servers += it }

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
        /** Within [HlsTestServer.streamUrl]'s audio, past where the stream was paused. */
        const val STREAM_SEEK_TARGET_MS = 3_000L
        /** How far a playing track moved on between SMP's position read and its skip. */
        const val CAPTURE_LAG_MS = 300L
        /** A relative seek (seekBy), within A's loaded segments. */
        const val SEEK_BY_MS = 2_000L
        /** Time for the watch's sampling and the threads around a give-up. */
        const val GIVE_UP_SLACK_MS = 750L
        const val CLOCK_TICK_MS = 5L
    }
}
