package com.doublesymmetry.trackplayer.service

/** What a wait does after reading its progress. */
internal enum class StallVerdict {
    /** Keep waiting. */
    WAIT,
    /** No progress for the stall timeout. */
    STALLED,
    /** The wait's total limit is exceeded, progress or not. */
    CAP_EXCEEDED
}

/**
 * Decides when a wait gives up: after [stallTimeoutMs] with no progress, or after [totalTimeoutMs]
 * in all (the safety cap). It is fed readings (bytes loaded, buffered position...) and the time; a
 * reading that grows from the previous one is progress. A reading that drops (a seek back) is not
 * progress, but the next growth from there is. Same rules as the iOS `StallWatch`.
 */
internal class StallWatch(
    val stallTimeoutMs: Long,
    val totalTimeoutMs: Long,
    private val startedAtMs: Long
) {
    private var lastProgressAtMs = startedAtMs
    private var previous: LongArray? = null

    /** Takes the current readings. The first ones only set the baseline. */
    fun check(nowMs: Long, readings: LongArray): StallVerdict {
        val last = previous
        if (last != null && last.size == readings.size && readings.indices.any { readings[it] > last[it] }) {
            lastProgressAtMs = nowMs
        }
        previous = readings.copyOf()
        if (nowMs - startedAtMs >= totalTimeoutMs) return StallVerdict.CAP_EXCEEDED
        if (nowMs - lastProgressAtMs >= stallTimeoutMs) return StallVerdict.STALLED
        return StallVerdict.WAIT
    }

    fun describe(verdict: StallVerdict): String = when (verdict) {
        StallVerdict.STALLED -> "no progress for ${stallTimeoutMs}ms"
        StallVerdict.CAP_EXCEEDED -> "over the ${totalTimeoutMs}ms limit"
        StallVerdict.WAIT -> "waiting"
    }
}

/**
 * Polls [isDone] every [pollIntervalMs] until it returns true (null result) or the wait gives up
 * (the [StallVerdict] that ended it). [isDone] may throw to fail at once (a player error).
 * [readings] are read after each unfinished poll; [nowMs] is a monotonic clock in milliseconds.
 */
internal suspend fun awaitWhileProgressing(
    stallTimeoutMs: Long,
    totalTimeoutMs: Long,
    pollIntervalMs: Long,
    nowMs: () -> Long,
    pause: suspend (Long) -> Unit,
    readings: () -> LongArray,
    isDone: () -> Boolean
): StallVerdict? {
    val watch = StallWatch(stallTimeoutMs, totalTimeoutMs, nowMs())
    while (true) {
        if (isDone()) return null
        val verdict = watch.check(nowMs(), readings())
        if (verdict != StallVerdict.WAIT) return verdict
        pause(pollIntervalMs)
    }
}

/** A monotonic clock for the waits, in milliseconds (works in JVM unit tests too). */
internal fun monotonicNowMs(): Long = System.nanoTime() / 1_000_000L
