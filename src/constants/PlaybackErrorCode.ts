/**
 * Error codes the player rejects a command with and reports in `PlaybackError` events, the same
 * on iOS and Android. Other codes (from the platform players) can appear too.
 */
export enum PlaybackErrorCode {
  /**
   * The system did not give the audio to this player (decision B): an Android audio focus
   * request was denied, or iOS could not activate the audio session or a call (an interruption)
   * is in progress. Nothing plays (paused, `playWhenReady` false) and nothing retries by
   * itself; a later play tries again. `play()` / `setPlayWhenReady(true)` reject with it; a
   * play no one awaits (a remote control on Android's crossfade backend, an interruption's
   * resume) emits it as `PlaybackError`. Showing a message (for example "can't play during a
   * call") is up to the app.
   */
  AudioFocusRefused = 'audio_focus_refused',
  /** A crossfade-backend play start gave up (`playStartTimeoutMs`, `stallTimeoutMs`). */
  CrossfadePlayStartTimeout = 'crossfade_play_start_timeout',
  /** The crossfade backend's player failed during a play start. */
  CrossfadeEngineError = 'crossfade_engine_error',
  /** A crossfade whose incoming song did not start (the outgoing song plays on). */
  CrossfadeStartFailed = 'crossfade_start_failed',
  /** A standard-backend seek did not complete (`standardSeekTimeoutMs`, `stallTimeoutMs`). */
  StandardSeekTimeout = 'standard_seek_timeout',
}
