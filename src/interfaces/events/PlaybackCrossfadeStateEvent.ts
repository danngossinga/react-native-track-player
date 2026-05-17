export type PlaybackCrossfadeState =
  | 'prepared'
  | 'scheduled'
  | 'started'
  | 'running'
  | 'completed'
  | 'cancelled'
  | 'error';

export interface PlaybackCrossfadeStateEvent {
  state: PlaybackCrossfadeState;
  fromIndex?: number;
  toIndex?: number;
  elapsedMs?: number;
  fromVolume?: number;
  toVolume?: number;
  errorCode?: string;
}
