import type { State } from '../constants';

export type PlayerLifecycleBackend = 'none' | 'standard' | 'crossfade';

export type PlayerLifecyclePhase =
  | 'uninitialized'
  | 'settingUp'
  | 'ready';

export type PlayerLifecycleState = {
  phase: PlayerLifecyclePhase;
  serviceBound: boolean;
  playerInitialized: boolean;
  setupInProgress: boolean;
  canAcceptCommands: boolean;
  playbackState: State;
  playWhenReady: boolean;
  backend: PlayerLifecycleBackend;
  queueSize: number;
  activeTrackIndex: number | null;
};
