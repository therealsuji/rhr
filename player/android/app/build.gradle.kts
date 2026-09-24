import groovy.json.JsonSlurper
import groovy.json.JsonOutput
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties().apply {
    rootProject.file("local.properties").inputStream().use(::load)
}
val flutterSdk = localProperties.getProperty("flutter.sdk")
    ?: error("flutter.sdk is missing from android/local.properties")
val flutterVersionFile = file("$flutterSdk/bin/cache/flutter.version.json")
if (!flutterVersionFile.exists()) {
    error("Flutter version metadata is missing: $flutterVersionFile")
}
@Suppress("UNCHECKED_CAST")
val flutterIdentity = JsonSlurper().parse(flutterVersionFile) as Map<String, Any>
fun flutterIdentityField(name: String): String =
    flutterIdentity[name]?.toString()
        ?: error("$name is missing from $flutterVersionFile")

// The release channel is optional metadata (custom SDK builds may omit it);
// an empty value keeps the dev-side compatibility gate conservative.
fun flutterIdentityFieldOrNull(name: String): String? =
    flutterIdentity[name]?.toString()
fun quotedBuildConfig(value: String): String =
    "\"${value.replace("\\", "\\\\").replace("\"", "\\\"")}\""

val flutterPluginMetadataFile = rootProject.file("../.flutter-plugins-dependencies")
if (!flutterPluginMetadataFile.exists()) {
    error("Run flutter pub get before building; missing $flutterPluginMetadataFile")
}
@Suppress("UNCHECKED_CAST")
val flutterPluginMetadata =
    JsonSlurper().parse(flutterPluginMetadataFile) as Map<String, Any>
@Suppress("UNCHECKED_CAST")
val platformPlugins = flutterPluginMetadata["plugins"] as Map<String, Any>
@Suppress("UNCHECKED_CAST")
val androidPlugins = platformPlugins["android"] as List<Map<String, Any>>
val androidPluginProfile = androidPlugins.associate { plugin ->
    val name = plugin["name"]?.toString()
        ?: error("Android plugin is missing its name")
    val path = plugin["path"]?.toString()
        ?: error("Android plugin $name is missing its path")
    val pubspec = file("${path.removeSuffix("/")}/pubspec.yaml")
    val version = Regex("""(?m)^version:\s*([^\s#]+)""")
        .find(pubspec.readText())?.groupValues?.get(1)
        ?: error("Android plugin $name has no version in $pubspec")
    name to version
}.toSortedMap()

// Which ABIs this player ships. It is streamed to a real device over a
// session, so anything it cannot load is pure transfer cost. Override for an
// emulator build with -Prhr.abis=arm64-v8a,x86_64.
val keptAbis: List<String> = (project.findProperty("rhr.abis") as String?)
    ?.split(",")
    ?.map(String::trim)
    ?.filter(String::isNotEmpty)
    ?: listOf("arm64-v8a")

android {
    namespace = "dev.rhr.rhr_player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications (and friends) need java.time etc. on
        // old Android; desugar those APIs instead of raising minSdk.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "dev.rhr.rhr_player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField(
            "String",
            "RHR_FLUTTER_VERSION",
            quotedBuildConfig(flutterIdentityField("frameworkVersion")),
        )
        buildConfigField(
            "String",
            "RHR_FRAMEWORK_REVISION",
            quotedBuildConfig(flutterIdentityField("frameworkRevision")),
        )
        buildConfigField(
            "String",
            "RHR_ENGINE_REVISION",
            quotedBuildConfig(flutterIdentityField("engineRevision")),
        )
        buildConfigField(
            "String",
            "RHR_DART_SDK_VERSION",
            quotedBuildConfig(flutterIdentityField("dartSdkVersion")),
        )
        buildConfigField(
            "String",
            "RHR_FLUTTER_CHANNEL",
            quotedBuildConfig(flutterIdentityFieldOrNull("channel") ?: ""),
        )
        buildConfigField(
            "String",
            "RHR_ANDROID_PLUGINS_JSON",
            quotedBuildConfig(JsonOutput.toJson(androidPluginProfile)),
        )
        // Mirror the identity into resources for the bridge-android library:
        // RhrConfig reads these by name, so the library carries no identity of
        // its own and each host bakes what describes it.
        resValue("string", "rhr_flutter_version", flutterIdentityField("frameworkVersion"))
        resValue("string", "rhr_framework_revision", flutterIdentityField("frameworkRevision"))
        resValue("string", "rhr_engine_revision", flutterIdentityField("engineRevision"))
        resValue("string", "rhr_dart_sdk_version", flutterIdentityField("dartSdkVersion"))
        resValue("string", "rhr_channel", flutterIdentityFieldOrNull("channel") ?: "")
        resValue("string", "rhr_android_plugins_json", JsonOutput.toJson(androidPluginProfile))
        resValue("string", "rhr_host", "player")
    }

    val releaseKey = System.getenv("RHR_PLAYER_KEYSTORE")
    if (releaseKey != null) {
        signingConfigs.create("publishedPlayer") {
            storeFile = file(releaseKey)
            storePassword = System.getenv("RHR_PLAYER_KEY_PASSWORD")
                ?: error("RHR_PLAYER_KEY_PASSWORD is required with RHR_PLAYER_KEYSTORE")
            keyAlias = "rhr-player"
            keyPassword = storePassword
        }
    }

    buildTypes {
        debug {
            if (releaseKey != null) {
                signingConfig = signingConfigs.getByName("publishedPlayer")
            }
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        resources {
            // BouncyCastle ships this OSGi manifest in each of its jars
            // (bcpkix/bcutil/bcprov), and jspecify adds a fourth. They are
            // build metadata with no runtime meaning, so drop them rather
            // than fail the merge. Pulled in via adb-android's pairing code.
            excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        }
        jniLibs {
            // The debug engine bundles the Vulkan validation layer for
            // Impeller work. It is a graphics-debugging tool nothing here
            // loads, and it is 15 MB of every player we stream to a phone.
            excludes += "**/libVkLayer_khronos_validation.so"
            // Drop the ABIs this build can never load. abiFilters does not
            // cover these: the .so files arrive prebuilt inside plugin AARs
            // and are merged in whole, so they survive the filter and only a
            // packaging exclude removes them. x86_64 is 24 MB and
            // armeabi-v7a 11 MB of pure wire time on a phone update.
            for (abi in keptAbis.let { kept ->
                listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64") - kept.toSet()
            }) {
                excludes += "lib/$abi/**"
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Embeddable tunnel core (RhrSessionService + RhrDirectTransport live in
    // the library now; the app provides the update handler and UI).
    implementation(project(":bridge-android"))
    // Connector mode: pair with this phone's own Wireless Debugging, find an
    // installed debug app's VM service, and tunnel it.
    implementation(project(":adb-android"))
    // Core library desugaring (see compileOptions above)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // JVM tests for the pure-Kotlin shake gesture (sensors cannot be faked on
    // a physical device).
    testImplementation("junit:junit:4.13.2")
}

// --target-platform picks the Dart AOT target, but plugins still contribute
// native libs for every ABI they ship, so a phone build carried x86_64
// (24 MB) and armeabi-v7a (11 MB) it can never load. The player is streamed
// to a device over a session, where every megabyte is wire time.
//
// This runs in afterEvaluate because the Flutter Gradle plugin assigns
// abiFilters itself during evaluation; a value set in defaultConfig is
// overwritten before the build sees it. Pass -Prhr.abis=... for an emulator
// build (e.g. "arm64-v8a,x86_64").
afterEvaluate {
    android.defaultConfig.ndk.abiFilters.clear()
    android.defaultConfig.ndk.abiFilters.addAll(keptAbis)
}
