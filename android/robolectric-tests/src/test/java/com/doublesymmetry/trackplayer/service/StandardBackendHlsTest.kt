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
    fun whileATrackLoadsTheMediaSessionAndTheNotificationReadTheReportedTrack() {
        // Rule 13 (N1), as iOS's lock screen (the reported track at its last position, rate 0):
        // while C loads, the player the media session and the notification read (KotlinAudio's
        // sessionPlayer, given to both) reports A's last position, duration (also in the
        // notification's media metadata) and buffered position, not playing; its play-when-ready
        // stays the player's (the foreground service follows it); once C is reported, the
        // player's own values again.
        val backed = backed()
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        // C's playlists are slow too: while they load, C's window is ExoPlayer's placeholder
        // (dynamic), for which KotlinAudio's notification metadata drops the player's duration.
        val slowPlaylists = HlsTestServer(
            LADDER, segmentCount = 8, stalledFrom = 8, playlistDelayMs = STALL_TIMEOUT_MS / 3, segmentDelayMs = STALL_TIMEOUT_MS / 3
        ).also { servers += it }
        backed.backend.add(listOf(item(playable, 1L), item(slowServer(), 2L), item(slowPlaylists, 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val session = backed.player.sessionPlayer
        val exo = backed.analytics.player!!
        // The one both read: the notification's player and the media session's.
        assertSame("the notification reads it", session, privateField(backed.player.notificationManager, "player"))
        val connector = privateField(backed.player, "mediaSessionConnector") as com.google.android.exoplayer2.ext.mediasession.MediaSessionConnector
        assertSame("the media session reads it", session, connector.player)
        assertTrue("A plays, read as is", session.isPlaying && session.playWhenReady)
        val durationOfA = backed.backend.durationMs
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the player moved to C") { backed.player.currentIndex == 2 }
        val positionOfA = backed.backend.positionMs
        var sawLoading = false
        var sawPlaceholder = false
        val deadline = monotonicNowMs() + AWAIT_MS
        while (skip() == null) {
            if (monotonicNowMs() >= deadline) fail("timed out waiting for the skip to C to end")
            shadowOf(Looper.getMainLooper()).idle()
            if (skip() != null) break
            if (exo.playbackState == com.google.android.exoplayer2.Player.STATE_BUFFERING && backed.player.currentIndex == 2) {
                sawLoading = true
                if (exo.isCurrentMediaItemDynamic) sawPlaceholder = true
                assertEquals("the session's position is A's last", positionOfA, session.currentPosition)
                assertEquals(positionOfA, session.contentPosition)
                assertEquals("the session's duration is A's", durationOfA, session.duration)
                assertEquals(durationOfA, session.contentDuration)
                assertTrue("the session's buffered position is A's", session.bufferedPosition >= positionOfA)
                assertEquals(session.bufferedPosition, session.contentBufferedPosition)
                assertEquals(session.bufferedPosition - positionOfA, session.totalBufferedDuration)
                assertFalse("the session is not playing", session.isPlaying)
                assertTrue("the player itself goes on to play C", exo.playWhenReady)
                assertTrue("play-when-ready stays the player's (the notification's ongoing flag)", session.playWhenReady)
                assertEquals(
                    "the notification's metadata duration is A's",
                    durationOfA,
                    backed.player.notificationManager.getMediaMetadataCompat().getLong(android.support.v4.media.MediaMetadataCompat.METADATA_KEY_DURATION)
                )
            }
            Thread.sleep(CLOCK_TICK_MS)
        }
        assertTrue("C's load was seen", sawLoading)
        assertTrue("C's placeholder window was seen", sawPlaceholder)
        assertTrue(skip()!!.isSuccess)
        awaitTrue("C plays") { exo.isPlaying }
        assertTrue("C's own: playing", session.isPlaying && session.playWhenReady)
        assertEquals("C's own duration", exo.duration, session.duration)
        val before = exo.currentPosition
        val read = session.currentPosition
        val after = exo.currentPosition
        assertTrue("C's own position: $read within [$before, $after]", read in before..after)
    }

    // Rule 13 (fifth review, F4): while held, the media session's current item is the reported
    // track (its index, its media item, the active queue item TimelineQueueNavigator publishes),
    // as getActiveTrack; after a give-up it shows the error the app sees (ERROR), not none, until
    // the next command ends it (a stop: no player event follows, the session is told at once).

    @Test
    fun whileATrackLoadsTheMediaSessionsCurrentItemIsTheReportedTrackAndAGiveUpIsItsError() {
        // ExoPlayer 2.19.0's MediaSessionConnector (a stand-in here: stubs/, not in the offline
        // cache) reads the player at its listener's events: its playback state is STATE_ERROR when
        // getPlayerError() is not null, else from getPlaybackState(); TimelineQueueNavigator's
        // active queue item is getCurrentMediaItemIndex(), taken at EVENT_POSITION_DISCONTINUITY
        // (an index other than the last one) and EVENT_TIMELINE_CHANGED (javap of the 2.19.0 jar).
        // So: what the session player reports, and the events it gives a listener.
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L), item(slowServer(), 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val session = backed.player.sessionPlayer as ReportedSessionPlayer
        val exo = backed.analytics.player!!
        // What a connector listening to the session would read at each event: its index, its error.
        val seen = mutableListOf<Triple<Int, Boolean, Boolean>>()
        session.addListener(object : com.google.android.exoplayer2.Player.Listener {
            override fun onEvents(player: com.google.android.exoplayer2.Player, events: com.google.android.exoplayer2.Player.Events) {
                seen += Triple(
                    player.currentMediaItemIndex,
                    player.playerError != null,
                    events.containsAny(com.google.android.exoplayer2.Player.EVENT_POSITION_DISCONTINUITY, com.google.android.exoplayer2.Player.EVENT_TIMELINE_CHANGED)
                )
            }
        })
        val itemOfA = exo.getMediaItemAt(0)
        val skip = launchCommand { backed.backend.skip(1) }
        awaitTrue("held while B loads") { backed.player.currentIndex == 1 && session.held != null }
        assertEquals("the session's current item is A", 0, session.currentMediaItemIndex)
        @Suppress("DEPRECATION")
        assertEquals(0, session.currentWindowIndex)
        assertSame("A's media item", itemOfA, session.currentMediaItem)
        assertEquals("next after A", 1, session.nextMediaItemIndex)
        assertFalse("nothing before A", session.hasPreviousMediaItem())
        assertEquals("a connector reading at the hold sees A", 0, seen.last().first)
        assertEquals(PREPARE_TIMEOUT_CODE, (skip.let { awaitTrue("the skip ends", AWAIT_MS) { it() != null }; it()!!.exceptionOrNull() as RejectionException }).code)
        pump(STALL_TIMEOUT_MS)
        assertEquals(0, backed.backend.currentIndex)
        assertEquals("still A", 0, session.currentMediaItemIndex)
        assertEquals(AudioPlayerState.ERROR, backed.backend.playbackState)
        assertEquals("the session's error is the give-up's (STATE_ERROR)", backed.backend.playbackError?.message, session.playerError?.message)
        assertTrue("a connector reading at the give-up sees the error: $seen", seen.last().second)
        // A queue change while held moves the reported track: the session follows it.
        backed.backend.add(listOf(item(slowServer(), 4L)), 0)
        pump(STALL_TIMEOUT_MS / 3)
        assertEquals(1, backed.backend.currentIndex)
        assertEquals("the session follows A", 1, session.currentMediaItemIndex)
        assertEquals("a connector reading at the timeline change sees A", 1, seen.last().first)
        // The stop ends the error (no player event follows): the session tells its listeners.
        val beforeStop = seen.size
        backed.backend.stop()
        assertNull("no error after the stop", session.playerError)
        assertTrue("told at once: ${seen.drop(beforeStop)}", seen.drop(beforeStop).any { !it.second })
        // A skip to C (index 3) that loads: held on A while it loads, then released on C. The
        // connector takes the active queue item only at a discontinuity or a timeline change:
        // every change of the index it reads comes with one.
        assertNull(command { backed.backend.skip(3) })
        pump(STALL_TIMEOUT_MS / 3)
        assertEquals("C reported", 3, backed.backend.currentIndex)
        assertEquals("the session's current item is C", 3, session.currentMediaItemIndex)
        assertEquals("the last index a connector took is C", 3, seen.last().first)
        seen.zipWithNext().forEach { (before, after) ->
            if (before.first != after.first) assertTrue("an index change ${before.first} -> ${after.first} a connector sees: $seen", after.third)
        }
    }

    @Test
    fun aNewQueueWhileATrackLoadsReleasesTheSessionPlayerAtOnce() {
        // The hold of the reported track ends with it: a cleared queue reports none, and the
        // media session reads the player again at once (no player event follows an empty queue).
        val backed = backed()
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        backed.backend.add(listOf(item(playable, 1L), item(slowServer(), 2L), item(slowServer(), 3L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val session = backed.player.sessionPlayer as ReportedSessionPlayer
        val skip = launchCommand { backed.backend.skip(2) }
        awaitTrue("the session holds A while C loads") { backed.player.currentIndex == 2 && session.held != null }
        backed.backend.clearQueue()
        assertNull("released at once", session.held)
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
    }

    @Test
    fun theSessionPlayerTellsItsListenersAtOnceWhenItHoldsAndReleases() {
        // The media session and the notification read the player at its events: a hold or a
        // release is one (play state and position), not left to the player's next event.
        val backed = backed()
        val session = backed.player.sessionPlayer as ReportedSessionPlayer
        val reads = mutableListOf<Pair<Long, Boolean>>()
        session.addListener(object : com.google.android.exoplayer2.Player.Listener {
            override fun onEvents(player: com.google.android.exoplayer2.Player, events: com.google.android.exoplayer2.Player.Events) {
                if (events.contains(com.google.android.exoplayer2.Player.EVENT_IS_PLAYING_CHANGED)) reads += player.currentPosition to player.isPlaying
            }
        })
        session.hold(TrackProgress(42_000L, 180_000L, 50_000L))
        assertEquals(listOf(42_000L to false), reads)
        session.hold(TrackProgress(42_000L, 180_000L, 50_000L))
        assertEquals("the same hold tells nothing", 1, reads.size)
        session.hold(null)
        assertEquals(listOf(42_000L to false, backed.analytics.player!!.currentPosition to false), reads)
        assertNull(session.held)
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
        // The give-up kept the play request (crossfade's failure keeps playWhenReady).
        assertTrue("the request stays", backed.backend.playWhenReady)
        // A seek to a part that loads: the stopped track loads again there, held paused, and
        // plays once the seek is done, as crossfade's seek after a failure. Changed deliberately
        // (eighth round, review 7 item 5: a seek after a seek that gave up stayed paused).
        assertNull(command { backed.backend.seekTo(LOADABLE_TARGET_MS) })
        assertTrue("at the target: ${backed.player.position}", backed.player.position >= LOADABLE_TARGET_MS)
        awaitTrue("plays at the target, with no play") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals(AudioPlayerState.PLAYING, backed.backend.playbackState)
        assertTrue(backed.backend.playWhenReady)
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
    // and its position), as crossfade's: the player goes back to A, at the seek's target, and
    // plays there when playback was requested before the failure, as crossfade's (its failed
    // skip keeps playWhenReady, AndroidPlaybackOrchestrator.prepareActiveOrFail, and its seek
    // then plays A; fifth review, F2, changed deliberately: paused before). Only a cancelled
    // operation pauses (a*DuringASkipsLoad*). iOS: StandardLoadCoordinator.beginSeek, stop.

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
        val playableBeforeSeek = playable.requests.size
        val seekError = command { backed.backend.seekTo(captured) }
        // The give-up stopped the player (every source released): the seek loads A again (before
        // f12dfde the play did, "A loaded again"; this had become an always-true >=).
        assertTrue("the seek loads A again", playable.requests.size > playableBeforeSeek)
        assertNull("the seek acts on A, which loads", seekError)
        // Changed deliberately (owner decision, 2026-11-17): 1 (the failed track) -> 0.
        assertEquals("the track the seek acted on", 0, backed.player.currentIndex)
        assertEquals("the active track after the seek", 0, backed.backend.currentIndex)
        assertTrue("at the seek's target: ${backed.player.position}", backed.player.position >= captured)
        // Changed deliberately (fifth review, F2): paused -> playing, as crossfade's seek after a
        // failed skip (paused is a cancelled operation's).
        assertTrue("playing, as crossfade's seek after a failed skip", backed.backend.playWhenReady)
        assertNull("the give-up's error ended", backed.backend.playbackError)
        awaitTrue("A plays after the seek, with no play") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        assertNull(command { backed.backend.play() })
        awaitTrue("A plays") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        pump(STALL_TIMEOUT_MS * 2)
        assertEquals(0, backed.player.currentIndex)
        assertEquals(0, backed.backend.currentIndex)
        assertEquals(AudioPlayerState.PLAYING, backed.backend.playbackState)
        assertTrue("from the seek's target: ${backed.player.position}", backed.player.position >= captured)
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

    // The seek after a failed skip plays only as requested before the failure (fifth review,
    // F2, crossfade's): a pause after the give-up ends that request, so the seek goes back to A
    // paused; a skip that failed while paused leaves the seek paused too. A queue change after a
    // give-up loads nothing (crossfade's queue change: upstream's add prepared the player, which
    // loaded the failed track again).

    @Test
    fun aSeekAfterAGiveUpThenAPauseGoesBackPausedAndAQueueChangeLoadsNothing() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val captured = backed.backend.positionMs - CAPTURE_LAG_MS
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        backed.assertStaysInError(PREPARE_TIMEOUT_CODE)
        val requests = listOf(playable, stalled).map { it.requests.size }
        val c = slowServer()
        backed.backend.add(listOf(item(c, 3L)), null)
        pump(STALL_TIMEOUT_MS * 2)
        assertEquals("the add loads nothing", requests + 0, listOf(playable, stalled, c).map { it.requests.size })
        assertEquals("nothing loads", com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
        assertEquals(AudioPlayerState.ERROR, backed.backend.playbackState)
        backed.backend.pause()
        assertEquals("the error stays", AudioPlayerState.ERROR, backed.backend.playbackState)
        assertNull(command { backed.backend.seekTo(captured) })
        assertEquals("the track the seek acted on", 0, backed.player.currentIndex)
        assertFalse("paused: the pause ended the request", backed.backend.playWhenReady)
        pump(STALL_TIMEOUT_MS)
        assertFalse("still paused", backed.player.playerState == AudioPlayerState.PLAYING)
    }

    @Test
    fun aSeekAfterASkipThatFailedWhilePausedGoesBackPaused() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        backed.backend.pause()
        val captured = backed.backend.positionMs
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        assertNull(command { backed.backend.seekTo(captured) })
        assertEquals("the track the seek acted on", 0, backed.player.currentIndex)
        assertFalse("paused, as before the skip", backed.backend.playWhenReady)
        pump(STALL_TIMEOUT_MS)
        assertFalse("still paused", backed.player.playerState == AudioPlayerState.PLAYING)
    }

    // Sixth review, 1: a scrubber drag is several seeks. After a failed skip the first seek goes
    // back to A paused, the next ones act there, and the player plays once the latest seek is done
    // (as iOS: StandardSeekResume; crossfade's seek after a failed skip plays). iOS:
    // testStandardLoadCoordinatorSeveralSeeksAfterAFailedSkipPlayOnceTheLatestIsDone.

    @Test
    fun severalSeeksAfterASkipThatGaveUpPlayOnceTheLatestIsDone() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val captured = backed.backend.positionMs - CAPTURE_LAG_MS
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        val first = launchCommand { backed.backend.seekTo(captured) }
        val second = launchCommand { backed.backend.seekTo(captured + 100) }
        val last = command { backed.backend.seekTo(captured + 200) }
        assertNull("the latest seek completes", last)
        awaitTrue("the older seeks end") { first() != null && second() != null }
        assertEquals("standard_seek_cancelled", (first()!!.exceptionOrNull() as RejectionException).code)
        assertEquals("standard_seek_cancelled", (second()!!.exceptionOrNull() as RejectionException).code)
        assertEquals("the track the seeks acted on", 0, backed.player.currentIndex)
        assertTrue("playing once the latest seek is done", backed.backend.playWhenReady)
        awaitTrue("A plays after the seeks, with no play") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        assertTrue("from the latest seek's target: ${backed.player.position}", backed.player.position >= captured + 200)
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
    }

    // Eighth round (review 7, blocking 1, P1): after a failure the module's play request stays
    // true, as crossfade's, until a pause or stop. A skip, next or load issued while a seek holds
    // the player paused at the active track takes that request over: the new track plays once
    // loaded (as crossfade's skip, which reads playWhenReady before it cancels the seek). iOS:
    // testStandardLoadCoordinatorACommandThatLoadsATrackTakesAFailuresRequestOver.

    @Test
    fun aSkipNextPreviousOrLoadDuringASeekAfterAFailedSkipPlaysTheNewTrack() {
        for (op in listOf("skip", "next", "previous", "load")) {
            val a = slowServer()
            val c = server(LADDER, segmentCount = 8, stalledFrom = 8)
            val stalled = server(LADDER)
            val backed = backed()
            // A, C, B; for previous C, A, B (A's previous is C).
            val first = if (op == "previous") 1 else 0
            backed.backend.add(if (op == "previous") listOf(item(c, 3L), item(a, 1L), item(stalled, 2L)) else listOf(item(a, 1L), item(c, 3L), item(stalled, 2L)))
            if (first == 1) assertNull(command { backed.backend.skip(1) })
            command { backed.backend.play() }
            awaitTrue("$op: A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
            val captured = backed.backend.positionMs - CAPTURE_LAG_MS
            val beforeSkip = backed.playWhenReadyEvents.size
            assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(2) } as RejectionException).code)
            val seek = launchCommand { backed.backend.seekTo(captured) }
            shadowOf(Looper.getMainLooper()).idle()
            assertNull("$op: the seek still holds the player (A's segments are slow)", seek())
            assertFalse("$op: the player waits paused", backed.player.playWhenReady)
            val loaded = item(server(LADDER, segmentCount = 8, stalledFrom = 8), 9L)
            val error = when (op) {
                "skip" -> command { backed.backend.skip(1) }
                "next" -> command { backed.backend.skipToNext() }
                "previous" -> command { backed.backend.skipToPrevious() }
                else -> command { backed.backend.load(loaded) }
            }
            assertNull("$op: it loads its track", error)
            awaitTrue("$op: the seek ended") { seek() != null }
            awaitTrue("$op: the new track plays, with no play") { backed.player.playerState == AudioPlayerState.PLAYING }
            // A load replaces the player's item (A, where the seek went back), as KotlinAudio's.
            val expected = when (op) { "load" -> 0; "previous" -> 0; else -> 1 }
            assertEquals("$op: on the new track", expected, backed.player.currentIndex)
            if (op == "previous") assertEquals("on C", 3L, (backed.player.currentItem as TrackAudioItem).track.queueId)
            assertEquals(expected, backed.backend.currentIndex)
            if (op == "load") assertSame(loaded, backed.player.currentItem)
            assertTrue("$op: the request was kept", backed.backend.playWhenReady)
            assertEquals("$op: never play-when-ready false since the failure", listOf<Boolean>(), backed.playWhenReadyEvents.drop(beforeSkip).filter { !it })
        }
    }

    // Eighth round (review 7, item 2, P2): while the seek holds the player paused after a failed
    // skip, every reader and event reads the play request true and the state LOADING (crossfade's
    // seek state), never paused; the player itself waits paused until the seek is done (seventh
    // review M1). iOS: testStandardLoadCoordinatorASeekAfterAFailureReadsPlayingAndLoading.

    @Test
    fun aSeekAfterASkipThatGaveUpReadsPlayingAndLoadingWhileItHoldsThePlayerPaused() {
        // A give-up (whose stop ends the player's own play-when-ready) or a player error (the
        // player's stays true until the seek holds it paused at A).
        for (failure in listOf("giveUp", "error")) {
            val a = slowServer()
            val failing = if (failure == "giveUp") server(LADDER) else HlsTestServer(LADDER, masterBody = "not a playlist").also { servers += it }
            val backed = backed()
            backed.backend.add(listOf(item(a, 1L), item(failing, 2L)))
            command { backed.backend.play() }
            awaitTrue("$failure: A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
            val captured = backed.backend.positionMs - CAPTURE_LAG_MS
            val beforeSkip = backed.playWhenReadyEvents.size
            assertEquals(if (failure == "giveUp") PREPARE_TIMEOUT_CODE else STANDARD_LOAD_ERROR_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
            pump(STALL_TIMEOUT_MS / 3)
            assertTrue("$failure: the failure keeps the request, as crossfade's", backed.backend.playWhenReady)
            assertEquals("$failure: the player's own", failure == "error", backed.player.playWhenReady)
            val beforeSeek = backed.events.size
            val seek = launchCommand { backed.backend.seekTo(captured) }
            val samples = mutableListOf<String>()
            var heldPaused = 0
            var duringSeek = listOf<String>()
            while (seek() == null) {
                shadowOf(Looper.getMainLooper()).idle()
                if (seek() != null) break
                // The events the app got while the seek held the player (none after its end).
                duringSeek = backed.events.drop(beforeSeek).toList()
                assertTrue("$failure: the request reads true during the seek", backed.backend.playWhenReady)
                assertFalse("$failure: the player waits paused until the seek is done", backed.player.playWhenReady)
                heldPaused++
                samples += "${backed.backend.playbackState}"
                Thread.sleep(CLOCK_TICK_MS)
            }
            assertNull("$failure: the seek completes", seek()!!.exceptionOrNull())
            assertTrue("$failure: the seek held the player for a while (A's segments are slow): $heldPaused", heldPaused > 1)
            assertEquals("$failure: LOADING throughout, as crossfade's seek", setOf("LOADING"), samples.toSet())
            val states = duringSeek.filter { it.startsWith("state:") }
            assertTrue("$failure: the player's loading was sent: $duringSeek", states.isNotEmpty())
            assertEquals("$failure: only LOADING was sent while the seek held the player: $duringSeek", setOf("state:LOADING"), states.toSet())
            awaitTrue("$failure: A plays after the seek") { backed.player.playerState == AudioPlayerState.PLAYING }
            pump(STALL_TIMEOUT_MS / 3)
            assertEquals("$failure: never play-when-ready false since the failure", listOf<Boolean>(), backed.playWhenReadyEvents.drop(beforeSkip).filter { !it })
            assertEquals("state:PLAYING", backed.events.last { it.startsWith("state:") })
        }
        // A pause while a seek holds the player ends the request; the app is told at once though
        // the player sends nothing (it already waits paused).
        val b = slowServer()
        val again = backed()
        again.backend.add(listOf(item(b, 1L), item(server(LADDER), 2L)))
        command { again.backend.play() }
        awaitTrue("B plays") { again.player.playerState == AudioPlayerState.PLAYING && again.player.position >= PLAYED_MS }
        assertEquals(PREPARE_TIMEOUT_CODE, (command { again.backend.skip(1) } as RejectionException).code)
        val pausedSeek = launchCommand { again.backend.seekTo(PLAYED_MS) }
        shadowOf(Looper.getMainLooper()).idle()
        assertNull(pausedSeek())
        val beforePause = again.playWhenReadyEvents.size
        val stateBeforePause = again.events.size
        again.backend.pause()
        assertFalse(again.backend.playWhenReady)
        assertEquals("the pause is told at once", listOf(false), again.playWhenReadyEvents.drop(beforePause).take(1))
        assertTrue("the state too: ${again.events.drop(stateBeforePause)}", again.events.drop(stateBeforePause).firstOrNull()?.let { it != "state:LOADING" } == true)
        awaitTrue("the seek ends") { pausedSeek() != null }
        pump(STALL_TIMEOUT_MS)
        assertFalse("still paused", again.player.playerState == AudioPlayerState.PLAYING)
    }

    // Eighth round (review 7, blocking 1, P3): a new queue while the seek holds the player
    // paused after a failed skip plays its first track (the request a failure kept, as a skip's);
    // a clear ends it (crossfade's clear is its stop). iOS:
    // testStandardLoadCoordinatorACommandThatLoadsATrackTakesAFailuresRequestOver.

    @Test
    fun aNewQueueDuringASeekAfterAFailedSkipPlaysItsFirstTrackAClearEndsTheRequestAndARemovalKeepsIt() {
        for (op in listOf("replace", "clear", "removeCurrent")) {
            val a = slowServer()
            val stalled = server(LADDER)
            val c = server(LADDER, segmentCount = 8, stalledFrom = 8)
            val backed = backed()
            backed.backend.add(listOf(item(a, 1L), item(stalled, 2L)))
            command { backed.backend.play() }
            awaitTrue("$op: A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
            val captured = backed.backend.positionMs - CAPTURE_LAG_MS
            assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
            val seek = launchCommand { backed.backend.seekTo(captured) }
            shadowOf(Looper.getMainLooper()).idle()
            assertNull("$op: the seek still holds the player", seek())
            if (op == "replace") {
                backed.backend.replaceQueue(listOf(item(c, 3L)))
                awaitTrue("the seek ended") { seek() != null }
                awaitTrue("the new queue's first track plays, with no play") { backed.player.playerState == AudioPlayerState.PLAYING }
                assertEquals(0, backed.backend.currentIndex)
                assertTrue(backed.backend.playWhenReady)
            } else if (op == "clear") {
                backed.backend.clearQueue()
                awaitTrue("the seek ended") { seek() != null }
                pump(STALL_TIMEOUT_MS)
                assertFalse("the clear ends the request", backed.backend.playWhenReady)
                assertEquals(false, backed.playWhenReadyEvents.lastOrNull())
            } else {
                // Removing the active track does not end the request (crossfade's queue change
                // without its active track does: README, remaining differences).
                backed.backend.remove(listOf(0))
                awaitTrue("the seek ended") { seek() != null }
                pump(STALL_TIMEOUT_MS)
                assertTrue("a removal keeps the request", backed.backend.playWhenReady)
                assertFalse("the player does not play", backed.player.playerState == AudioPlayerState.PLAYING)
            }
        }
    }

    // Eighth round (review 7, item 4; seventh review M10; iOS: the coordinator's "the seek fails"
    // cases): the latest seek after a failed skip fails (its track now fails with a player error):
    // the player does not play and loads nothing more; the request stays (crossfade's failure
    // keeps playWhenReady) and the next seek that succeeds plays.

    @Test
    fun aFailedLatestSeekAfterAFailedSkipDoesNotPlayAndKeepsTheRequest() {
        val a = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(a, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        val captured = backed.backend.positionMs - CAPTURE_LAG_MS
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        a.broken = true
        val seekError = command { backed.backend.seekTo(captured) } as? RejectionException
        assertEquals(STANDARD_SEEK_UNAVAILABLE_CODE, seekError?.code)
        pump(STALL_TIMEOUT_MS)
        val requests = a.requests.size
        pump(STALL_TIMEOUT_MS)
        assertFalse("the failed seek does not play", backed.player.playWhenReady)
        assertFalse(backed.player.playerState == AudioPlayerState.PLAYING)
        assertEquals("nothing loads after the failed seek", requests, a.requests.size)
        assertTrue("the request stays", backed.backend.playWhenReady)
        // A player error on A: a seek cannot act there (standard_seek_unavailable); the retry
        // loads A again and plays it, the request it takes over.
        a.broken = false
        assertNull(command { backed.backend.retry() })
        awaitTrue("the retry plays A, as requested") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals(0, backed.player.currentIndex)
    }

    // Eighth round (review 7, item 5, M2): a seek that gives up while a seek after a failed skip
    // holds the player paused keeps the request (the player's own was false: it waited paused),
    // and the next seek on that track plays once done, as crossfade's seek after a failure.

    @Test
    fun aSeekThatGivesUpWhileASeekHoldsThePlayerKeepsTheRequestAndTheNextSeekPlays() {
        // A: segments from the fourth on (12 s) stall until recovered.
        val a = server(LADDER, segmentCount = 8, stalledFrom = 3)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(a, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        assertEquals(PREPARE_TIMEOUT_CODE, (command { backed.backend.skip(1) } as RejectionException).code)
        assertEquals("standard_seek_timeout", (command { backed.backend.seekTo(SEEK_TARGET_MS) } as RejectionException).code)
        assertEquals("on A", 0, backed.player.currentIndex)
        assertFalse(backed.player.playWhenReady)
        assertTrue("the request stays", backed.backend.playWhenReady)
        assertNull(command { backed.backend.seekTo(LOADABLE_TARGET_MS) })
        awaitTrue("plays once the seek is done, with no play") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals(0, backed.player.currentIndex)
    }

    // Eighth round (owner question, LOAD-14): the first track gives up while playing (no active
    // track, the request kept); the seek that retries it (LOAD-14) holds it paused and plays once
    // done, as every seek with a kept request (before: it stayed paused; after a player error it
    // played, the player's own request being true). iOS:
    // testStandardLoadCoordinatorTheSeekThatRetriesAFirstTrackThatGaveUpPlaysOnceDone.

    @Test
    fun theSeekThatRetriesAFirstTrackThatGaveUpPlaysOnceDone() {
        val first = server(LADDER, segmentCount = 2, stalledFrom = 0)
        val backed = backed()
        backed.backend.add(listOf(item(first, 1L)))
        command { backed.backend.play() }
        awaitTrue("the first load gives up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        assertEquals("none active", -1, backed.backend.currentIndex)
        assertTrue("the request stays", backed.backend.playWhenReady)
        first.recovered = true
        assertNull("the seek retries the failed track", command { backed.backend.seekTo(LOADABLE_TARGET_MS) })
        awaitTrue("it plays once the seek is done, with no play") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals(0, backed.player.currentIndex)
    }

    // Sixth review, A4: a seek while a natural advance loads goes back to the track that ended,
    // paused, though playback was requested (the seek cancels the advance, crossfade's cancelled
    // operation; only a seek after a failed load plays). iOS:
    // testStandardLoadCoordinatorASeekDuringANaturalAdvanceStaysPausedThoughPlaybackWasRequested.

    @Test
    fun aSeekDuringANaturalAdvanceGoesBackToTheEndedTrackPaused() {
        // A: one segment (4 s), which arrives; B: its first segment never arrives (it loads until
        // the give-up, stallTimeoutMs after the advance).
        val shortA = server(LADDER, segmentCount = 1, stalledFrom = 1)
        val stalled = server(LADDER)
        val backed = backed()
        backed.backend.add(listOf(item(shortA, 1L), item(stalled, 2L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        awaitTrue("the natural advance to B") { backed.player.currentIndex == 1 }
        assertTrue("no give-up yet: B loads", backed.gaveUpAtMs.isEmpty())
        assertTrue("playback requested", backed.player.playWhenReady)
        assertNull("the seek acts on A", command { backed.backend.seekTo(PLAYED_MS) })
        assertEquals("back on A, the track that ended", 0, backed.player.currentIndex)
        assertEquals(0, backed.backend.currentIndex)
        assertFalse("paused: the seek cancelled the advance", backed.backend.playWhenReady)
        pump(STALL_TIMEOUT_MS * 2)
        assertFalse("still paused", backed.player.playerState == AudioPlayerState.PLAYING)
        assertEquals("B is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
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
        // Changed deliberately (fifth review, F2): paused -> playing, as crossfade's.
        assertTrue("playing: a player error keeps play-when-ready", backed.backend.playWhenReady)
        awaitTrue("A plays after the seek, with no play") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        assertNull(command { backed.backend.play() })
        awaitTrue("A plays") { backed.player.currentIndex == 0 && backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals(0, backed.backend.currentIndex)
        assertEquals("the failed track is never reported", listOf<Int?>(0), backed.activeTrackChanges.map { it.first })
    }

    // With no active track (the first track failed with a player error), a seek acts on the
    // track that failed (owner decision, 2026-11-17, LOAD-14), which the player cannot seek in
    // (standard_seek_unavailable): it fails again, as after its own failure (FailedLoadRule
    // .failed: the notification is told to show the active track, none), and the play retries it.

    @Test
    fun aSeekOnAFirstTrackThatFailedWithAPlayerErrorFailsItAgain() {
        val broken = HlsTestServer(LADDER, masterBody = "not a playlist").also { servers += it }
        val backed = backed()
        backed.backend.add(listOf(item(broken, 1L), item(slowServer(), 2L)))
        command { backed.backend.play() }
        awaitTrue("a player error") { backed.player.playerState == AudioPlayerState.ERROR }
        pump(STALL_TIMEOUT_MS / 3)
        assertEquals("the failure, with no active track to show", listOf<Int?>(null), backed.loadFailures)
        assertEquals(-1, backed.backend.currentIndex)
        val seekError = command { backed.backend.seekTo(LOADABLE_TARGET_MS) } as? RejectionException
        assertEquals(STANDARD_SEEK_UNAVAILABLE_CODE, seekError?.code)
        assertEquals("the track the seek acted on (none active: the failed one)", 0, backed.player.currentIndex)
        assertEquals("it failed again: the notification is told again", listOf<Int?>(null, null), backed.loadFailures)
        assertEquals(-1, backed.backend.currentIndex)
        val requests = broken.requests.size
        assertNull(command { backed.backend.play() })
        awaitTrue("the play retries it") { broken.requests.size > requests }
        assertEquals(0, backed.player.currentIndex)
        assertEquals("never reported but at its selection", listOf<Int?>(0, null), backed.activeTrackChanges.map { it.first })
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
    fun aSeekCancellingASkipWithNoActiveTrackResolvesAndLoadsNothing() {
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
        // Changed deliberately (crossfade's seek with no active track, AndroidPlaybackOrchestrator
        // .seekTo): it rejected standard_seek_unavailable; it now resolves and does nothing.
        assertNull("no active track to seek in: nothing to do", seekError)
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        backed.assertTheSkipsLoadEnded(b, stopped)
        pump(STALL_TIMEOUT_MS * 3)
        assertEquals("the cancelled skip's track is never reported", listOf<Int?>(0, null), backed.activeTrackChanges.map { it.first })
        assertEquals(-1, backed.backend.currentIndex)
        assertEquals(com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
    }

    // The idle a cancel entered (no active track, the player stopped) lasts across queue changes,
    // as crossfade's queue change with no active track (Android AndroidPlaybackOrchestrator
    // .setQueue keeps currentIndex -1; iOS sets idle): adding, moving or removing loads nothing
    // (upstream KotlinAudio's add prepared the player, which loaded the cancelled skip's track
    // again and reported READY with no active track); a new queue has no active track either and
    // loads nothing; the next play starts its first track, reported once it loaded.

    /** The first track gave up (none active), a skip to B ([b]) was cancelled by a pause: idle. */
    private fun idleAfterACancelledSkip(b: HlsTestServer, first: HlsTestServer = server(LADDER), more: List<TrackAudioItem> = emptyList()): Backed {
        val backed = backed()
        backed.backend.add(listOf(item(first, 1L), item(b, 2L)) + more)
        command { backed.backend.play() }
        awaitTrue("a give-up", AWAIT_MS) { backed.gaveUpAtMs.isNotEmpty() }
        val skip = launchCommand { backed.backend.skip(1) }
        awaitTrue("the player moved to B") { backed.player.currentIndex == 1 }
        awaitTrue("B requested") { b.requests.isNotEmpty() }
        backed.backend.pause()
        awaitTrue("the skip ends") { skip() != null }
        assertEquals("cancelled", (skip()!!.exceptionOrNull() as RejectionException).code)
        pump(STALL_TIMEOUT_MS)
        assertEquals(-1, backed.backend.currentIndex)
        assertEquals(AudioPlayerState.STOPPED, backed.backend.playbackState)
        return backed
    }

    /** After [change], nothing loads: no request of [servers], the player idle, no state event. */
    private fun assertAQueueChangeInIdleLoadsNothing(backed: Backed, servers: List<HlsTestServer>, change: () -> Unit) {
        val requests = servers.map { it.requests.size }
        val events = backed.events.size
        val changes = backed.activeTrackChanges.toList()
        change()
        pump(STALL_TIMEOUT_MS * 3)
        assertEquals("requests after the queue change", requests, servers.map { it.requests.size })
        assertEquals("the player loads nothing", com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
        assertEquals("no state event", emptyList<String>(), backed.events.drop(events))
        assertEquals("no active track", -1, backed.backend.currentIndex)
        assertEquals("every reader: stopped", AudioPlayerState.STOPPED, backed.backend.playbackState)
        assertEquals("nothing reported", changes, backed.activeTrackChanges)
    }

    @Test
    fun anAddWithNoActiveTrackLoadsNothing() {
        val b = slowServer()
        val backed = idleAfterACancelledSkip(b)
        val c = slowServer()
        assertAQueueChangeInIdleLoadsNothing(backed, listOf(b, c)) { backed.backend.add(listOf(item(c, 3L)), null) }
    }

    @Test
    fun anAddAtAnIndexWithNoActiveTrackLoadsNothing() {
        val b = slowServer()
        val backed = idleAfterACancelledSkip(b)
        val c = slowServer()
        assertAQueueChangeInIdleLoadsNothing(backed, listOf(b, c)) { backed.backend.add(listOf(item(c, 3L)), 1) }
    }

    @Test
    fun aMoveWithNoActiveTrackLoadsNothing() {
        val b = slowServer()
        val c = slowServer()
        val backed = idleAfterACancelledSkip(b, more = listOf(item(c, 3L)))
        assertAQueueChangeInIdleLoadsNothing(backed, listOf(b, c)) { backed.backend.move(1, 2) }
    }

    @Test
    fun removingThePlayersTrackWithNoActiveTrackLoadsNothing() {
        val b = slowServer()
        val c = slowServer()
        val backed = idleAfterACancelledSkip(b, more = listOf(item(c, 3L)))
        // B, the player's own item, leaves: the player is on C, which does not load.
        assertAQueueChangeInIdleLoadsNothing(backed, listOf(b, c)) { backed.backend.remove(listOf(1)) }
        assertEquals(1, backed.player.currentIndex)
    }

    @Test
    fun aNewQueueWithNoActiveTrackLoadsNothingAndThePlayStartsItsFirstTrack() {
        val b = slowServer()
        val backed = idleAfterACancelledSkip(b)
        val c = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val d = slowServer()
        assertAQueueChangeInIdleLoadsNothing(backed, listOf(b, c, d)) { backed.backend.replaceQueue(listOf(item(c, 3L), item(d, 4L))) }
        val before = backed.activeTrackChanges.toList()
        val returned = backed.commandReading { backed.backend.play() }
        assertEquals("not reported before it loaded", -1, returned.index)
        awaitTrue("C plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals("C reported once it loaded", before + listOf<Pair<Int?, Int?>>(0 to null), backed.activeTrackChanges)
        assertEquals(0, backed.backend.currentIndex)
    }

    // A backend switch that restores no active track (a snapshot with none) is the same logical
    // idle: a seek resolves and does nothing; the play reports its first track once it loaded.

    @Test
    fun aRestoreWithNoActiveTrackResolvesASeekAndReportsThePlaysTrackOnceItLoaded() {
        val a = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val items = listOf(item(a, 1L), item(slowServer(), 2L))
        val backed = backed(candidateQueue = items)
        val snapshot = PlaybackBackendSnapshot.empty().copy(queueIds = items.map { it.track.queueId.toString() })
        assertNull(command {
            backed.backend.prepareSilently(snapshot)
            backed.backend.restore(snapshot)
            backed.backend.commitQueue(snapshot)
            backed.backend.activateAfterCommit(snapshot)
        })
        pump(STALL_TIMEOUT_MS / 3)
        assertEquals(-1, backed.backend.currentIndex)
        assertEquals(AudioPlayerState.IDLE, backed.backend.playbackState)
        assertNull("no active track to seek in: nothing to do", command { backed.backend.seekTo(LOADABLE_TARGET_MS) })
        assertEquals(-1, backed.backend.currentIndex)
        val returned = backed.commandReading { backed.backend.play() }
        assertEquals("not reported before it loaded", emptyList<Int?>(), returned.reported)
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals("A reported once it loaded", listOf<Pair<Int?, Int?>>(0 to null), backed.activeTrackChanges)
        assertEquals(0, backed.backend.currentIndex)
    }

    // Sixth review, 2: the restored idle loads nothing, as iOS and the cancel's idle: neither the
    // restore (before: ExoPlayer prepared the restored queue and loaded its first track) nor a new
    // queue or a queue change after it (before: the prepared player loaded the new queue's first
    // track, or the next one when its item left, and emitted LOADING/BUFFERING/READY while the app
    // read IDLE with no active track). Every reader stays IDLE (rule 13).

    @Test
    fun aRestoreWithNoActiveTrackAndTheQueueChangesAfterItLoadNothing() {
        for (op in listOf("replace", "removeTheCurrent", "add", "move")) {
            val a = slowServer()
            val b = slowServer()
            val items = listOf(item(a, 1L), item(b, 2L))
            val backed = backed(candidateQueue = items)
            val snapshot = PlaybackBackendSnapshot.empty().copy(queueIds = items.map { it.track.queueId.toString() })
            assertNull(command {
                backed.backend.prepareSilently(snapshot)
                backed.backend.restore(snapshot)
                backed.backend.commitQueue(snapshot)
                backed.backend.activateAfterCommit(snapshot)
            })
            pump(STALL_TIMEOUT_MS)
            assertEquals("$op: the restore loads nothing", listOf(0, 0), listOf(a, b).map { it.requests.size })
            assertEquals(op, com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
            assertEquals(op, AudioPlayerState.IDLE, backed.backend.playbackState)
            val c = server(LADDER, segmentCount = 8, stalledFrom = 8)
            val d = slowServer()
            val events = backed.events.size
            when (op) {
                "replace" -> backed.backend.replaceQueue(listOf(item(c, 3L), item(d, 4L)))
                "removeTheCurrent" -> backed.backend.remove(listOf(0))
                "add" -> backed.backend.add(listOf(item(c, 3L)), 0)
                else -> backed.backend.move(0, 1)
            }
            pump(STALL_TIMEOUT_MS * 3)
            assertEquals("$op: the queue change loads nothing", listOf(0, 0, 0, 0), listOf(a, b, c, d).map { it.requests.size })
            assertEquals(op, com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
            assertEquals("$op: no state event", emptyList<String>(), backed.events.drop(events))
            assertEquals(op, -1, backed.backend.currentIndex)
            assertEquals("$op: every reader IDLE", AudioPlayerState.IDLE, backed.backend.playbackState)
            assertEquals("$op: nothing reported", emptyList<Pair<Int?, Int?>>(), backed.activeTrackChanges)
            if (op == "replace") {
                val returned = backed.commandReading { backed.backend.play() }
                assertEquals("not reported before it loaded", emptyList<Int?>(), returned.reported)
                awaitTrue("the new queue's first track plays") { backed.player.playerState == AudioPlayerState.PLAYING }
                assertEquals(listOf<Pair<Int?, Int?>>(0 to null), backed.activeTrackChanges)
                assertTrue("C loaded", c.requests.isNotEmpty())
            }
        }
    }

    // An add to a queue the player stopped on loads nothing (wider than the idle: a stop, a
    // failure), as crossfade's queue change and SwiftAudioEx's add to a queue that has items;
    // upstream KotlinAudio's add prepared the player, which loaded its stopped item again.

    @Test
    fun anAddAfterAStopLoadsNothing() {
        val playable = server(LADDER, segmentCount = 8, stalledFrom = 8)
        val backed = backed()
        backed.backend.add(listOf(item(playable, 1L)))
        command { backed.backend.play() }
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING && backed.player.position >= PLAYED_MS }
        backed.backend.stop()
        pump(STALL_TIMEOUT_MS / 3)
        val requests = playable.requests.size
        val events = backed.events.size
        val c = slowServer()
        backed.backend.add(listOf(item(c, 2L)), null)
        pump(STALL_TIMEOUT_MS * 2)
        assertEquals("the add loads nothing", listOf(requests, 0), listOf(playable.requests.size, c.requests.size))
        assertEquals(com.google.android.exoplayer2.Player.STATE_IDLE, backed.analytics.player!!.playbackState)
        assertEquals("no state event", emptyList<String>(), backed.events.drop(events))
        assertEquals(AudioPlayerState.STOPPED, backed.backend.playbackState)
    }

    // A play, retry, skip, next or load with no active track (the logical idle) reports its track
    // once it loaded, as crossfade's play with no active track (before: at once, then, when its
    // load failed, no active track again). iOS: StandardLoadCoordinator.idleActivation.

    @Test
    fun aPlayWithNoActiveTrackReportsTheFirstTrackOnceItLoaded() {
        val a = server(LADDER, segmentCount = 8, stalledFrom = 0)
        val b = slowServer()
        val backed = idleAfterACancelledSkip(b, first = a)
        val before = backed.activeTrackChanges.toList()
        assertEquals(listOf<Int?>(0, null), before.map { it.first })
        a.recovered = true
        val returned = backed.commandReading { backed.backend.play() }
        assertEquals("the play starts the first track", 0, backed.player.currentIndex)
        assertEquals("not reported before it loaded", before.map { it.first }, returned.reported)
        assertEquals("no active track while it loads", -1, returned.index)
        awaitTrue("A plays") { backed.player.playerState == AudioPlayerState.PLAYING }
        assertEquals("A reported once it loaded", before + listOf<Pair<Int?, Int?>>(0 to null), backed.activeTrackChanges)
        assertEquals(0, backed.backend.currentIndex)
    }

    @Test
    fun aNextWithNoActiveTrackWhoseTrackFailsReportsNothing() {
        val b = slowServer()
        val backed = idleAfterACancelledSkip(b)
        val before = backed.activeTrackChanges.toList()
        val error = command { backed.backend.skipToNext() } as? RejectionException
        assertEquals(PREPARE_TIMEOUT_CODE, error?.code)
        assertEquals("the next started the first track", 0, backed.player.currentIndex)
        pump(STALL_TIMEOUT_MS)
        assertEquals("the failed track is never reported (nor none again)", before, backed.activeTrackChanges)
        assertEquals(-1, backed.backend.currentIndex)
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
        loadTimeoutMs: Long = PREPARE_TIMEOUT_MS,
        /** A backend switch's candidate with this queue (not authoritative until its commit). */
        candidateQueue: List<TrackAudioItem>? = null
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
            AndroidTrackQueue().apply { candidateQueue?.let(::replaceWith) },
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
            // As MusicService: what the app reads that changed with no event of the player's.
            onReportedChanged = { playWhenReady, state ->
                state?.let { events += "state:$it" }
                playWhenReady?.let { playWhenReadyEvents += it }
            },
            initiallyAuthoritative = candidateQueue == null
        ).also { it.startLoadWatch(Handler(Looper.getMainLooper())) }

        /**
         * KotlinAudio's state and playback-error events in the order MusicService emits them to
         * JS (PLAYBACK_STATE, PLAYBACK_ERROR): "state:<state>", "error:<code>". Collected as
         * MusicService's observeEvents does (its MainScope, collectWithAdmission, admitted);
         * both flows replay their last value at subscription, recorded too.
         */
        val events: MutableList<String> = java.util.Collections.synchronizedList(mutableListOf())
        /**
         * The play-when-ready events MusicService emits (PLAYBACK_PLAY_WHEN_READY_CHANGED): the
         * player's own, as the backend reads them, and the backend's changes with no player event.
         */
        val playWhenReadyEvents: MutableList<Boolean> = java.util.Collections.synchronizedList(mutableListOf())
        val eventScope = kotlinx.coroutines.MainScope()

        init {
            val admission = SharedFlowAdmissionGate().also { it.admit() }
            // As MusicService.observeEvents: the backend's reading of the player's events.
            eventScope.collectWithAdmission(player.event.stateChange, admission) { events += "state:${backend.reportedStateOf(it)}" }
            eventScope.collectWithAdmission(player.event.playbackError, admission) { events += "error:${it.code}" }
            eventScope.collectWithAdmission(player.event.playWhenReadyChange, admission) {
                playWhenReadyEvents += backend.reportedPlayWhenReadyOf(it.playWhenReady)
            }
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
        loadTimeoutMs: Long = PREPARE_TIMEOUT_MS,
        candidateQueue: List<TrackAudioItem>? = null
    ): Backed = Backed(seekStallMs, seekTimeoutMs, loadTimeoutMs, candidateQueue).also { backends += it }

    private fun item(server: HlsTestServer, queueId: Long) =
        TrackAudioItem(track = Track(queueId = queueId), type = MediaType.HLS, audioUrl = server.masterUrl)

    /** [owner]'s private field [name] (declared by its class or a superclass). */
    private fun privateField(owner: Any, name: String): Any? {
        var type: Class<*>? = owner.javaClass
        while (type != null) {
            type.declaredFields.firstOrNull { it.name == name }?.let { field ->
                field.isAccessible = true
                return field.get(owner)
            }
            type = type.superclass
        }
        fail("no field $name in ${owner.javaClass}")
        return null
    }

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
