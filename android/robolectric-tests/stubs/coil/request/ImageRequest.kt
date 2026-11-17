package coil.request

import android.content.Context
import android.graphics.drawable.Drawable
import okhttp3.Headers

/** Stand-in for coil's request (see coil/ImageLoader.kt). */
class ImageRequest private constructor() {
    class Builder(@Suppress("UNUSED_PARAMETER") context: Context) {
        fun data(data: Any?): Builder = this
        fun headers(headers: Headers): Builder = this
        fun target(onSuccess: (Drawable) -> Unit): Builder = this
        fun build(): ImageRequest = ImageRequest()
    }
}

interface Disposable {
    fun dispose()
}
