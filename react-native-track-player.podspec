require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name = package["name"]
  s.version = package["version"]
  s.summary = package["description"]
  s.license = package["license"]

  s.author = "David Chavez"
  s.homepage = package["repository"]["url"]
  s.platform = :ios, "11.0"

  s.source = { :git => package["repository"]["url"], :tag => "v#{s.version}" }
  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.pod_target_xcconfig = {
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) RCT_NEW_ARCH_ENABLED=1"
  } if ENV["RCT_NEW_ARCH_ENABLED"] == "1"

  s.swift_version = "4.2"

  s.dependency "React-Core"
  if ENV["RCT_NEW_ARCH_ENABLED"] == "1"
    s.dependency "ReactCodegen"
    s.dependency "React-NativeModulesApple"
    s.dependency "ReactCommon/turbomodule/core"
  end
  s.dependency "SwiftAudioEx", "1.1.0"
end
