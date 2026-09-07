const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const consumerRoot = path.resolve(root, '..', 'expo-smart-hls-proxy');

function read(base, relativePath) {
  return fs.readFileSync(path.join(base, relativePath), 'utf8');
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function section(source, startToken, endToken) {
  const start = source.indexOf(startToken);
  const end = source.indexOf(endToken, start + startToken.length);
  if (start < 0 || end < 0) {
    throw new Error(`Unable to isolate section ${startToken}`);
  }
  return source.slice(start, end);
}

const nativeSpec = read(root, 'src/NativeTrackPlayerModule.ts');
const trackPlayer = read(root, 'src/trackPlayer.ts');
const playbackBackend = read(root, 'src/playbackBackend.ts');
const interfacesIndex = read(root, 'src/interfaces/index.ts');
const packageIndex = read(root, 'src/index.ts');
const iosBridge = read(root, 'ios/RNTrackPlayer/RNTrackPlayerBridge.m');
const iosTurboModule = read(root, 'ios/RNTrackPlayer/RNTrackPlayerTurboModule.mm');
const iosPlayer = read(root, 'ios/RNTrackPlayer/RNTrackPlayer.swift');
const androidModule = read(root, 'android/src/main/java/com/doublesymmetry/trackplayer/module/MusicModule.kt');
const androidService = read(root, 'android/src/main/java/com/doublesymmetry/trackplayer/service/MusicService.kt');
const androidFallback = read(root, 'android/src/main/jni/RNTrackPlayerSpec/RNTrackPlayerSpec-generated.cpp');
const consumerApp = read(consumerRoot, 'example-itunes-lites/App.tsx');

assert(
  nativeSpec.includes("import type {\n  PlaybackState,\n  PlayerLifecycleState,") ||
    nativeSpec.includes('PlayerLifecycleState'),
  'NativeTrackPlayerModule must type PlayerLifecycleState.'
);
assert(
  nativeSpec.includes('getPlayerLifecycle(): Promise<PlayerLifecycleState>;'),
  'NativeTrackPlayerModule must expose getPlayerLifecycle().'
);
assert(
  trackPlayer.includes('export function getPlayerLifecycle(): Promise<PlayerLifecycleState>') &&
    trackPlayer.includes('return TrackPlayer.getPlayerLifecycle();'),
  'Public trackPlayer API must expose getPlayerLifecycle().'
);
assert(
  interfacesIndex.includes("export * from './PlayerLifecycleState';"),
  'PlayerLifecycleState must be exported from interfaces.'
);
assert(
  interfacesIndex.includes("export * from './PlaybackBackendConfig';") &&
    packageIndex.includes('setPlaybackBackend') &&
    trackPlayer.includes('export function setPlaybackBackend(') &&
    trackPlayer.includes('setPlaybackBackendOn(TrackPlayer, config)'),
  'PlaybackBackendConfig and setPlaybackBackend must be exported by the public API.'
);
assert(
  nativeSpec.includes('setPlaybackBackend(config: UnsafeObject): Promise<PlayerLifecycleState>;') &&
    playbackBackend.includes('invalid_playback_backend_config') &&
    playbackBackend.includes('bridge.setPlaybackBackend(value)'),
  'The codegen boundary must use UnsafeObject while the JS boundary validates before bridge access.'
);
assert(
  iosBridge.includes('RCT_EXTERN_METHOD(getPlayerLifecycle:(RCTPromiseResolveBlock)resolve'),
  'iOS legacy bridge must export getPlayerLifecycle.'
);
assert(
  iosTurboModule.includes('- (void)getPlayerLifecycle:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;') &&
    iosTurboModule.includes('[self getPlayerLifecycle:resolve rejecter:reject];'),
  'iOS TurboModule bridge must forward getPlayerLifecycle.'
);
assert(
  iosBridge.includes('RCT_EXTERN_METHOD(setPlaybackBackend:(NSDictionary *)config') &&
    iosTurboModule.includes('- (void)setPlaybackBackend:(NSDictionary *)config resolver:') &&
    iosTurboModule.includes('[self setPlaybackBackend:config ?: @{} resolver:resolve rejecter:reject];'),
  'iOS legacy and TurboModule bridges must forward setPlaybackBackend.'
);
assert(
  iosPlayer.includes('private var setupInProgress = false') &&
    iosPlayer.includes('@objc(getPlayerLifecycle:rejecter:)') &&
    iosPlayer.includes('"playerInitialized": hasInitialized') &&
    iosPlayer.includes('"setupInProgress": setupInProgress') &&
    iosPlayer.includes('"canAcceptCommands": hasInitialized'),
  'iOS native player lifecycle must expose initialized/setup/canAcceptCommands truth.'
);
assert(
  !iosPlayer.includes('TODO That is probably always true') &&
    section(iosPlayer, '@objc(isServiceRunning:rejecter:)', '@objc(updateOptions:resolver:rejecter:)').includes('resolve(hasInitialized)'),
  'iOS isServiceRunning must no longer return the always-present player object.'
);
assert(
  androidModule.includes('@ReactMethod\n    fun getPlayerLifecycle(callback: Promise)') &&
    androidModule.includes('playerInitialized') &&
    androidModule.includes('setupInProgress') &&
    androidModule.includes('canAcceptCommands') &&
    androidModule.includes('playerSetUpPromise = null'),
  'Android module must expose lifecycle and clear setup promise after setup resolves.'
);
assert(
  androidModule.includes('fun setPlaybackBackend(config: ReadableMap?, callback: Promise)') &&
    androidFallback.includes('TRACK_PLAYER_PROMISE_METHOD(setPlaybackBackend') &&
    androidFallback.includes('methodMap_["setPlaybackBackend"] = MethodMetadata {1,'),
  'Android legacy/Turbo fallback maps must expose setPlaybackBackend with arity one.'
);
assert(
  androidService.includes('suspend fun getPlayerLifecycleBundle(') &&
    androidService.includes('val snapshot = getPlaybackBackendReadSnapshot()') &&
    androidService.includes('putString("playbackState", snapshot.playbackState.asLibState.state)') &&
    androidService.includes('putString("backend", if (snapshot.backendType == PlaybackBackendType.PING_PONG) "crossfade" else "standard")') &&
    iosPlayer.includes('let backendName = backend?.kind == .pingPong ? "crossfade" : (backend?.kind.rawValue ?? "none")'),
  'Native lifecycle must preserve the legacy crossfade backend discriminator.'
);
assert(
  !consumerApp.includes('TrackPlayer.isServiceRunning') &&
    consumerApp.includes('TrackPlayer.getPlayerLifecycle') &&
    consumerApp.includes('playerLifecycle.playerInitialized'),
  'example-itunes-lites must use getPlayerLifecycle instead of isServiceRunning.'
);

console.log('Player lifecycle contracts OK');
