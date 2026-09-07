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
        // RhrConfig reads these (resource-based, so wrapped apps can bake the
        // same keys at build time with zero code).
        resValue("string", "rhr_flutter_version", flutterIdentityField("frameworkVersion"))
        resValue("string", "rhr_framework_revision", flutterIdentityField("frameworkRevision"))
        resValue("string", "rhr_engine_revision", flutterIdentityField("engineRevision"))
        resValue("string", "rhr_dart_sdk_version", flutterIdentityField("dartSdkVersion"))
        resValue("string", "rhr_channel", flutterIdentityFieldOrNull("channel") ?: "")
        resValue("string", "rhr_android_plugins_json", JsonOutput.toJson(androidPluginProfile))
        resValue("string", "rhr_host", "player")
        // No rhr_relay_url / rhr_session_code: the player's lobby drives
        // sessions, so RhrBridgeInit auto-start no-ops here.
    }

    buildTypes {
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
    // installed debug app's VM service, and tunnel it. Shared with the
    // standalone connector so the ADB logic has one implementation.
    implementation(project(":adb-android"))
    // Spring physics for the dev overlay animations
    implementation("androidx.dynamicanimation:dynamicanimation:1.0.0")
    // Core library desugaring (see compileOptions above)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
