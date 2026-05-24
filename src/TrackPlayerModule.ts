import { NativeModules } from 'react-native';

import NativeTrackPlayerModule, {
  type Spec,
} from './NativeTrackPlayerModule';

const { TrackPlayerModule: LegacyTrackPlayerModule } = NativeModules;
const TrackPlayerModule = NativeTrackPlayerModule ?? LegacyTrackPlayerModule;

if (!TrackPlayerModule) {
  throw new Error('Native module TrackPlayerModule was not found.');
}

export default TrackPlayerModule as Spec;
