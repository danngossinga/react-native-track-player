package com.doublesymmetry.trackplayer.service

import android.content.Context
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import com.doublesymmetry.kotlinaudio.models.RepeatMode
import com.doublesymmetry.trackplayer.model.TrackAudioItem
import com.doublesymmetry.trackplayer.utils.RejectionException
import com.google.android.exoplayer2.Player
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

internal enum class AndroidPlaybackOrchestratorState {
    IDLE,
    LOADING,
    PLAYING_SINGLE,
    PRELOADING_NEXT,
    CROSSFADING,
    PAUSED,
    PAUSED_DURING_CROSSFADE,
    SEEKING,
    SKIPPING,
    STOPPED,
    ENDED,
    ERROR
}

internal data class AndroidPlaybackSnapshot(
    val currentIndex: Int,
    val queueSize: Int,
    val currentItem: TrackAudioItem?,
    val playbackState: AudioPlayerState,
    val orchestratorState: AndroidPlaybackOrchestratorState,
    val playWhenReady: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val bufferedMs: Long,
    val rate: Float,
    val hasPrevious: Boolean,
    val hasNext: Boolean
)

internal interface AndroidPlaybackOrchestratorDelegate {
    fun onPlaybackStateChanged(state: AudioPlayerState)
    fun onActiveTrackChanged(index: Int?, previousIndex: Int?, oldPositionMs: Long)
    fun onQueueEnded(index: Int, positionMs: Long)
    fun onCrossfadeState(
        state: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int? = null,
        fromVolume: Float? = null,
        toVolume: Float? = null,
        errorCode: String? = null
    )
    fun onNowPlayingChanged(index: Int)
    fun onPlaybackError(code: String, message: String?)
    fun onSnapshotChanged(snapshot: AndroidPlaybackSnapshot)
}

internal class AndroidPlaybackOrchestrator(
    context: Context,
    private val scope: CoroutineScope,
    audioContentType: Int,
    handleAudioFocus: Boolean,
    private val delegate: AndroidPlaybackOrchestratorDelegate
) {
    private val engineA = AndroidCrossfadeEngine(context, "engineA", audioContentType, handleAudioFocus)
    private val engineB = AndroidCrossfadeEngine(context, "engineB", audioContentType, handleAudioFocus)
    private var activeEngine = engineA
    private var standbyEngine = engineB
    private var queue: List<TrackAudioItem> = emptyList()
    private var lastEmittedPlaybackState: AudioPlayerState? = null
    private var preloadJob: Job? = null
    private var standbyMaintenanceJob: Job? = null
    private var preloadTargetIndex: Int? = null
    private var monitorJob: Job? = null
    private var crossfadeRunId = 0
    private var activeCrossfadeFromIndex: Int? = null
    private var activeCrossfadeToIndex: Int? = null
    private var preparedCrossfadeFromIndex: Int? = null
    private var preparedCrossfadeToIndex: Int? = null
    private var preparedCrossfadeSeekToMs: Long = 0L
    private var nowPlayingOverride: TrackAudioItem? = null

    var currentIndex: Int = -1
        private set

    var playWhenReady: Boolean = false
        private set

    var volume: Float = 1f
        private set

    var rate: Float = 1f
        private set

    var repeatMode: RepeatMode = RepeatMode.OFF
        private set

    var state: AndroidPlaybackOrchestratorState = AndroidPlaybackOrchestratorState.IDLE
        private set

    val currentTrack: TrackAudioItem?
        get() = queue.getOrNull(currentIndex)

    val positionMs: Long
        get() = when (state) {
            AndroidPlaybackOrchestratorState.CROSSFADING,
            AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE -> standbyEngine.positionMs
            else -> activeEngine.positionMs
        }

    val durationMs: Long
        get() = when (state) {
            AndroidPlaybackOrchestratorState.CROSSFADING,
            AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE -> standbyEngine.durationMs
            else -> activeEngine.durationMs
        }

    val bufferedMs: Long
        get() = when (state) {
            AndroidPlaybackOrchestratorState.CROSSFADING,
            AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE -> standbyEngine.bufferedMs
            else -> activeEngine.bufferedMs
        }

    val playbackState: AudioPlayerState
        get() {
            if (state == AndroidPlaybackOrchestratorState.ERROR) return AudioPlayerState.ERROR
            if (state == AndroidPlaybackOrchestratorState.ENDED) return AudioPlayerState.ENDED
            if (state == AndroidPlaybackOrchestratorState.STOPPED) return AudioPlayerState.STOPPED
            if (state == AndroidPlaybackOrchestratorState.IDLE) return AudioPlayerState.IDLE
            if (state == AndroidPlaybackOrchestratorState.LOADING ||
                state == AndroidPlaybackOrchestratorState.SEEKING ||
                state == AndroidPlaybackOrchestratorState.SKIPPING
            ) {
                return AudioPlayerState.LOADING
            }
            if (state == AndroidPlaybackOrchestratorState.PAUSED ||
                state == AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE
            ) {
                return AudioPlayerState.PAUSED
            }
            if (activeEngine.playbackState == Player.STATE_BUFFERING) return AudioPlayerState.BUFFERING
            if (playWhenReady) return AudioPlayerState.PLAYING
            return AudioPlayerState.PAUSED
        }

    fun snapshot(): AndroidPlaybackSnapshot {
        return AndroidPlaybackSnapshot(
            currentIndex = currentIndex,
            queueSize = queue.size,
            currentItem = nowPlayingOverride ?: currentTrack,
            playbackState = playbackState,
            orchestratorState = state,
            playWhenReady = playWhenReady,
            positionMs = positionMs,
            durationMs = durationMs,
            bufferedMs = bufferedMs,
            rate = rate,
            hasPrevious = previousIndexFor(currentIndex) != null || positionMs > PREVIOUS_RESTART_THRESHOLD_MS,
            hasNext = nextIndexFor(currentIndex) != null
        )
    }

    init {
        monitorJob = scope.launch {
            while (true) {
                try {
                    monitorActiveEngine()
                } catch (error: Exception) {
                    androidXfadeLog("monitor error=${error.message}")
                }
                delay(250)
            }
        }
    }

    fun setQueue(items: List<TrackAudioItem>) {
        val currentItem = currentTrack
        val currentQueueId = currentTrack?.track?.queueId
        val nextQueue = items.toList()
        val identityIndex = currentItem?.let { item -> nextQueue.indexOfFirst { it === item } } ?: -1
        val queueIdIndex = currentQueueId?.let { queueId ->
            nextQueue.indexOfFirst { it.track.queueId == queueId }
                .takeIf { nextQueue.count { it.track.queueId == queueId } == 1 }
        } ?: -1
        queue = nextQueue
        currentIndex = when {
            queue.isEmpty() -> -1
            identityIndex >= 0 -> identityIndex
            queueIdIndex >= 0 -> queueIdIndex
            currentIndex in queue.indices -> currentIndex
            else -> -1
        }
        androidXfadeLog("queue sync size=${queue.size} currentIndex=$currentIndex")
        notifySnapshotChanged()
    }

    suspend fun load(item: TrackAudioItem) {
        cancelCrossfade("load", promoteIncoming = false)
        standbyMaintenanceJob?.cancelAndJoin()
        standbyMaintenanceJob = null
        preloadJob?.cancelAndJoin()
        nowPlayingOverride = null
        val existingIndex = queue.indexOfFirst { it.track.queueId == item.track.queueId }
        if (existingIndex >= 0) {
            startTrackAt(existingIndex, 0L, emitTrackChange = true, oldPositionMs = activeEngine.positionMs)
        } else {
            queue = listOf(item)
            currentIndex = 0
            activeEngine.reset()
            standbyEngine.reset()
            setState(AndroidPlaybackOrchestratorState.LOADING)
            activeEngine.prepare(item, 0L)
            activeEngine.setVolume(if (playWhenReady) volume else 0f)
            delegate.onActiveTrackChanged(0, null, 0L)
            delegate.onNowPlayingChanged(0)
            notifySnapshotChanged()
            if (playWhenReady) {
                activeEngine.play(rate)
                setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)
            } else {
                setState(AndroidPlaybackOrchestratorState.PAUSED)
            }
        }
    }

    fun setNowPlayingOverride(item: TrackAudioItem?) {
        nowPlayingOverride = item
        notifySnapshotChanged()
    }

    suspend fun play() {
        playWhenReady = true
        if (state == AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE) {
            activeEngine.play(rate)
            standbyEngine.play(rate)
            setState(AndroidPlaybackOrchestratorState.CROSSFADING)
            return
        }

        if (queue.isEmpty()) {
            setState(AndroidPlaybackOrchestratorState.IDLE)
            return
        }
        if (currentIndex !in queue.indices) {
            startTrackAt(0, 0L, emitTrackChange = true, oldPositionMs = 0L)
            return
        }
        ensureActivePrepared(currentIndex, positionMs)
        activeEngine.setVolume(volume)
        activeEngine.play(rate)
        setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)
        preloadNextIfPossible()
    }

    fun pause() {
        playWhenReady = false
        when (state) {
            AndroidPlaybackOrchestratorState.CROSSFADING -> {
                activeEngine.pause()
                standbyEngine.pause()
                setState(AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE)
            }
            else -> {
                activeEngine.pause()
                standbyEngine.pause()
                setState(AndroidPlaybackOrchestratorState.PAUSED)
            }
        }
    }

    fun stop() {
        playWhenReady = false
        cancelCrossfade("stop", promoteIncoming = false)
        preloadJob?.cancel()
        standbyMaintenanceJob?.cancel()
        standbyMaintenanceJob = null
        preloadTargetIndex = null
        activeEngine.reset()
        standbyEngine.reset()
        setState(AndroidPlaybackOrchestratorState.STOPPED)
    }

    suspend fun skip(index: Int) {
        if (index !in queue.indices) {
            throw RejectionException("The track index is out of bounds.", "index_out_of_bounds")
        }
        cancelCrossfade("skip", promoteIncoming = false)
        startTrackAt(index, 0L, emitTrackChange = true, oldPositionMs = activeEngine.positionMs)
    }

    suspend fun skipToNext() {
        val nextIndex = nextIndexFor(currentIndex)
            ?: throw RejectionException("There is no next track.", "no_next_track")
        skip(nextIndex)
    }

    suspend fun skipToPrevious() {
        if (currentIndex in queue.indices && positionMs > PREVIOUS_RESTART_THRESHOLD_MS) {
            seekTo(0L)
            return
        }
        val previousIndex = previousIndexFor(currentIndex)
            ?: throw RejectionException("There is no previous track.", "no_previous_track")
        skip(previousIndex)
    }

    suspend fun seekTo(positionMs: Long) {
        if (queue.isEmpty() || currentIndex !in queue.indices) return
        cancelCrossfade("seek", promoteIncoming = true)
        setState(AndroidPlaybackOrchestratorState.SEEKING)
        ensureActivePrepared(currentIndex, this.positionMs)
        activeEngine.seekTo(positionMs)
        if (playWhenReady) {
            activeEngine.setVolume(volume)
            activeEngine.play(rate)
            setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)
        } else {
            setState(AndroidPlaybackOrchestratorState.PAUSED)
        }
        preloadNextIfPossible()
    }

    suspend fun seekBy(offsetMs: Long) {
        seekTo(max(0L, positionMs + offsetMs))
    }

    fun setVolume(value: Float) {
        volume = value.coerceIn(0f, 1f)
        notifySnapshotChanged()
        if (state == AndroidPlaybackOrchestratorState.CROSSFADING) return
        activeEngine.setVolume(if (playWhenReady) volume else 0f)
    }

    fun setRate(value: Float) {
        rate = max(0.1f, value)
        activeEngine.player.setPlaybackSpeed(rate)
        standbyEngine.player.setPlaybackSpeed(rate)
        notifySnapshotChanged()
    }

    fun setRepeatMode(value: RepeatMode) {
        repeatMode = value
        notifySnapshotChanged()
    }

    suspend fun crossFadePrepare(previous: Boolean = false, seekTo: Double = 0.0) {
        val fromIndex = currentIndex
        val toIndex = if (previous) previousIndexFor(fromIndex) else nextIndexFor(fromIndex)
        if (!isPlaybackActiveForCrossfade()) {
            emitCrossfade("cancelled", fromIndex, toIndex ?: -1, errorCode = "not_playing")
            throw RejectionException("Crossfade cannot prepare while playback is not active.", "crossfade_not_playing")
        }
        if (state == AndroidPlaybackOrchestratorState.CROSSFADING ||
            state == AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE
        ) {
            emitCrossfade("error", fromIndex, toIndex ?: -1, errorCode = "crossfade_in_progress")
            throw RejectionException("A crossfade is already in progress.", "crossfade_in_progress")
        }
        if (fromIndex !in queue.indices || toIndex == null || toIndex !in queue.indices) {
            emitCrossfade("error", fromIndex, toIndex ?: -1, errorCode = "crossfade_target_unavailable")
            throw RejectionException("No crossfade target track is available.", "crossfade_target_unavailable")
        }
        preparedCrossfadeFromIndex = fromIndex
        preparedCrossfadeToIndex = toIndex
        preparedCrossfadeSeekToMs = (max(0.0, seekTo) * 1000).toLong()
        preloadJob?.cancelAndJoin()
        prepareStandby(toIndex, preparedCrossfadeSeekToMs)
        emitCrossfade(
            state = "prepared",
            fromIndex = fromIndex,
            toIndex = toIndex,
            elapsedMs = 0,
            fromVolume = activeEngine.player.volume,
            toVolume = 0f
        )
    }

    suspend fun crossFade(
        fadeDuration: Double = 5000.0,
        fadeInterval: Double = 20.0,
        fadeToVolume: Double = 1.0,
        waitUntil: Double = 0.0
    ) {
        val fromIndex = currentIndex
        val toIndex = if (preparedCrossfadeFromIndex == fromIndex && preparedCrossfadeToIndex != null) {
            preparedCrossfadeToIndex!!
        } else {
            nextIndexFor(fromIndex) ?: -1
        }
        if (fromIndex !in queue.indices || toIndex !in queue.indices) {
            emitCrossfade("error", fromIndex, toIndex, errorCode = "crossfade_target_unavailable")
            throw RejectionException("No prepared crossfade target track is available.", "crossfade_target_unavailable")
        }

        val durationMs = max(0.0, fadeDuration).toLong()
        if (!isPlaybackActiveForCrossfade()) {
            emitCrossfade("cancelled", fromIndex, toIndex, errorCode = "not_playing")
            throw RejectionException("Crossfade cannot start while playback is not active.", "crossfade_not_playing")
        }
        if (!canCrossfade(fromIndex, toIndex, durationMs)) {
            emitCrossfade("error", fromIndex, toIndex, errorCode = "crossfade_not_supported")
            throw RejectionException("Crossfade is not supported for this transition.", "crossfade_not_supported")
        }

        crossfadeRunId += 1
        val runId = crossfadeRunId
        activeCrossfadeFromIndex = fromIndex
        activeCrossfadeToIndex = toIndex
        val intervalMs = max(10.0, fadeInterval).toLong()
        val rampDurationMs = max(1L, durationMs)
        val targetVolume = fadeToVolume.toFloat().coerceIn(0f, 1f)
        val outgoingStartVolume = volume
        val waitDelayMs = max(0L, waitUntil.toLong() - activeEngine.positionMs)

        emitCrossfade("scheduled", fromIndex, toIndex, elapsedMs = 0, fromVolume = outgoingStartVolume, toVolume = 0f)

        try {
            if (waitDelayMs > 0) {
                delayChecked(waitDelayMs, runId)
            }
            ensureCrossfadeRunActive(runId)
            ensurePlaybackStillActiveForCrossfade(fromIndex, toIndex, "Crossfade was cancelled because playback is paused.")
            standbyMaintenanceJob?.cancelAndJoin()
            standbyMaintenanceJob = null
            preloadJob?.cancelAndJoin()
            ensureActivePrepared(fromIndex, activeEngine.positionMs)
            prepareStandby(toIndex, preparedCrossfadeSeekToMs)
            ensurePlaybackStillActiveForCrossfade(fromIndex, toIndex, "Crossfade was cancelled because playback is paused.")
            val outgoingEngine = activeEngine
            val incomingEngine = standbyEngine
            val oldPositionMs = outgoingEngine.positionMs

            outgoingEngine.setVolume(outgoingStartVolume)
            incomingEngine.setVolume(0f)
            outgoingEngine.play(rate)
            incomingEngine.play(rate)

            currentIndex = toIndex
            delegate.onActiveTrackChanged(toIndex, fromIndex, oldPositionMs)
            delegate.onNowPlayingChanged(toIndex)
            setState(AndroidPlaybackOrchestratorState.CROSSFADING)
            emitCrossfade("started", fromIndex, toIndex, elapsedMs = 0, fromVolume = outgoingStartVolume, toVolume = 0f)

            val incomingStartMs = incomingEngine.positionMs
            var elapsedMs = 0L
            var lastRunningEmitMs = -CROSSFADE_RUNNING_EVENT_INTERVAL_MS
            while (elapsedMs < durationMs) {
                ensureCrossfadeRunActive(runId)
                if (state == AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE) {
                    delay(intervalMs)
                    continue
                }
                if (!playWhenReady) {
                    ensurePlaybackStillActiveForCrossfade(fromIndex, toIndex, "Crossfade was cancelled because playback is paused.")
                }
                if (elapsedMs >= INCOMING_STALL_GRACE_MS &&
                    incomingEngine.positionMs <= incomingStartMs + INCOMING_STALL_TOLERANCE_MS
                ) {
                    fallbackToTargetAfterStalledCrossfade(
                        fromIndex = fromIndex,
                        toIndex = toIndex,
                        elapsedMs = elapsedMs,
                        oldPositionMs = oldPositionMs,
                        errorCode = "incoming_stalled"
                    )
                    return
                }
                if (outgoingEngine.durationMs > 0L &&
                    outgoingEngine.positionMs >= max(0L, outgoingEngine.durationMs - OUTGOING_END_TOLERANCE_MS)
                ) {
                    if (incomingEngine.positionMs > incomingStartMs + INCOMING_STALL_TOLERANCE_MS) {
                        elapsedMs = durationMs
                    } else {
                        fallbackToTargetAfterStalledCrossfade(
                            fromIndex = fromIndex,
                            toIndex = toIndex,
                            elapsedMs = elapsedMs,
                            oldPositionMs = oldPositionMs,
                            errorCode = "incoming_stalled"
                        )
                        return
                    }
                    break
                }
                val progress = min(1.0, elapsedMs.toDouble() / rampDurationMs.toDouble())
                val angle = progress * PI / 2.0
                val fromVolume = (outgoingStartVolume.toDouble() * cos(angle)).toFloat()
                val toVolume = (targetVolume.toDouble() * sin(angle)).toFloat()
                outgoingEngine.setVolume(fromVolume)
                incomingEngine.setVolume(toVolume)
                if (elapsedMs - lastRunningEmitMs >= CROSSFADE_RUNNING_EVENT_INTERVAL_MS) {
                    emitCrossfade("running", fromIndex, toIndex, elapsedMs = elapsedMs.toInt(), fromVolume = fromVolume, toVolume = toVolume)
                    lastRunningEmitMs = elapsedMs
                }
                delay(intervalMs)
                elapsedMs = min(durationMs, elapsedMs + intervalMs)
            }

            outgoingEngine.setVolume(0f)
            incomingEngine.setVolume(targetVolume)
            outgoingEngine.pause()
            activeEngine = incomingEngine
            standbyEngine = outgoingEngine
            preloadTargetIndex = null
            preparedCrossfadeFromIndex = null
            preparedCrossfadeToIndex = null
            preparedCrossfadeSeekToMs = 0L
            activeCrossfadeFromIndex = null
            activeCrossfadeToIndex = null
            volume = targetVolume
            if (playWhenReady) {
                activeEngine.play(rate)
                setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)
            } else {
                activeEngine.pause()
                setState(AndroidPlaybackOrchestratorState.PAUSED)
            }
            emitCrossfade("completed", fromIndex, toIndex, elapsedMs = durationMs.toInt(), fromVolume = 0f, toVolume = targetVolume)
            schedulePostCrossfadeStandbyMaintenance(crossfadeDurationMs = durationMs)
        } catch (error: RejectionException) {
            if (error.code != "cancelled" && error.code != "crossfade_not_playing") {
                emitCrossfade("error", fromIndex, toIndex, errorCode = error.code)
                setState(AndroidPlaybackOrchestratorState.ERROR)
            }
            throw error
        } catch (error: Exception) {
            emitCrossfade("error", fromIndex, toIndex, errorCode = "crossfade_unexpected_error")
            setState(AndroidPlaybackOrchestratorState.ERROR)
            throw error
        }
    }

    private fun isPlaybackActiveForCrossfade(): Boolean {
        return playWhenReady &&
            (state == AndroidPlaybackOrchestratorState.PLAYING_SINGLE ||
                state == AndroidPlaybackOrchestratorState.PRELOADING_NEXT)
    }

    private fun ensurePlaybackStillActiveForCrossfade(fromIndex: Int, toIndex: Int, message: String) {
        if (playWhenReady) return
        emitCrossfade("cancelled", fromIndex, toIndex, errorCode = "not_playing")
        throw RejectionException(message, "crossfade_not_playing")
    }

    private suspend fun fallbackToTargetAfterStalledCrossfade(
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Long,
        oldPositionMs: Long,
        errorCode: String
    ) {
        androidXfadeLog("crossfade fallback to target fromIndex=$fromIndex toIndex=$toIndex error=$errorCode")
        emitCrossfade(
            "error",
            fromIndex,
            toIndex,
            elapsedMs = elapsedMs.toInt(),
            fromVolume = activeEngine.player.volume,
            toVolume = standbyEngine.player.volume,
            errorCode = errorCode
        )
        activeCrossfadeFromIndex = null
        activeCrossfadeToIndex = null
        preparedCrossfadeFromIndex = null
        preparedCrossfadeToIndex = null
        preparedCrossfadeSeekToMs = 0L
        preloadTargetIndex = null
        startTrackAt(toIndex, 0L, emitTrackChange = true, oldPositionMs = oldPositionMs)
    }

    private fun schedulePostCrossfadeStandbyMaintenance(crossfadeDurationMs: Long) {
        standbyMaintenanceJob?.cancel()
        if (!playWhenReady || state != AndroidPlaybackOrchestratorState.PLAYING_SINGLE) return
        if (nextIndexFor(currentIndex) == null) return

        val runId = crossfadeRunId
        val activeDurationMs = durationMs
        val activePositionMs = positionMs
        val settleMs = POST_CROSSFADE_SETTLE_MS
        val targetPreloadPositionMs = if (activeDurationMs > 0L) {
            max(
                activePositionMs + settleMs,
                activeDurationMs - max(1L, crossfadeDurationMs) - POST_CROSSFADE_PRELOAD_LEAD_MS
            )
        } else {
            activePositionMs + settleMs
        }
        val delayMs = max(settleMs, targetPreloadPositionMs - activePositionMs)

        androidXfadeLog("post-crossfade standby maintenance scheduled delayMs=$delayMs")
        standbyMaintenanceJob = scope.launch {
            delay(delayMs)
            ensureCrossfadeRunActive(runId)
            if (!playWhenReady || state != AndroidPlaybackOrchestratorState.PLAYING_SINGLE) return@launch
            standbyEngine.reset()
            preloadTargetIndex = null
            preloadNextIfPossible()
        }
    }

    fun release() {
        preloadJob?.cancel()
        standbyMaintenanceJob?.cancel()
        standbyMaintenanceJob = null
        preloadTargetIndex = null
        monitorJob?.cancel()
        engineA.release()
        engineB.release()
    }

    private suspend fun startTrackAt(
        index: Int,
        positionMs: Long,
        emitTrackChange: Boolean,
        oldPositionMs: Long
    ) {
        val previousIndex = currentIndex.takeIf { it in queue.indices }
        standbyMaintenanceJob?.cancelAndJoin()
        standbyMaintenanceJob = null
        preloadJob?.cancelAndJoin()
        preloadTargetIndex = null
        activeEngine.reset()
        standbyEngine.reset()
        currentIndex = index
        nowPlayingOverride = null
        setState(AndroidPlaybackOrchestratorState.LOADING)
        if (emitTrackChange) {
            delegate.onActiveTrackChanged(index, previousIndex, oldPositionMs)
        }
        delegate.onNowPlayingChanged(index)
        notifySnapshotChanged()
        activeEngine.prepare(queue[index], positionMs)
        activeEngine.setVolume(if (playWhenReady) volume else 0f)
        if (playWhenReady) {
            activeEngine.play(rate)
            setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)
        } else {
            setState(AndroidPlaybackOrchestratorState.PAUSED)
        }
        notifySnapshotChanged()
        preloadNextIfPossible()
    }

    private suspend fun ensureActivePrepared(index: Int, positionMs: Long) {
        val item = queue[index]
        if (activeEngine.isPreparedFor(item)) return
        setState(AndroidPlaybackOrchestratorState.LOADING)
        activeEngine.prepare(item, positionMs)
    }

    private suspend fun prepareStandby(index: Int, positionMs: Long) {
        val item = queue[index]
        if (standbyEngine.isPreparedFor(item) && standbyEngine.isReady) {
            if (positionMs > 0L && abs(standbyEngine.positionMs - positionMs) > PREPARED_POSITION_TOLERANCE_MS) {
                standbyEngine.seekTo(positionMs)
            }
            return
        }
        androidXfadeLog("standby prepare targetIndex=$index engine=${standbyEngine.name}")
        standbyEngine.prepare(item, positionMs)
    }

    private fun preloadNextIfPossible() {
        if (state == AndroidPlaybackOrchestratorState.CROSSFADING ||
            state == AndroidPlaybackOrchestratorState.PAUSED_DURING_CROSSFADE
        ) {
            return
        }
        val nextIndex = nextIndexFor(currentIndex) ?: return
        if (!canPreload(nextIndex)) return
        val nextItem = queue.getOrNull(nextIndex) ?: return
        if (standbyEngine.isPreparedFor(nextItem) && standbyEngine.isReady) {
            androidXfadeLog("preload reuse toIndex=$nextIndex standby=${standbyEngine.name}")
            preloadTargetIndex = nextIndex
            return
        }
        if (preloadTargetIndex == nextIndex && preloadJob?.isActive == true) {
            androidXfadeLog("preload already in flight toIndex=$nextIndex standby=${standbyEngine.name}")
            return
        }
        preloadJob?.cancel()
        preloadTargetIndex = nextIndex
        preloadJob = scope.launch {
            try {
                val restorePlayingState = state == AndroidPlaybackOrchestratorState.PLAYING_SINGLE
                if (restorePlayingState) setState(AndroidPlaybackOrchestratorState.PRELOADING_NEXT)
                prepareStandby(nextIndex, 0L)
                androidXfadeLog("preload complete fromIndex=$currentIndex toIndex=$nextIndex standby=${standbyEngine.name}")
                if (restorePlayingState && state == AndroidPlaybackOrchestratorState.PRELOADING_NEXT) {
                    setState(AndroidPlaybackOrchestratorState.PLAYING_SINGLE)
                }
            } catch (error: CancellationException) {
                androidXfadeLog("preload cancelled toIndex=$nextIndex")
                if (state == AndroidPlaybackOrchestratorState.PRELOADING_NEXT) {
                    setState(if (playWhenReady) AndroidPlaybackOrchestratorState.PLAYING_SINGLE else AndroidPlaybackOrchestratorState.PAUSED)
                }
                throw error
            } catch (error: Exception) {
                androidXfadeLog("preload failed toIndex=$nextIndex error=${error.message}")
                if (preloadTargetIndex == nextIndex) {
                    preloadTargetIndex = null
                }
                standbyEngine.reset()
                if (state == AndroidPlaybackOrchestratorState.PRELOADING_NEXT) {
                    setState(if (playWhenReady) AndroidPlaybackOrchestratorState.PLAYING_SINGLE else AndroidPlaybackOrchestratorState.PAUSED)
                }
            }
        }
    }

    private fun canPreload(index: Int): Boolean {
        val item = queue.getOrNull(index) ?: return false
        return (item.duration ?: 0L) > 0L
    }

    private fun canCrossfade(fromIndex: Int, toIndex: Int, durationMs: Long): Boolean {
        val fromItem = queue.getOrNull(fromIndex) ?: return false
        val toItem = queue.getOrNull(toIndex) ?: return false
        val fromDuration = fromItem.duration ?: activeEngine.durationMs
        val toDuration = toItem.duration ?: 0L
        if (fromDuration <= 0L || toDuration <= 0L) return false
        return fromDuration > durationMs && toDuration > 0L
    }

    private fun nextIndexFor(index: Int): Int? {
        if (queue.isEmpty()) return null
        if (index < 0) return 0
        if (index + 1 < queue.size) return index + 1
        return if (repeatMode == RepeatMode.ALL) 0 else null
    }

    private fun previousIndexFor(index: Int): Int? {
        if (queue.isEmpty()) return null
        if (index - 1 >= 0) return index - 1
        return if (repeatMode == RepeatMode.ALL) queue.lastIndex else null
    }

    private suspend fun monitorActiveEngine() {
        if (state != AndroidPlaybackOrchestratorState.PLAYING_SINGLE || !playWhenReady) return
        if (activeEngine.playbackState != Player.STATE_ENDED) return
        val endedIndex = currentIndex
        val endedPosition = activeEngine.positionMs
        val nextIndex = nextIndexFor(currentIndex)
        if (nextIndex != null) {
            startTrackAt(nextIndex, 0L, emitTrackChange = true, oldPositionMs = endedPosition)
        } else {
            setState(AndroidPlaybackOrchestratorState.ENDED)
            delegate.onQueueEnded(endedIndex, endedPosition)
        }
    }

    private fun cancelCrossfade(errorCode: String, promoteIncoming: Boolean) {
        val fromIndex = activeCrossfadeFromIndex
        val toIndex = activeCrossfadeToIndex
        val wasCrossfading = fromIndex != null && toIndex != null
        crossfadeRunId += 1
        standbyMaintenanceJob?.cancel()
        standbyMaintenanceJob = null
        if (wasCrossfading) {
            emitCrossfade("cancelled", fromIndex!!, toIndex!!, errorCode = errorCode)
        }
        if (promoteIncoming && wasCrossfading && toIndex == currentIndex) {
            val outgoingEngine = activeEngine
            activeEngine = standbyEngine
            standbyEngine = outgoingEngine
            standbyEngine.reset()
            activeEngine.setVolume(if (playWhenReady) volume else 0f)
        } else if (wasCrossfading) {
            standbyEngine.reset()
            activeEngine.setVolume(if (playWhenReady) volume else 0f)
        }
        activeCrossfadeFromIndex = null
        activeCrossfadeToIndex = null
        preparedCrossfadeFromIndex = null
        preparedCrossfadeToIndex = null
        preparedCrossfadeSeekToMs = 0L
    }

    private fun ensureCrossfadeRunActive(runId: Int) {
        if (runId != crossfadeRunId) {
            throw RejectionException("Crossfade was cancelled.", "cancelled")
        }
    }

    private suspend fun delayChecked(durationMs: Long, runId: Int) {
        var remaining = durationMs
        while (remaining > 0) {
            ensureCrossfadeRunActive(runId)
            activeEngine.player.playerError?.let { error ->
                androidXfadeLog("crossfade wait interrupted by active engine error=${error.message}")
                throw RejectionException(
                    "Active engine failed while waiting to start crossfade.",
                    "crossfade_engine_error"
                )
            }
            val slice = min(remaining, 100L)
            delay(slice)
            remaining -= slice
        }
    }

    private fun emitCrossfade(
        state: String,
        fromIndex: Int,
        toIndex: Int,
        elapsedMs: Int? = null,
        fromVolume: Float? = null,
        toVolume: Float? = null,
        errorCode: String? = null
    ) {
        androidXfadeLog(
            "crossfade state=$state fromIndex=$fromIndex toIndex=$toIndex elapsedMs=$elapsedMs " +
                "fromVolume=$fromVolume toVolume=$toVolume error=${errorCode ?: "none"} active=${activeEngine.name} standby=${standbyEngine.name}"
        )
        delegate.onCrossfadeState(state, fromIndex, toIndex, elapsedMs, fromVolume, toVolume, errorCode)
        notifySnapshotChanged()
    }

    private fun setState(value: AndroidPlaybackOrchestratorState) {
        if (state != value) {
            androidXfadeLog("state $state -> $value currentIndex=$currentIndex active=${activeEngine.name} standby=${standbyEngine.name}")
            state = value
        }
        val mapped = playbackState
        if (lastEmittedPlaybackState != mapped) {
            lastEmittedPlaybackState = mapped
            delegate.onPlaybackStateChanged(mapped)
        }
        notifySnapshotChanged()
    }

    private fun notifySnapshotChanged() {
        delegate.onSnapshotChanged(snapshot())
    }

    private companion object {
        const val PREVIOUS_RESTART_THRESHOLD_MS = 3000L
        const val CROSSFADE_RUNNING_EVENT_INTERVAL_MS = 250L
        const val PREPARED_POSITION_TOLERANCE_MS = 250L
        const val INCOMING_STALL_GRACE_MS = 2000L
        const val INCOMING_STALL_TOLERANCE_MS = 200L
        const val OUTGOING_END_TOLERANCE_MS = 150L
        const val POST_CROSSFADE_SETTLE_MS = 1500L
        const val POST_CROSSFADE_PRELOAD_LEAD_MS = 8000L
    }
}
