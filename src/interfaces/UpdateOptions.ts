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
   * How long, in milliseconds, any of the player's waits for a track (a crossfade load, seek or
   * play start, a standard backend's readiness or seek) may go on with no progress (no new media
   * downloaded or buffered) before it fails. Defaults to 10000. A slow load that keeps progressing
   * is not stopped by it, only by the wait's own total limit below. On Android, the crossfade
   * players' HTTP connect and read timeouts follow it too (instead of ExoPlayer's fixed 8 s), from
   * the next load or seek; the standard player (KotlinAudio) keeps the fixed 8 s. A value that is
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
   * iOS crossfade backend: the total limit, in milliseconds, for playback to start (after `play`,
   * a load that plays at once, or the incoming song of a crossfade). Defaults to 60000. A backend
   * switch and the play used to resume after an interruption wait at most this plus
   * `prepareTimeoutMs` plus 5 s (at least 10 s). Same bounds as `stallTimeoutMs`.
   */
  playStartTimeoutMs?: number;
  /**
   * Standard backend (iOS and Android): the total limit, in milliseconds, for a track restored by
   * a backend switch to be ready. Defaults to 60000. Same bounds as `stallTimeoutMs`.
   */
  standardReadyTimeoutMs?: number;
  /**
   * iOS standard backend: the total limit, in milliseconds, for a seek (`standard_seek_timeout`).
   * Defaults to 60000. Same bounds as `stallTimeoutMs`.
   */
  standardSeekTimeoutMs?: number;
  /**
   * Crossfade backend: how long, in milliseconds, a crossfade waits for the incoming track to
   * start moving before it falls back to playing that track alone (`incoming_stalled`). Read at
   * every fade step. Defaults to 2000. Same bounds as `stallTimeoutMs`.
   */
  incomingStallGraceMs?: number;
  /**
   * Android crossfade backend: the bandwidth, in bits per second, each track starts from before
   * the player has measured the network. An adaptive (HLS/DASH) track starts at the highest
   * rendition whose bitrate fits about 70 % of it (ExoPlayer's bandwidth fraction), or at the
   * lowest when none fits, and climbs as the player measures. Defaults to 96000. Also accepted by
   * `updateOptions`. It is a start-of-track estimate: a new value is used at the next track
   * start; the playing track is not reset mid-track (its rendition follows the measured
   * bandwidth). A value that is not a number from 1 to 2147483646 is ignored.
   */
  initialBitrateEstimateBps?: number;

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
