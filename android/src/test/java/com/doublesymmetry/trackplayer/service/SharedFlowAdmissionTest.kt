package com.doublesymmetry.trackplayer.service

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SharedFlowAdmissionTest {
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
}
