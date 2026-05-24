#pragma once

#include <ReactCommon/JavaTurboModule.h>
#include <ReactCommon/TurboModule.h>
#include <jsi/jsi.h>

namespace facebook::react {

class JSI_EXPORT NativeTrackPlayerModuleSpecJSI : public JavaTurboModule {
public:
  NativeTrackPlayerModuleSpecJSI(const JavaTurboModule::InitParams &params);
};

JSI_EXPORT
std::shared_ptr<TurboModule> RNTrackPlayerSpec_ModuleProvider(
    const std::string &moduleName,
    const JavaTurboModule::InitParams &params);

} // namespace facebook::react
