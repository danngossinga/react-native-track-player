package com.doublesymmetry.trackplayer

import com.doublesymmetry.trackplayer.module.MusicModule
import com.facebook.react.BaseReactPackage
import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.facebook.react.uimanager.ViewManager

/**
 * TrackPlayer
 * https://github.com/react-native-kit/react-native-track-player
 * @author Milen Pivchev @mpivchev
 */
class TrackPlayer : BaseReactPackage(), ReactPackage {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? {
        return if (name == MODULE_NAME) MusicModule(reactContext) else null
    }

    override fun createNativeModules(reactContext: ReactApplicationContext): List<NativeModule> {
        return listOf(MusicModule(reactContext))
    }

    override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> {
        return emptyList()
    }

    override fun getReactModuleInfoProvider(): ReactModuleInfoProvider {
        return ReactModuleInfoProvider {
            mapOf(
                MODULE_NAME to ReactModuleInfo(
                    MODULE_NAME,
                    MusicModule::class.java.name,
                    false,
                    false,
                    false,
                    true
                )
            )
        }
    }

    companion object {
        private const val MODULE_NAME = "TrackPlayerModule"
    }
}
