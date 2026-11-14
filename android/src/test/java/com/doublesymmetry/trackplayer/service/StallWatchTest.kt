package com.doublesymmetry.trackplayer.service

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class StallWatchTest {
    @Test
    fun aSlowButProgressingLoadSurvivesPastTheStallTimeoutUntilItsCap() {
        // A little more media every second, with a 3 s stall timeout and a 60 s cap.
        val watch = StallWatch(stallTimeoutMs = 3_000L, totalTimeoutMs = 60_000L, startedAtMs = 100L)
        assertEquals(StallVerdict.WAIT, watch.check(100L, longArrayOf(0L)))
        for (second in 1 until 60) {
            assertEquals("$second s", StallVerdict.WAIT, watch.check(100L + second * 1_000L, longArrayOf(second * 200L)))
        }
        assertEquals(StallVerdict.CAP_EXCEEDED, watch.check(60_100L, longArrayOf(12_000L)))
    }

    @Test
    fun aStalledLoadFailsAtTheStallTimeout() {
        val watch = StallWatch(stallTimeoutMs = 3_000L, totalTimeoutMs = 60_000L, startedAtMs = 0L)
        assertEquals(StallVerdict.WAIT, watch.check(0L, longArrayOf(4L)))
        assertEquals(StallVerdict.WAIT, watch.check(1_000L, longArrayOf(5L)))
        // Nothing more loads from 1 s: it fails 3 s later, not at the cap.
        assertEquals(StallVerdict.WAIT, watch.check(2_000L, longArrayOf(5L)))
        assertEquals(StallVerdict.WAIT, watch.check(3_999L, longArrayOf(5L)))
        assertEquals(StallVerdict.STALLED, watch.check(4_000L, longArrayOf(5L)))
    }

    @Test
    fun anyGrowingReadingIsProgressAndGrowthAfterADropCounts() {
        val watch = StallWatch(stallTimeoutMs = 1_000L, totalTimeoutMs = 60_000L, startedAtMs = 0L)
        // Bytes, buffered position.
        assertEquals(StallVerdict.WAIT, watch.check(0L, longArrayOf(0L, 10_000L)))
        // Bytes keep arriving while the buffered position does not move (one slow segment).
        assertEquals(StallVerdict.WAIT, watch.check(900L, longArrayOf(4_096L, 10_000L)))
        assertEquals(StallVerdict.WAIT, watch.check(1_800L, longArrayOf(8_192L, 10_000L)))
        // A seek back drops the buffered position: not progress, but growth from there is.
        assertEquals(StallVerdict.WAIT, watch.check(2_700L, longArrayOf(8_192L, 3_000L)))
        assertEquals(StallVerdict.WAIT, watch.check(3_500L, longArrayOf(8_192L, 4_000L)))
        assertEquals(StallVerdict.STALLED, watch.check(4_500L, longArrayOf(8_192L, 4_000L)))
    }

    @Test
    fun theWaitEndsWhenDoneAndOtherwiseOnItsVerdict() = runTest {
        // Done after 30 s of slow progress, with a 10 s stall timeout: no verdict.
        var loaded = 0L
        val started = currentTime
        val done = awaitWhileProgressing(
            stallTimeoutMs = 10_000L,
            totalTimeoutMs = 60_000L,
            pollIntervalMs = 25L,
            nowMs = { currentTime },
            pause = { delay(it) },
            readings = { longArrayOf(loaded) }
        ) {
            loaded += 1L
            currentTime - started >= 30_000L
        }
        assertNull(done)
        assertEquals(30_000L, currentTime - started)

        // Nothing loads: stalled at 10 s.
        val stalledAt = currentTime
        val stalled = awaitWhileProgressing(10_000L, 60_000L, 25L, { currentTime }, { delay(it) }, { longArrayOf(7L) }) { false }
        assertEquals(StallVerdict.STALLED, stalled)
        assertEquals(10_000L, currentTime - stalledAt)

        // Progress forever: the cap ends it.
        val cappedAt = currentTime
        val capped = awaitWhileProgressing(10_000L, 60_000L, 25L, { currentTime }, { delay(it) }, { longArrayOf(loaded++) }) { false }
        assertEquals(StallVerdict.CAP_EXCEEDED, capped)
        assertEquals(60_000L, currentTime - cappedAt)
    }

    @Test
    fun aPlayerErrorEndsTheWaitAtOnce() = runTest {
        try {
            awaitWhileProgressing(10_000L, 60_000L, 25L, { currentTime }, { delay(it) }, { longArrayOf(0L) }) {
                throw IllegalStateException("player error")
            }
            fail("Expected the error")
        } catch (error: IllegalStateException) {
            assertTrue(error.message == "player error")
        }
    }
}
