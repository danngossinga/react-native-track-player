#include "RNTrackPlayerSpec.h"

namespace facebook::react {

#define TRACK_PLAYER_OBJECT_METHOD(methodName, signature) \
static facebook::jsi::Value __hostFunction_NativeTrackPlayerModuleSpecJSI_##methodName( \
    facebook::jsi::Runtime& rt, TurboModule &turboModule, const facebook::jsi::Value* args, size_t count) { \
  static jmethodID cachedMethodId = nullptr; \
  return static_cast<JavaTurboModule &>(turboModule).invokeJavaMethod( \
      rt, ObjectKind, #methodName, signature, args, count, cachedMethodId); \
}

#define TRACK_PLAYER_VOID_METHOD(methodName, signature) \
static facebook::jsi::Value __hostFunction_NativeTrackPlayerModuleSpecJSI_##methodName( \
    facebook::jsi::Runtime& rt, TurboModule &turboModule, const facebook::jsi::Value* args, size_t count) { \
  static jmethodID cachedMethodId = nullptr; \
  return static_cast<JavaTurboModule &>(turboModule).invokeJavaMethod( \
      rt, VoidKind, #methodName, signature, args, count, cachedMethodId); \
}

#define TRACK_PLAYER_PROMISE_METHOD(methodName, signature) \
static facebook::jsi::Value __hostFunction_NativeTrackPlayerModuleSpecJSI_##methodName( \
    facebook::jsi::Runtime& rt, TurboModule &turboModule, const facebook::jsi::Value* args, size_t count) { \
  static jmethodID cachedMethodId = nullptr; \
  return static_cast<JavaTurboModule &>(turboModule).invokeJavaMethod( \
      rt, PromiseKind, #methodName, signature, args, count, cachedMethodId); \
}

TRACK_PLAYER_OBJECT_METHOD(getConstants, "()Ljava/util/Map;")
TRACK_PLAYER_VOID_METHOD(addListener, "(Ljava/lang/String;)V")
TRACK_PLAYER_VOID_METHOD(removeListeners, "(D)V")
TRACK_PLAYER_PROMISE_METHOD(setupPlayer, "(Lcom/facebook/react/bridge/ReadableMap;Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(isServiceRunning, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getPlayerLifecycle, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(updateOptions, "(Lcom/facebook/react/bridge/ReadableMap;Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(add, "(Lcom/facebook/react/bridge/ReadableArray;Ljava/lang/Double;Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(load, "(Lcom/facebook/react/bridge/ReadableMap;Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(move, "(DDLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(remove, "(Lcom/facebook/react/bridge/ReadableArray;Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(removeUpcomingTracks, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(skip, "(DDLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(skipToNext, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(skipToPrevious, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(reset, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(play, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(pause, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(stop, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(setPlayWhenReady, "(ZLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getPlayWhenReady, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(retry, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(seekTo, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(seekBy, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(setRepeatMode, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getRepeatMode, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(setVolume, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(crossFadePrepare, "(ZDLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(crossFade, "(DDDDLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getVolume, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(setRate, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getRate, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getTrack, "(DLcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getQueue, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(setQueue, "(Lcom/facebook/react/bridge/ReadableArray;Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getActiveTrack, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getActiveTrackIndex, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getDuration, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getBufferedPosition, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getPosition, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getProgress, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(getPlaybackState, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(updateMetadataForTrack, "(DLcom/facebook/react/bridge/ReadableMap;Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(clearNowPlayingMetadata, "(Lcom/facebook/react/bridge/Promise;)V")
TRACK_PLAYER_PROMISE_METHOD(updateNowPlayingMetadata, "(Lcom/facebook/react/bridge/ReadableMap;Lcom/facebook/react/bridge/Promise;)V")

NativeTrackPlayerModuleSpecJSI::NativeTrackPlayerModuleSpecJSI(
    const JavaTurboModule::InitParams &params)
    : JavaTurboModule(params) {
  methodMap_["getConstants"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getConstants};
  methodMap_["addListener"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_addListener};
  methodMap_["removeListeners"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_removeListeners};
  methodMap_["setupPlayer"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_setupPlayer};
  methodMap_["isServiceRunning"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_isServiceRunning};
  methodMap_["getPlayerLifecycle"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getPlayerLifecycle};
  methodMap_["updateOptions"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_updateOptions};
  methodMap_["add"] = MethodMetadata {2, __hostFunction_NativeTrackPlayerModuleSpecJSI_add};
  methodMap_["load"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_load};
  methodMap_["move"] = MethodMetadata {2, __hostFunction_NativeTrackPlayerModuleSpecJSI_move};
  methodMap_["remove"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_remove};
  methodMap_["removeUpcomingTracks"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_removeUpcomingTracks};
  methodMap_["skip"] = MethodMetadata {2, __hostFunction_NativeTrackPlayerModuleSpecJSI_skip};
  methodMap_["skipToNext"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_skipToNext};
  methodMap_["skipToPrevious"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_skipToPrevious};
  methodMap_["reset"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_reset};
  methodMap_["play"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_play};
  methodMap_["pause"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_pause};
  methodMap_["stop"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_stop};
  methodMap_["setPlayWhenReady"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_setPlayWhenReady};
  methodMap_["getPlayWhenReady"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getPlayWhenReady};
  methodMap_["retry"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_retry};
  methodMap_["seekTo"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_seekTo};
  methodMap_["seekBy"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_seekBy};
  methodMap_["setRepeatMode"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_setRepeatMode};
  methodMap_["getRepeatMode"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getRepeatMode};
  methodMap_["setVolume"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_setVolume};
  methodMap_["crossFadePrepare"] = MethodMetadata {2, __hostFunction_NativeTrackPlayerModuleSpecJSI_crossFadePrepare};
  methodMap_["crossFade"] = MethodMetadata {4, __hostFunction_NativeTrackPlayerModuleSpecJSI_crossFade};
  methodMap_["getVolume"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getVolume};
  methodMap_["setRate"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_setRate};
  methodMap_["getRate"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getRate};
  methodMap_["getTrack"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_getTrack};
  methodMap_["getQueue"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getQueue};
  methodMap_["setQueue"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_setQueue};
  methodMap_["getActiveTrack"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getActiveTrack};
  methodMap_["getActiveTrackIndex"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getActiveTrackIndex};
  methodMap_["getDuration"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getDuration};
  methodMap_["getBufferedPosition"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getBufferedPosition};
  methodMap_["getPosition"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getPosition};
  methodMap_["getProgress"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getProgress};
  methodMap_["getPlaybackState"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_getPlaybackState};
  methodMap_["updateMetadataForTrack"] = MethodMetadata {2, __hostFunction_NativeTrackPlayerModuleSpecJSI_updateMetadataForTrack};
  methodMap_["clearNowPlayingMetadata"] = MethodMetadata {0, __hostFunction_NativeTrackPlayerModuleSpecJSI_clearNowPlayingMetadata};
  methodMap_["updateNowPlayingMetadata"] = MethodMetadata {1, __hostFunction_NativeTrackPlayerModuleSpecJSI_updateNowPlayingMetadata};
}

std::shared_ptr<TurboModule> RNTrackPlayerSpec_ModuleProvider(
    const std::string &moduleName,
    const JavaTurboModule::InitParams &params) {
  if (moduleName == "TrackPlayerModule") {
    return std::make_shared<NativeTrackPlayerModuleSpecJSI>(params);
  }
  return nullptr;
}

#undef TRACK_PLAYER_OBJECT_METHOD
#undef TRACK_PLAYER_VOID_METHOD
#undef TRACK_PLAYER_PROMISE_METHOD

} // namespace facebook::react
