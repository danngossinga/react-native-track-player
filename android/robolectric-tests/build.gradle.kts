// JVM tests that run the crossfade engine's real ExoPlayer (Robolectric) against a local HTTP
// server: the renditions it asks for and how long a stalled load takes to give up. A separate
// build (Gradle 8.7, AGP 8), so the library's own build and the example app need no new
// dependency. It compiles the engine's sources from ../src/main/java with small stubs for the
// React Native and KotlinAudio types they name (stubs/).
//
//   cd android/robolectric-tests && JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew testDebugUnitTest
plugins {
    id("com.android.library") version "8.6.1"
    kotlin("android") version "1.9.24"
}

/** The library sources under test: the crossfade engine and what it uses. */
val engineSources = listOf(
    "com/doublesymmetry/trackplayer/service/AndroidCrossfadeEngine.kt",
    "com/doublesymmetry/trackplayer/service/CurrentTimeoutHttpDataSource.kt",
    "com/doublesymmetry/trackplayer/service/PerTrackBandwidthMeter.kt",
    "com/doublesymmetry/trackplayer/service/PlaybackBackendRuntime.kt",
    "com/doublesymmetry/trackplayer/service/StallWatch.kt",
    "com/doublesymmetry/trackplayer/model/TrackAudioItem.kt",
    "com/doublesymmetry/trackplayer/utils/RejectionException.kt"
)

val librarySources = tasks.register<Sync>("librarySources") {
    from("${rootProject.projectDir}/../src/main/java") { include(engineSources) }
    into(layout.buildDirectory.dir("library-src"))
}

android {
    namespace = "com.doublesymmetry.trackplayer.robolectrictests"
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
    // The library resolves kotlinx-coroutines 1.6.4 (KotlinAudio, React Native). Here, declaring
    // 1.6.4 resolves to 1.7.1 (another dependency asks for its BOM), and 1.7.1 is not in this
    // machine's offline Gradle 8 cache (1.6.4 is), so these tests run on 1.9.0, which is. The
    // library's own JVM tests (on 1.6.4) cover the ticket waits (select/onTimeout).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14")
    testImplementation("androidx.test:core:1.6.1")
}
