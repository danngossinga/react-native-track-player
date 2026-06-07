#ifdef RCT_NEW_ARCH_ENABLED

#import <Foundation/Foundation.h>
#import <React/RCTEventEmitter.h>
#import <ReactCommon/RCTTurboModule.h>
#import <RNTrackPlayerSpec/RNTrackPlayerSpec.h>

#import <memory>

@interface RNTrackPlayer : RCTEventEmitter

- (NSDictionary *)constantsToExport;

- (void)setupPlayer:(NSDictionary *)data resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)isServiceRunning:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getPlayerLifecycle:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)updateOptions:(NSDictionary *)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)add:(NSArray *)objects before:(NSNumber *)trackIndex resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)move:(NSNumber *)fromIndex toIndex:(NSNumber *)toIndex resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)load:(NSDictionary *)trackDict resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)remove:(NSArray *)objects resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)removeUpcomingTracks:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)skip:(NSNumber *)trackIndex initialTime:(double)initialTime resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)skipToNext:(double)initialTime resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)skipToPrevious:(double)initialTime resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)reset:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)play:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)pause:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)stop:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setPlayWhenReady:(BOOL)playWhenReady resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getPlayWhenReady:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)retry:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)seekTo:(double)time resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)seekBy:(double)offset resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setRepeatMode:(NSNumber *)repeatMode resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getRepeatMode:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setVolume:(float)volume resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)crossFadePrepare:(BOOL)previous seekTo:(double)seekTo resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)crossFade:(double)fadeDuration fadeInterval:(double)fadeInterval fadeToVolume:(double)fadeToVolume waitUntil:(double)waitUntil resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getVolume:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setRate:(float)rate resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getRate:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getTrack:(NSNumber *)trackIndex resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getQueue:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setQueue:(NSArray *)objects resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getActiveTrack:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getActiveTrackIndex:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getDuration:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getBufferedPosition:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getPosition:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getProgress:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getPlaybackState:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)updateMetadataForTrack:(NSNumber *)trackIndex metadata:(NSDictionary *)metadata resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)clearNowPlayingMetadata:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)updateNowPlayingMetadata:(NSDictionary *)metadata resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;

@end

@interface RNTrackPlayer (TurboModuleConformance) <RCTTurboModule>
@end

@implementation RNTrackPlayer (TurboModule)

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeTrackPlayerModuleSpecJSI>(params);
}

- (NSDictionary *)getConstants
{
  return [self constantsToExport];
}

- (void)setupPlayer:(NSDictionary *)data resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self setupPlayer:data ?: @{} resolver:resolve rejecter:reject];
}

- (void)isServiceRunning:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self isServiceRunning:resolve rejecter:reject];
}

- (void)getPlayerLifecycle:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getPlayerLifecycle:resolve rejecter:reject];
}

- (void)updateOptions:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self updateOptions:options ?: @{} resolver:resolve rejecter:reject];
}

- (void)add:(NSArray *)objects insertBeforeIndex:(NSNumber *)insertBeforeIndex resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self add:objects ?: @[] before:insertBeforeIndex ?: @(-1) resolver:resolve rejecter:reject];
}

- (void)load:(NSDictionary *)trackDict resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self load:trackDict ?: @{} resolver:resolve rejecter:reject];
}

- (void)move:(double)fromIndex toIndex:(double)toIndex resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self move:@(fromIndex) toIndex:@(toIndex) resolver:resolve rejecter:reject];
}

- (void)remove:(NSArray *)objects resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self remove:objects ?: @[] resolver:resolve rejecter:reject];
}

- (void)removeUpcomingTracks:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self removeUpcomingTracks:resolve rejecter:reject];
}

- (void)skip:(double)trackIndex initialTime:(double)initialTime resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self skip:@(trackIndex) initialTime:initialTime resolver:resolve rejecter:reject];
}

- (void)skipToNext:(double)initialTime resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self skipToNext:initialTime resolver:resolve rejecter:reject];
}

- (void)skipToPrevious:(double)initialTime resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self skipToPrevious:initialTime resolver:resolve rejecter:reject];
}

- (void)reset:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self reset:resolve rejecter:reject];
}

- (void)play:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self play:resolve rejecter:reject];
}

- (void)pause:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self pause:resolve rejecter:reject];
}

- (void)stop:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self stop:resolve rejecter:reject];
}

- (void)setPlayWhenReady:(BOOL)playWhenReady resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self setPlayWhenReady:playWhenReady resolver:resolve rejecter:reject];
}

- (void)getPlayWhenReady:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getPlayWhenReady:resolve rejecter:reject];
}

- (void)retry:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self retry:resolve rejecter:reject];
}

- (void)seekTo:(double)time resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self seekTo:time resolver:resolve rejecter:reject];
}

- (void)seekBy:(double)offset resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self seekBy:offset resolver:resolve rejecter:reject];
}

- (void)setRepeatMode:(double)repeatMode resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self setRepeatMode:@(repeatMode) resolver:resolve rejecter:reject];
}

- (void)getRepeatMode:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getRepeatMode:resolve rejecter:reject];
}

- (void)setVolume:(float)volume resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self setVolume:volume resolver:resolve rejecter:reject];
}

- (void)crossFadePrepare:(BOOL)previous seekTo:(double)seekTo resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self crossFadePrepare:previous seekTo:seekTo resolver:resolve rejecter:reject];
}

- (void)crossFade:(double)fadeDuration fadeInterval:(double)fadeInterval fadeToVolume:(double)fadeToVolume waitUntil:(double)waitUntil resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self crossFade:fadeDuration fadeInterval:fadeInterval fadeToVolume:fadeToVolume waitUntil:waitUntil resolver:resolve rejecter:reject];
}

- (void)getVolume:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getVolume:resolve rejecter:reject];
}

- (void)setRate:(float)rate resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self setRate:rate resolver:resolve rejecter:reject];
}

- (void)getRate:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getRate:resolve rejecter:reject];
}

- (void)getTrack:(double)trackIndex resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getTrack:@(trackIndex) resolver:resolve rejecter:reject];
}

- (void)getQueue:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getQueue:resolve rejecter:reject];
}

- (void)setQueue:(NSArray *)objects resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self setQueue:objects ?: @[] resolver:resolve rejecter:reject];
}

- (void)getActiveTrack:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getActiveTrack:resolve rejecter:reject];
}

- (void)getActiveTrackIndex:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getActiveTrackIndex:resolve rejecter:reject];
}

- (void)getDuration:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getDuration:resolve rejecter:reject];
}

- (void)getBufferedPosition:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getBufferedPosition:resolve rejecter:reject];
}

- (void)getPosition:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getPosition:resolve rejecter:reject];
}

- (void)getProgress:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getProgress:resolve rejecter:reject];
}

- (void)getPlaybackState:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self getPlaybackState:resolve rejecter:reject];
}

- (void)updateMetadataForTrack:(double)trackIndex metadata:(NSDictionary *)metadata resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self updateMetadataForTrack:@(trackIndex) metadata:metadata ?: @{} resolver:resolve rejecter:reject];
}

- (void)clearNowPlayingMetadata:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self clearNowPlayingMetadata:resolve rejecter:reject];
}

- (void)updateNowPlayingMetadata:(NSDictionary *)metadata resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self updateNowPlayingMetadata:metadata ?: @{} resolver:resolve rejecter:reject];
}

@end

#endif
