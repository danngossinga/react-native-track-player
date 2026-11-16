package com.doublesymmetry.trackplayer.service

import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import org.junit.Assert.assertEquals
import org.junit.Test

class CrossfadeHttpTimeoutsTest {
    private fun timeoutsOf(source: DefaultHttpDataSource): Pair<Int, Int> {
        fun field(name: String) = DefaultHttpDataSource::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.getInt(source)
        return field("connectTimeoutMillis") to field("readTimeoutMillis")
    }

    @Test
    fun theDataSourcesOfACrossfadePlayerFollowTheCurrentStallTimeout() {
        val factory = DefaultHttpDataSource.Factory()
        // ExoPlayer's fixed default, which would cut a slow read at 8 s.
        assertEquals(
            DefaultHttpDataSource.DEFAULT_CONNECT_TIMEOUT_MILLIS to DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS,
            timeoutsOf(factory.createDataSource())
        )
        assertEquals(10_000, applyHttpTimeouts(factory, DEFAULT_STALL_TIMEOUT_MS))
        assertEquals(10_000 to 10_000, timeoutsOf(factory.createDataSource()))
        // A new value from updateOptions applies to the data sources created at the next load.
        assertEquals(25_000, applyHttpTimeouts(factory, 25_000L))
        assertEquals(25_000 to 25_000, timeoutsOf(factory.createDataSource()))
        // The option's upper bound fits an Int.
        assertEquals(2_147_483_646, applyHttpTimeouts(factory, 2_147_483_646L))
    }
}
