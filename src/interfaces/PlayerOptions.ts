import type {
  AndroidAudioContentType,
  IOSCategory,
  IOSCategoryMode,
  IOSCategoryOptions,
} from '../constants';

export interface PlayerOptions {
  /**
   * Minimum duration of media that the player will attempt to buffer in seconds.
   *
   * Supported on Android & iOS.
   *
   * @throws Will throw on Android if min buffer is higher than max buffer.
   * @default 50
   */
  minBuffer?: number;
  /**
   * Maximum duration of media that the player will attempt to buffer in seconds.
   * Max buffer may not be lower than min buffer.
   *
   * Supported on Android only.
   *
   * @throws Will throw if max buffer is lower than min buffer.
   * @default 50
   */
  maxBuffer?: number;
  /**
   * Duration in seconds that should be kept in the buffer behind the current
   * playhead time.
   *
   * Supported on Android only.
   *
   * @default 0
   */
  backBuffer?: number;
  /**
   * Duration of media in seconds that must be buffered for playback to start or
   * resume following a user action such as a seek.
   *
   * Supported on Android only.
   *
   * @default 2.5
   */
  playBuffer?: number;
  /**
   * Maximum cache size in kilobytes.
   *
   * Supported on Android only.
   *
   * @default 0
   */
  maxCacheSize?: number;
  /**
   * [AVAudioSession.Category](https://developer.apple.com/documentation/avfoundation/avaudiosession/1616615-category)
   * for iOS. Sets on `play()`.
   */
  iosCategory?: IOSCategory;
  /**
   * (iOS only) The audio session mode, together with the audio session category,
   * indicates to the system how you intend to use audio in your app. You can use
   * a mode to configure the audio system for specific use cases such as video
   * recording, voice or video chat, or audio analysis.
   * Sets on `play()`.
   *
   * See https://developer.apple.com/documentation/avfoundation/avaudiosession/1616508-mode
   */
  iosCategoryMode?: IOSCategoryMode;
  /**
   * [AVAudioSession.CategoryOptions](https://developer.apple.com/documentation/avfoundation/avaudiosession/1616503-categoryoptions) for iOS.
   * Sets on `play()`.
   */
  iosCategoryOptions?: IOSCategoryOptions[];
  /**
   * (Android only) The audio content type indicates to the android system how
   * you intend to use audio in your app (the players' audio attributes and the
   * audio focus request).
   *
   * It no longer changes interruptions: every interruption pauses, a short one
   * (a can-duck loss such as a message sound) too, whatever the type, and
   * `autoHandleInterruptions` decides the resume, as on iOS.
   *
   * @default AndroidAudioContentType.Music
   */
  androidAudioContentType?: AndroidAudioContentType;
  /**
   * Indicates whether the player should automatically delay playback in order to minimize stalling.
   * Defaults to `true`.
   * @deprecated This option has been nominated for removal in a future version
   * of RNTP. If you have this set to `true`, you can safely remove this from
   * the options. If you are setting this to `false` and have a reason for that,
   * please post a comment in the following discussion: https://github.com/doublesymmetry/react-native-track-player/pull/1695
   * and describe why you are doing so.
   */
  waitForBuffer?: boolean;
  /**
   * Indicates whether the player should automatically update now playing metadata data in control center / notification.
   * Defaults to `true`.
   */
  autoUpdateMetadata?: boolean;
  /**
   * Calls, other apps' audio and headphones, the same on iOS and Android and on both backends
   * (standard and crossfade): playback always pauses when the audio is taken away (a call, an
   * audio focus loss, can-duck included) or the headphones are unplugged. With this option, it
   * resumes by itself when the interruption ends, if the system allows it (iOS `shouldResume`,
   * Android focus gain after a transient loss) and the user did not pause or play meanwhile; a
   * permanent loss or an unplug never resumes. `remote-duck` reports `paused` and `permanent`
   * with the same meaning on both platforms. Defaults to `false`.
   */
  autoHandleInterruptions?: boolean;
  /**
   * Enables native two-player crossfade support when available.
   * Currently implemented on Android and iOS in this fork.
   * Defaults to `false`.
   */
  crossfade?: boolean;
  /**
   * How long, in milliseconds, any of the player's waits for a track (a crossfade load, seek or
   * play start, a standard backend's readiness or seek) may go on with no progress (no new media
   * downloaded or buffered) before it fails. Defaults to 10000. A slow load that keeps progressing
   * is not stopped by it, only by the wait's own total limit below. On Android, the
   * players' HTTP connect and read timeouts follow it too (instead of ExoPlayer's fixed 8 s), from
   * the next request on every track; the crossfade and the standard player alike. A value that is
   * not a number from 1 to 2147483646 is ignored.
   */
  stallTimeoutMs?: number;
  /**
   * Crossfade backend: the total limit, in milliseconds, for a track to become ready, even while
   * it progresses (`stallTimeoutMs` fails a stalled load sooner). Android bounds the whole load and
   * every seek (`crossfade_prepare_timeout`, `crossfade_seek_timeout`); iOS bounds the whole load
   * (playable stage, ready item, seek to the start position, preroll) and every seek. On iOS the
   * stage before the asset is playable has no progress signal, so only this limit ends it there;
   * `stallTimeoutMs` applies from the moment the asset is playable. An iOS crossfade seek (which
   * had no limit before) now fails after `stallTimeoutMs` with no progress or at this limit, and
   * the player then reports an error state. Defaults to 60000. Same bounds as `stallTimeoutMs`.
   */
  prepareTimeoutMs?: number;
  /**
   * Crossfade backend (iOS and Android): the total limit, in milliseconds, for playback to start
   * (after `play`, a load that plays at once, or the incoming song of a crossfade; the resume of a
   * fade paused mid-way does not wait). A start that loads nothing for `stallTimeoutMs` fails
   * sooner. On both platforms a failed start pauses, rejects with `crossfade_play_start_timeout`
   * (`crossfade_engine_error` when the player fails during the start) and emits a
   * `playback-error` with that code, and a crossfade whose incoming song does not
   * start rejects with `crossfade_start_failed` while the outgoing song plays on. Defaults to
   * 60000. On iOS, a backend switch waits at most this plus `prepareTimeoutMs` plus 5 s (at
   * least 10 s); on Android it does not block a thread and is bounded by the load and play-start
   * waits themselves. The play that resumes after an interruption is not awaited on either
   * platform. Same bounds as `stallTimeoutMs`.
   */
  playStartTimeoutMs?: number;
  /**
   * Standard backend (iOS and Android): the total limit, in milliseconds, for a track restored by
   * a backend switch to be ready. Defaults to 60000. Same bounds as `stallTimeoutMs`.
   */
  standardReadyTimeoutMs?: number;
  /**
   * Backend switch (iOS and Android, both backends): how far, in milliseconds, the restored
   * position may be from the switched-from position for the new backend to count as restored
   * (otherwise it seeks, or keeps waiting for readiness). Defaults to 750. Same bounds as
   * `stallTimeoutMs`.
   */
  backendSwitchPositionToleranceMs?: number;
  /**
   * Standard backend (iOS and Android): the total limit, in milliseconds, for a seek
   * (`standard_seek_timeout`); a seek that makes no progress for `stallTimeoutMs` fails sooner
   * (Android: ExoPlayer's buffered position; iOS: new buffered time and the media bytes of its
   * item, as the crossfade waits). Defaults to 60000. Same bounds as `stallTimeoutMs`.
   */
  standardSeekTimeoutMs?: number;
  /**
   * Crossfade backend: how long, in milliseconds, a crossfade waits for the incoming track to
   * start moving before it falls back to playing that track alone (`incoming_stalled`). Read at
   * every fade step. Defaults to 2000. Same bounds as `stallTimeoutMs`.
   */
  incomingStallGraceMs?: number;
  /**
   * Android (crossfade and standard backends): the bandwidth, in bits per second, each track starts from before
   * the player has measured the network. An adaptive (HLS/DASH) track starts at the highest
   * rendition whose bitrate fits about 70 % of it (ExoPlayer's bandwidth fraction), or at the
   * lowest when none fits, and climbs as the player measures. Defaults to 96000. Also accepted by
   * `updateOptions`. It is a start-of-track estimate: a new value is used at the next track
   * start; the playing track is not reset mid-track (its rendition follows the measured
   * bandwidth). A value that is not a number from 1 to 2147483646 is ignored.
   */
  initialBitrateEstimateBps?: number;
  /**
   * Compatibility alias for selecting the iOS crossfade engine.
   * Both values now use the RNTP-owned orchestrated dual engine.
   * @deprecated RNTP owns a single crossfade engine; omit this option.
   */
  crossfadeEngineMode?: 'orchestratedDualEngine' | 'legacyHybrid';
}
