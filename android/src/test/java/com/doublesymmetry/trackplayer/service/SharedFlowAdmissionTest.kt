package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.kotlinaudio.event.PlayerEventHolder
import com.doublesymmetry.kotlinaudio.models.AudioPlayerState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SharedFlowAdmissionTest {
    @Test
    fun kotlinAudioMainScopeRestoreEmissionIsDrainedBeforeAdmissionFlip() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(main)
        try {
            val holder = PlayerEventHolder()
            val update = holder.javaClass.getDeclaredMethod(
                "updateAudioPlayerState\$kotlin_audio_release",
                AudioPlayerState::class.java
            )
            val gate = SharedFlowAdmissionGate()
            val received = mutableListOf<AudioPlayerState>()
            val collector = backgroundScope.collectWithAdmission(
                holder.stateChange,
                gate,
                received::add
            )

            update.invoke(holder, AudioPlayerState.LOADING)
            gate.admitAfterProducerDrain(backgroundScope)
            runCurrent()
            update.invoke(holder, AudioPlayerState.PAUSED)
            runCurrent()

            assertEquals(listOf(AudioPlayerState.PAUSED), received)
            collector.cancel()
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun restoreEmissionQueuedBeforeAdmissionIsRejectedWhenDeliveredAfterAdmission() = runTest {
        val source = MutableSharedFlow<String>(replay = 1)
        val gate = SharedFlowAdmissionGate()
        val received = mutableListOf<String>()
        val collector = backgroundScope.collectWithAdmission(source, gate, received::add)

        backgroundScope.launch { source.emit("restore") }
        gate.admitAfterProducerDrain(backgroundScope)
        runCurrent()
        source.emit("canonical")
        runCurrent()

        assertEquals(listOf("canonical"), received)
        collector.cancel()
    }

    @Test
    fun candidateReplayAndRestoreEventsAreQuarantinedUntilCommit() = runTest {
        val source = MutableSharedFlow<String>(replay = 1)
        source.emit("candidate-create")
        val gate = SharedFlowAdmissionGate()
        val delivered = mutableListOf<String>()
        val job = collectWithAdmission(source, gate) { delivered += it }

        source.emit("candidate-restore")
        runCurrent()
        assertEquals(emptyList<String>(), delivered)

        gate.admit()
        source.emit("post-commit")
        runCurrent()
        assertEquals(listOf("post-commit"), delivered)
        job.cancel()
    }

    @Test
    fun equalValuedReplacementIsClassifiedByAdmissionNotEquality() = runTest {
        val source = MutableSharedFlow<String>(replay = 1)
        source.emit("same-value")
        val gate = SharedFlowAdmissionGate()
        val delivered = mutableListOf<String>()
        val job = collectWithAdmission(source, gate) { delivered += it }

        // Equal replay replacement after the early subscription is still
        // pre-commit and must be quarantined without equality heuristics.
        source.emit("same-value")
        runCurrent()
        gate.admit()

        source.emit("same-value")
        runCurrent()
        assertEquals(listOf("same-value"), delivered)
        job.cancel()
    }

    @Test
    fun rollbackDrainRejectsQuiescenceEventsBeforeCanonicalAdmission() = runTest {
        val source = MutableSharedFlow<String>(extraBufferCapacity = 4)
        val gate = SharedFlowAdmissionGate()
        val received = mutableListOf<String>()
        val ordering = mutableListOf<String>()
        val collector = backgroundScope.collectWithAdmission(source, gate, received::add)
        gate.admit()
        source.emit("playing")
        runCurrent()

        gate.suspendAdmission()
        backgroundScope.launch { source.emit("quiescence-paused") }
        val resumed = gate.admitAfterProducerDrain(backgroundScope) {
            ordering += "canonical"
        }
        runCurrent()
        resumed.join()
        ordering += "barrier-release"
        source.emit("post-rollback")
        runCurrent()

        assertEquals(listOf("playing", "post-rollback"), received)
        assertEquals(listOf("canonical", "barrier-release"), ordering)
        collector.cancel()
    }
}
