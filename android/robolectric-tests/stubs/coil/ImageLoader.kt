package coil

import android.content.Context
import coil.request.Disposable
import coil.request.ImageRequest

// Stand-ins for coil 2.2.0 (vendored KotlinAudio loads the notification's artwork with it): not
// in this machine's offline Gradle 8 cache. No artwork is loaded in these tests.

interface ImageLoader {
    fun enqueue(request: ImageRequest): Disposable
}

val Context.imageLoader: ImageLoader
    get() = object : ImageLoader {
        override fun enqueue(request: ImageRequest): Disposable = object : Disposable {
            override fun dispose() = Unit
        }
    }
