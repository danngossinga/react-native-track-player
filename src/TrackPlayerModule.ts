import { NativeModules } from 'react-native';

import NativeTrackPlayerModule, {
  type TrackPlayerConstants,
  type Spec,
} from './NativeTrackPlayerModule';

type TrackPlayerModuleShape = Spec & TrackPlayerConstants;

const { TrackPlayerModule: LegacyTrackPlayerModule } = NativeModules;
const NativeModule = NativeTrackPlayerModule ?? LegacyTrackPlayerModule;

if (!NativeModule) {
  throw new Error('Native module TrackPlayerModule was not found.');
}

const constants =
  typeof NativeModule.getConstants === 'function'
    ? NativeModule.getConstants()
    : {};

const TrackPlayerModule = new Proxy(NativeModule, {
  get(target, property, receiver) {
    if (
      typeof property === 'string' &&
      Object.prototype.hasOwnProperty.call(constants, property)
    ) {
      return constants[property as keyof TrackPlayerConstants];
    }
    return Reflect.get(target, property, receiver);
  },
});

export default TrackPlayerModule as TrackPlayerModuleShape;
