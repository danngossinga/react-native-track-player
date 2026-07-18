package com.doublesymmetry.trackplayer.service

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.support.v4.media.RatingCompat
import androidx.test.platform.app.InstrumentationRegistry
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.BufferConfig
import com.doublesymmetry.kotlinaudio.models.CacheConfig
import com.doublesymmetry.kotlinaudio.models.PlayerConfig
import com.doublesymmetry.kotlinaudio.players.QueuedAudioPlayer
import com.doublesymmetry.trackplayer.model.Track
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class KotlinAudioMediaSessionControlInstrumentationTest {
    @Test
    fun testPinnedReflectionSuspendsAndResumesLiveKotlinAudioSession() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val player = QueuedAudioPlayer(
                instrumentation.targetContext,
                PlayerConfig(),
                BufferConfig(null, null, null, null),
                CacheConfig(null)
            )
            try {
                val control = KotlinAudioMediaSessionControl.from(player)
                assertTrue(control.isActive())

                control.deactivate()
                assertFalse(control.isActive())

                control.activate()
                assertTrue(control.isActive())
            } finally {
                player.destroy()
            }
        }
    }

    @Test
    fun testRestoredIdleQueueActivatesPhysicalZeroOnlyOnNext() {
        withRestoredIdleBackend { fixture ->
            assertEquals(0, fixture.player.currentIndex)
            assertEquals(-1, fixture.backend.currentIndex)
            assertEquals(AudioPlayerState.IDLE, fixture.backend.playbackState)
            assertNull(fixture.backend.snapshot().activeIndex)

            fixture.backend.removeUpcomingTracks()
            assertEquals(3, fixture.backend.queueItems.size)
            fixture.player.jumpToItem(2)
            yield()
            fixture.clearTransitionEvents()
            fixture.backend.skipToPrevious()
            assertEquals(2, fixture.player.currentIndex)
            assertEquals(-1, fixture.backend.currentIndex)
            assertTrue(fixture.canonicalActivationIndices().isEmpty())

            fixture.backend.skipToNext()
            yield()
            assertEquals(0, fixture.player.currentIndex)
            assertEquals(0, fixture.backend.currentIndex)
            assertEquals(listOf(0), fixture.canonicalActivationIndices())
            assertEquals(0, fixture.backend.snapshot().activeIndex)
        }
    }

    @Test
    fun testRestoredIdlePlayPublishesCanonicalFirstTrack() {
        withRestoredIdleBackend { fixture ->
            fixture.player.jumpToItem(2)
            yield()
            fixture.clearTransitionEvents()

            fixture.backend.play()
            yield()

            assertEquals(0, fixture.player.currentIndex)
            assertEquals(0, fixture.backend.currentIndex)
            assertEquals(listOf(0), fixture.canonicalActivationIndices())
            assertEquals(0, fixture.backend.snapshot().activeIndex)
        }
    }

    @Test
    fun testActivePlayDoesNotCanonicalizeToPhysicalZero() {
        withActiveBackend(activeIndex = 2) { fixture ->
            assertEquals(2, fixture.player.currentIndex)
            assertEquals(2, fixture.backend.currentIndex)
            fixture.clearTransitionEvents()

            fixture.backend.play()
            yield()

            assertEquals(2, fixture.player.currentIndex)
            assertEquals(2, fixture.backend.currentIndex)
            assertTrue(fixture.canonicalActivationIndices().isEmpty())
        }
    }

    @Test
    fun testRestoredIdleRetryPublishesCanonicalFirstTrack() {
        withRestoredIdleBackend { fixture ->
            fixture.player.jumpToItem(2)
            yield()
            fixture.clearTransitionEvents()

            fixture.backend.retry()
            yield()

            assertEquals(0, fixture.player.currentIndex)
            assertEquals(0, fixture.backend.currentIndex)
            assertEquals(listOf(0), fixture.canonicalActivationIndices())
            assertEquals(0, fixture.backend.snapshot().activeIndex)
        }
    }

    @Test
    fun testRestoredIdleLoadPublishesCanonicalCallbackAndQueue() {
        withRestoredIdleBackend { fixture ->
            val loaded = createSilentTrack(fixture.context, "loaded")
            fixture.player.jumpToItem(2)
            yield()
            fixture.clearTransitionEvents()

            fixture.backend.load(loaded)
            yield()

            assertEquals(listOf(0), fixture.canonicalActivationIndices())
            assertEquals(3, fixture.backend.queueItems.size)
            assertEquals(loaded, fixture.backend.queueItems.first())
            assertEquals(fixture.items.drop(1), fixture.backend.queueItems.drop(1))
            assertEquals(0, fixture.backend.currentIndex)
            val snapshot = fixture.backend.snapshot()
            assertEquals(0, snapshot.activeIndex)
            assertEquals(loaded.track.queueId.toString(), snapshot.activeTrackId)
            assertEquals(
                fixture.backend.queueItems.map { it.track.queueId.toString() },
                snapshot.queueIds
            )
        }
    }

    @Test
    fun testInvalidExplicitSkipKeepsRestoredIdle() {
        withRestoredIdleBackend { fixture ->
            try {
                fixture.backend.skip(fixture.items.size)
                fail("Expected invalid queue index to fail")
            } catch (_: IndexOutOfBoundsException) {
                // Expected from QueuedAudioPlayer.
            }

            assertEquals(-1, fixture.backend.currentIndex)
            assertEquals(AudioPlayerState.IDLE, fixture.backend.playbackState)
            assertTrue(fixture.activatedIndices.isEmpty())
        }
    }

    private fun withRestoredIdleBackend(
        block: suspend CoroutineScope.(IdleBackendFixture) -> Unit
    ) = withBackend(activeIndex = null, block)

    private fun withActiveBackend(
        activeIndex: Int,
        block: suspend CoroutineScope.(IdleBackendFixture) -> Unit
    ) = withBackend(activeIndex, block)

    private fun withBackend(
        activeIndex: Int?,
        block: suspend CoroutineScope.(IdleBackendFixture) -> Unit
    ) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val player = QueuedAudioPlayer(
                instrumentation.targetContext,
                PlayerConfig(),
                BufferConfig(null, null, null, null),
                CacheConfig(null)
            )
            try {
                val items = listOf("a", "b", "c").map {
                    createSilentTrack(instrumentation.targetContext, it)
                }
                val queueStore = AndroidTrackQueue().apply { replaceWith(items) }
                val activatedIndices = mutableListOf<Int>()
                val nativeTransitionIndices = mutableListOf<Int>()
                val backend = KotlinAudioPlaybackBackend(
                    player = player,
                    identity = Any(),
                    queueStore = queueStore,
                    transitionGenerationSidecar = PlaybackTransitionGenerationSidecar(),
                    onCommitted = {},
                    onActivated = {},
                    onDisposed = {},
                    onLogicalActiveItemActivated = activatedIndices::add
                )
                val snapshot = PlaybackBackendSnapshot.empty().copy(
                    queueIds = items.map { it.track.queueId.toString() },
                    activeIndex = activeIndex,
                    activeTrackId = activeIndex?.let { items[it].track.queueId.toString() }
                )

                runBlocking {
                    backend.prepareSilently(snapshot)
                    backend.restore(snapshot)
                    backend.commitQueue(snapshot)
                    backend.activateAfterCommit(snapshot)
                    val nativeTransitionCollector = launch {
                        player.event.audioItemTransition.collect {
                            nativeTransitionIndices += player.currentIndex
                        }
                    }
                    try {
                        yield()
                        nativeTransitionIndices.clear()
                        block(
                            IdleBackendFixture(
                                context = instrumentation.targetContext,
                                player = player,
                                backend = backend,
                                items = items,
                                activatedIndices = activatedIndices,
                                nativeTransitionIndices = nativeTransitionIndices
                            )
                        )
                    } finally {
                        nativeTransitionCollector.cancel()
                    }
                }
            } finally {
                player.destroy()
            }
        }
    }

    private fun createSilentTrack(context: Context, name: String): TrackAudioItem {
        val file = File(context.cacheDir, "rntp-$name.wav")
        if (!file.isFile) {
            val dataSize = 800
            val wav = ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN)
            wav.put("RIFF".toByteArray(Charsets.US_ASCII))
            wav.putInt(36 + dataSize)
            wav.put("WAVEfmt ".toByteArray(Charsets.US_ASCII))
            wav.putInt(16)
            wav.putShort(1)
            wav.putShort(1)
            wav.putInt(8_000)
            wav.putInt(16_000)
            wav.putShort(2)
            wav.putShort(16)
            wav.put("data".toByteArray(Charsets.US_ASCII))
            wav.putInt(dataSize)
            repeat(dataSize) { wav.put(0) }
            file.writeBytes(wav.array())
        }
        return Track(
            context,
            Bundle().apply {
                putString("url", Uri.fromFile(file).toString())
                putString("title", name)
            },
            RatingCompat.RATING_NONE
        ).toAudioItem()
    }

    private data class IdleBackendFixture(
        val context: Context,
        val player: QueuedAudioPlayer,
        val backend: KotlinAudioPlaybackBackend,
        val items: List<TrackAudioItem>,
        val activatedIndices: MutableList<Int>,
        val nativeTransitionIndices: MutableList<Int>
    ) {
        fun canonicalActivationIndices(): List<Int> = activatedIndices + nativeTransitionIndices

        fun clearTransitionEvents() {
            activatedIndices.clear()
            nativeTransitionIndices.clear()
        }
    }
}
