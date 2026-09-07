import type { PlaybackBackendConfig, PlayerLifecycleState } from './interfaces';

type PlaybackBackendBridge = {
  setPlaybackBackend(
    config: PlaybackBackendConfig
  ): Promise<PlayerLifecycleState>;
};

function isPlaybackBackendConfig(
  value: unknown
): value is PlaybackBackendConfig {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }

  const config = value as Record<string, unknown>;
  const keys = Object.keys(config);
  if (config.type === 'standard') {
    return keys.length === 1;
  }

  if (config.type !== 'pingPong') {
    return false;
  }

  return (
    keys.every((key) => key === 'type' || key === 'engineMode') &&
    (config.engineMode === undefined ||
      config.engineMode === 'orchestratedDualEngine')
  );
}

function invalidPlaybackBackendConfigError() {
  return Object.assign(new TypeError('Invalid playback backend config'), {
    code: 'invalid_playback_backend_config',
  });
}

export function setPlaybackBackendOn(
  bridge: PlaybackBackendBridge,
  value: unknown
): Promise<PlayerLifecycleState> {
  if (!isPlaybackBackendConfig(value)) {
    return Promise.reject(invalidPlaybackBackendConfigError());
  }

  return bridge.setPlaybackBackend(value);
}
