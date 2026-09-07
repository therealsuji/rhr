plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.rhr.rhr_connector"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.rhr.rhr_connector"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// RhrConfig (bridge-android) reads these; a wrapped app bakes the same
// keys at build time.
android {
    buildFeatures {
        resValues = true
    }
    defaultConfig {
        resValue("string", "rhr_host", "connector")
    }
}

// The connector binds a UserService into the Shizuku server via AIDL.
android {
    buildFeatures {
        aidl = true
    }
}

repositories {
    // The published bridge-android AAR (built from the rhr checkout:
    // cd <rhr>/player/android && ./gradlew :bridge-android:publish).
    maven { url = uri("file://${System.getProperty("user.home")}/.rhr/m2") }
}

dependencies {
    // Embedded ADB client + pairing (vendored from Shizuku, Apache-2.0):
    // pairs with this phone's own Wireless Debugging and streams shell
    // commands — no Shizuku manager app needed. Now a shared library so the
    // player's connector mode and this app run identical code; it exports
    // BouncyCastle and Conscrypt transitively (see that module's api deps).
    implementation("dev.rhr:adb-android:0.1.0")
    // The player's native tunnel layer as a library: RhrSessionService
    // dials the relay, tunnels the target app's VM door, survives
    // backgrounding (foreground service).
    implementation("dev.rhr:bridge-android:0.1.0")
}
