export type PlaybackBackendConfig =
  | { type: 'standard' }
  | { type: 'pingPong'; engineMode?: 'orchestratedDualEngine' };
