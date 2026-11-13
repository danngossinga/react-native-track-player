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
   * you intend to use audio in your app.
   *
   * With `autoHandleInterruptions: true` and
   * `androidAudioContentType: AndroidAudioContentType.Speech`, the audio will be
   * paused during short interruptions, such as when a message arrives.
   * Otherwise the playback volume is reduced while the notification is playing.
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
   * Indicates whether the player should automatically handle audio interruptions.
   * Defaults to `false`.
   */
  autoHandleInterruptions?: boolean;
  /**
   * Enables native two-player crossfade support when available.
   * Currently implemented on Android and iOS in this fork.
   * Defaults to `false`.
   */
  crossfade?: boolean;
  /**
   * Crossfade backend: how long, in milliseconds, a track may take to become ready before the load
   * fails. Android bounds the whole load and every seek (`crossfade_prepare_timeout`,
   * `crossfade_seek_timeout`); iOS bounds the wait from a playable asset to a ready item, and a
   * backend switch and the play used to resume after an interruption wait at least this long plus 5 s (at
   * least 10 s). Defaults to 5000. A value that is not
   * a number from 1 to 2147483646 is ignored.
   */
  prepareTimeoutMs?: number;
  /**
   * iOS crossfade backend: how long, in milliseconds, playback may take to start (after `play`, a
   * load that plays at once, or the incoming song of a crossfade) before it fails. Defaults to
   * 8000. A backend switch and the play used to resume after an interruption wait at least this
   * long plus 2 s. Same bounds and rules as `prepareTimeoutMs`.
   */
  playStartTimeoutMs?: number;
  /**
   * Standard backend (iOS and Android): how long, in milliseconds, a track restored by a backend
   * switch may take to be ready. Defaults to 5000. Same bounds and rules as `prepareTimeoutMs`.
   */
  standardReadyTimeoutMs?: number;
  /**
   * iOS standard backend: how long, in milliseconds, a seek may take before it fails
   * (`standard_seek_timeout`). Defaults to 25000. Same bounds and rules as `prepareTimeoutMs`.
   */
  standardSeekTimeoutMs?: number;
  /**
   * Compatibility alias for selecting the iOS crossfade engine.
   * Both values now use the RNTP-owned orchestrated dual engine.
   * @deprecated RNTP owns a single crossfade engine; omit this option.
   */
  crossfadeEngineMode?: 'orchestratedDualEngine' | 'legacyHybrid';
}
