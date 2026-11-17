package timber.log

/** Stand-in for Timber (the engine's log line also goes to android.util.Log; KotlinAudio's debug lines). */
object Timber {
    fun tag(tag: String): Tree = Tree

    fun d(message: String, vararg args: Any?) = Unit

    object Tree {
        fun d(message: String) = Unit
    }
}
