package com.doublesymmetry.trackplayer.service

import android.support.v4.media.session.MediaSessionCompat
import com.doublesymmetry.kotlinaudio.players.QueuedAudioPlayer
import java.lang.reflect.Field

/**
 * Physical MediaSession barrier for the pinned KotlinAudio v2.1.0 backend.
 *
 * KotlinAudio activates its private MediaSessionCompat in BaseAudioPlayer's
 * constructor and exposes no supported suspend/resume API. Resolve and verify
 * the exact pinned field before changing session state so dependency drift
 * fails loudly instead of allowing two active playback control surfaces.
 */
internal class KotlinAudioMediaSessionControl private constructor(
    private val mediaSession: MediaSessionCompat
) {
    fun deactivate() {
        mediaSession.isActive = false
    }

    fun activate() {
        mediaSession.isActive = true
    }

    internal fun isActive(): Boolean = mediaSession.isActive

    companion object {
        internal const val PINNED_OWNER_CLASS =
            "com.doublesymmetry.kotlinaudio.players.BaseAudioPlayer"
        internal const val PINNED_FIELD_NAME = "mediaSession"

        fun from(player: QueuedAudioPlayer): KotlinAudioMediaSessionControl {
            val field = resolvePinnedField()
            check(field.declaringClass.isAssignableFrom(player.javaClass)) {
                "KotlinAudio v2.1.0 MediaSession owner does not match QueuedAudioPlayer."
            }
            val session = try {
                field.get(player)
            } catch (error: ReflectiveOperationException) {
                throw incompatibleDependency(error)
            } as? MediaSessionCompat ?: throw incompatibleDependency()
            return KotlinAudioMediaSessionControl(session)
        }

        internal fun resolvePinnedField(): Field {
            val owner = try {
                Class.forName(PINNED_OWNER_CLASS)
            } catch (error: ClassNotFoundException) {
                throw incompatibleDependency(error)
            }
            val field = try {
                owner.getDeclaredField(PINNED_FIELD_NAME)
            } catch (error: NoSuchFieldException) {
                throw incompatibleDependency(error)
            }
            check(field.type == MediaSessionCompat::class.java) {
                "KotlinAudio v2.1.0 MediaSession field has an incompatible type."
            }
            try {
                field.isAccessible = true
            } catch (error: SecurityException) {
                throw incompatibleDependency(error)
            }
            return field
        }

        private fun incompatibleDependency(cause: Throwable? = null): IllegalStateException =
            IllegalStateException(
                "KotlinAudio v2.1.0 private MediaSession contract is unavailable. " +
                    "Keep KotlinAudio pinned or update KotlinAudioMediaSessionControl.",
                cause
            )
    }
}
