package com.doublesymmetry.trackplayer.service

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * Product flows subscribe while the Standard candidate is created, before its
 * restore can emit. The binding is admitted only after logical commit. There is
 * no unsubscribe/resubscribe window, so even an equal-valued replay replacement
 * is classified by which side of the admission barrier collected it.
 */
internal class SharedFlowAdmissionGate {
    private val admitted = AtomicBoolean(false)

    fun admit() {
        admitted.set(true)
    }

    fun suspendAdmission() {
        admitted.set(false)
    }

    /**
     * KotlinAudio publishes PlayerEventHolder updates with MainScope.launch.
     * Starting this fence on the same Main-backed owner scope and yielding once
     * lets both the queued producer and the resumed collector run while the gate
     * is still quarantined. The admission flip and canonical event are therefore
     * ordered after every restore event already posted by the candidate.
     */
    fun admitAfterProducerDrain(
        scope: CoroutineScope,
        onAdmitted: () -> Unit = {}
    ): Job = scope.launch(start = CoroutineStart.DEFAULT) {
        yield()
        admitted.set(true)
        onAdmitted()
    }

    fun acceptsEvents(): Boolean = admitted.get()
}

internal fun <T> CoroutineScope.collectWithAdmission(
    source: SharedFlow<T>,
    gate: SharedFlowAdmissionGate,
    collector: suspend (T) -> Unit
): Job = launch(start = CoroutineStart.UNDISPATCHED) {
    source.collect { value ->
        if (gate.acceptsEvents()) collector(value)
    }
}
