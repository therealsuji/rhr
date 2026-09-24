plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// The rhr player's tunnel core: the native session service (relay dial,
// tunnel, VM-service discovery, presence). Deliberately Flutter-free — it
// owns the tunnel that lives outside the engine, so a hot restart cannot
// kill it.
//
// A separate module rather than app sources because the service must not
// depend on the Flutter layer it outlives.

android {
    namespace = "dev.rhr.bridge"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Native tunnel bridge (RhrSessionService)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Native WebRTC data channel for direct tunnel payloads. The relay carries
    // signaling and control messages only unless relay-only mode is explicit.
    implementation("io.github.webrtc-sdk:android:144.7559.12")
}


