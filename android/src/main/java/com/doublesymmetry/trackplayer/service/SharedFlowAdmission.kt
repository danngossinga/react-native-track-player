package com.doublesymmetry.trackplayer.service

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

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
