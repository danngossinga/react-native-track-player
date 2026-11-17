// JVM tests that run the crossfade engine's real ExoPlayer (Robolectric) against a local HTTP
// server: the renditions it asks for and how long a stalled load takes to give up. A separate
// build (Gradle 8.7, AGP 8), so the library's own build and the example app need no new
// dependency. It compiles the engine's sources from ../src/main/java and the vendored KotlinAudio
// (../src/vendor/kotlinaudio, the standard player, with its resources), with small stubs (stubs/)
// for the React Native types they name and for KotlinAudio's media session, artwork and log
// libraries, which this machine's offline Gradle 8 cache lacks (not under test).
//
//   cd android/robolectric-tests && JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew testDebugUnitTest
plugins {
    id("com.android.library") version "8.6.1"
    kotlin("android") version "1.9.24"
}

/** The library sources under test: the crossfade engine, the standard player's configuration, and what they use. */
val engineSources = listOf(
    "com/doublesymmetry/trackplayer/service/AndroidCrossfadeEngine.kt",
    "com/doublesymmetry/trackplayer/service/AndroidTrackQueue.kt",
    "com/doublesymmetry/trackplayer/service/FailedLoadRule.kt",
    "com/doublesymmetry/trackplayer/service/KotlinAudioPlaybackBackend.kt",
    "com/doublesymmetry/trackplayer/service/PlaybackBackend.kt",
    "com/doublesymmetry/trackplayer/service/CurrentTimeoutHttpDataSource.kt",
    "com/doublesymmetry/trackplayer/service/PerTrackBandwidthMeter.kt",
    "com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt",
    "com/doublesymmetry/trackplayer/service/StallWatch.kt",
    "com/doublesymmetry/trackplayer/service/StartLowTrackSelection.kt",
    "com/doublesymmetry/trackplayer/service/StandardCommandLoad.kt",
    "com/doublesymmetry/trackplayer/service/StandardLoadWatch.kt",
    "com/doublesymmetry/trackplayer/model/TrackAudioItem.kt",
    "com/doublesymmetry/trackplayer/utils/RejectionException.kt"
)

val librarySources = tasks.register<Sync>("librarySources") {
    from("${rootProject.projectDir}/../src/main/java") { include(engineSources) }
    // Vendored KotlinAudio as the library builds it (its standard player: QueuedAudioPlayer).
    from("${rootProject.projectDir}/../src/vendor/kotlinaudio/java")
    into(layout.buildDirectory.dir("library-src"))
}

android {
    // The library's namespace: vendored KotlinAudio names its resources' R there.
    namespace = "com.doublesymmetry.trackplayer"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            java.setSrcDirs(listOf(layout.buildDirectory.dir("library-src").get().asFile, "stubs"))
            res.setSrcDirs(listOf("${rootProject.projectDir}/../src/vendor/kotlinaudio/res"))
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all { it.maxHeapSize = "1g" }
        }
    }

    lint {
        abortOnError = false
    }
}

tasks.named("preBuild") { dependsOn(librarySources) }

dependencies {
    // The versions the library runs with (KotlinAudio v2.1.0 brings ExoPlayer 2.19.0).
    implementation("com.google.android.exoplayer:exoplayer:2.19.0")
    // The library resolves 1.6.4 (KotlinAudio, React Native); 1.6.4 is not in this machine's
    // Gradle 8 cache, so these tests run on 1.9.0. The library's own JVM tests (1.6.4) cover the
    // ticket waits (select/onTimeout) that the orchestrator uses.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14")
    testImplementation("androidx.test:core:1.6.1")
}
