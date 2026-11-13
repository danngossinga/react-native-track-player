import type { AndroidOptions } from './AndroidOptions';
import type { FeedbackOptions } from './FeedbackOptions';
import type { ResourceObject } from './ResourceObject';
import type { RatingType, Capability } from '../constants';

export interface UpdateOptions {
  android?: AndroidOptions;
  ratingType?: RatingType;
  forwardJumpInterval?: number;
  backwardJumpInterval?: number;
  progressUpdateEventInterval?: number; // in seconds

  // ios
  likeOptions?: FeedbackOptions;
  dislikeOptions?: FeedbackOptions;
  bookmarkOptions?: FeedbackOptions;

  capabilities?: Capability[];

  /**
   * Crossfade backend: how long, in milliseconds, a track may take to become ready before the load
   * fails. Android bounds the whole load and every seek (`crossfade_prepare_timeout`,
   * `crossfade_seek_timeout`); iOS bounds the wait from a playable asset to a ready item, and a
   * backend switch and the play used to resume after an interruption wait this long plus 5 s (at
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

  // android
  /**
   * @deprecated Use `android` options and `appKilledPlaybackMode` instead.
   * @example
   * ```
   * await TrackPlayer.updateOptions({
   *   android: {
   *     appKilledPlaybackMode: AppKilledPlaybackMode.PausePlayback
   *  },
   * });
   *  ```
   */
  stoppingAppPausesPlayback?: boolean;
  /**
   * @deprecated use `TrackPlayer.updateOptions({ android: { alwaysPauseOnInterruption: boolean }})` instead
   */
  alwaysPauseOnInterruption?: boolean;
  notificationCapabilities?: Capability[];
  compactCapabilities?: Capability[];

  icon?: ResourceObject;
  playIcon?: ResourceObject;
  pauseIcon?: ResourceObject;
  stopIcon?: ResourceObject;
  previousIcon?: ResourceObject;
  nextIcon?: ResourceObject;
  rewindIcon?: ResourceObject;
  forwardIcon?: ResourceObject;
  color?: number;
}
