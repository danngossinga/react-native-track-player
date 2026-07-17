package com.doublesymmetry.trackplayer.module

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException

internal suspend fun completePlaybackCommand(
    operation: suspend () -> Unit,
    resolve: () -> Unit,
    reject: (Exception) -> Unit
) {
    val terminal = AtomicBoolean(false)
    val failure = try {
        operation()
        null
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        error
    }

    if (!terminal.compareAndSet(false, true)) return
    if (failure == null) resolve() else reject(failure)
}
