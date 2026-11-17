package okhttp3

/** Stand-in for OkHttp's Headers (coil's, see coil/ImageLoader.kt): the shapes KotlinAudio names. */
class Headers private constructor() {
    class Builder {
        fun build(): Headers = Headers()
    }

    companion object {
        fun Map<String, String>.toHeaders(): Headers = Headers()
    }
}
