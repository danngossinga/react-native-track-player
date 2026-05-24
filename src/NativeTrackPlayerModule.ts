import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';
import type {
  Double,
  Float,
  UnsafeObject,
} from 'react-native/Libraries/Types/CodegenTypes';

import type { PlaybackState, Progress, Track } from './interfaces';

type NullableUnsafeObject = UnsafeObject | null | undefined;
type NullableUnsafeObjectArray = UnsafeObject[] | null | undefined;

export type TrackPlayerConstants = {
  CAPABILITY_PLAY: number;
  CAPABILITY_PLAY_FROM_ID: number;
  CAPABILITY_PLAY_FROM_SEARCH: number;
  CAPABILITY_PAUSE: number;
  CAPABILITY_STOP: number;
  CAPABILITY_SEEK_TO: number;
  CAPABILITY_SKIP: number;
  CAPABILITY_SKIP_TO_NEXT: number;
  CAPABILITY_SKIP_TO_PREVIOUS: number;
  CAPABILITY_SET_RATING: number;
  CAPABILITY_JUMP_FORWARD: number;
  CAPABILITY_JUMP_BACKWARD: number;
  CAPABILITY_LIKE: number;
  CAPABILITY_DISLIKE: number;
  CAPABILITY_BOOKMARK: number;
  PITCH_ALGORITHM_LINEAR: number;
  PITCH_ALGORITHM_MUSIC: number;
  PITCH_ALGORITHM_VOICE: number;
  RATING_HEART: number;
  RATING_THUMBS_UP_DOWN: number;
  RATING_3_STARS: number;
  RATING_4_STARS: number;
  RATING_5_STARS: number;
  RATING_PERCENTAGE: number;
  REPEAT_OFF: number;
  REPEAT_TRACK: number;
  REPEAT_QUEUE: number;
};

export interface Spec extends TurboModule, TrackPlayerConstants {
  getConstants: () => TrackPlayerConstants;
  addListener: (eventName: string) => void;
  removeListeners: (count: Double) => void;

  setupPlayer(data?: NullableUnsafeObject): Promise<void>;
  isServiceRunning(): Promise<boolean>;
  updateOptions(options?: NullableUnsafeObject): Promise<void>;
  add(
    objects?: NullableUnsafeObjectArray,
    insertBeforeIndex?: Double
  ): Promise<Double | void>;
  load(trackDict?: NullableUnsafeObject): Promise<Double | void>;
  move(fromIndex: Double, toIndex: Double): Promise<void>;
  remove(objects?: ReadonlyArray<Double> | null): Promise<void>;
  removeUpcomingTracks(): Promise<void>;
  skip(trackIndex: Double, initialTime: Double): Promise<void>;
  skipToNext(initialTime: Double): Promise<void>;
  skipToPrevious(initialTime: Double): Promise<void>;
  reset(): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  stop(): Promise<void>;
  setPlayWhenReady(playWhenReady: boolean): Promise<boolean>;
  getPlayWhenReady(): Promise<boolean>;
  retry(): Promise<void>;
  seekTo(time: Double): Promise<void>;
  seekBy(offset: Double): Promise<void>;
  setRepeatMode(repeatMode: Double): Promise<Double>;
  getRepeatMode(): Promise<Double>;
  setVolume(volume: Float): Promise<void>;
  crossFadePrepare(previous: boolean, seekTo: Double): Promise<void>;
  crossFade(
    fadeDuration: Double,
    fadeInterval: Double,
    fadeToVolume: Double,
    waitUntil: Double
  ): Promise<void>;
  getVolume(): Promise<Double>;
  setRate(rate: Float): Promise<void>;
  getRate(): Promise<Double>;
  getTrack(trackIndex: Double): Promise<Track | undefined>;
  getQueue(): Promise<Track[]>;
  setQueue(objects?: NullableUnsafeObjectArray): Promise<void>;
  getActiveTrack(): Promise<Track | undefined>;
  getActiveTrackIndex(): Promise<Double | null>;
  getDuration(): Promise<Double>;
  getBufferedPosition(): Promise<Double>;
  getPosition(): Promise<Double>;
  getProgress(): Promise<Progress>;
  getPlaybackState(): Promise<PlaybackState>;
  updateMetadataForTrack(
    trackIndex: Double,
    metadata?: NullableUnsafeObject
  ): Promise<void>;
  clearNowPlayingMetadata(): Promise<void>;
  updateNowPlayingMetadata(metadata?: NullableUnsafeObject): Promise<void>;
}

export default TurboModuleRegistry.get<Spec>('TrackPlayerModule');
