package timber.log

/** Stand-in for Timber (the engine's log line also goes to android.util.Log). */
object Timber {
    fun tag(tag: String): Tree = Tree

    object Tree {
        fun d(message: String) = Unit
    }
}
