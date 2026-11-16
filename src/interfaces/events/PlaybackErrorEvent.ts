import type { PlaybackErrorCode } from '../../constants/PlaybackErrorCode';

export interface PlaybackErrorEvent {
  /** The error code: one of {@link PlaybackErrorCode}, or a platform player's own code. */
  code: PlaybackErrorCode | (string & {});
  /** The error message */
  message: string;
}
