package com.doublesymmetry.trackplayer.model

import android.os.Bundle

/** Stand-in for the library's Track (the engine reads its original item and queue id). */
class Track(val originalItem: Bundle? = null, val queueId: Long = 0L)
