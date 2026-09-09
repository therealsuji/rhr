plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// On-device Wireless Debugging client: pairs with THIS phone's own adbd,
// discovers the rotating connect port over mDNS, and runs shell commands.
// Used by the player's connector mode, which tunnels an app already
// installed on the phone.
//
// Kept OUT of bridge-android on purpose: that module is the tunnel core, and
// a host embedding it needs neither BouncyCastle nor Conscrypt. Only an app
// that drives adbd pays for these.
//
// src/main/jniLibs carries a prebuilt libadb.so: the SPAKE2 handshake used
// during pairing is native, and AdbPairingClient fails to initialise without
// it (UnsatisfiedLinkError surfacing later as NoClassDefFoundError). It ships
// here rather than in the app so it is picked up automatically. arm64-v8a
// only, matching the devices this targets.

android {
    namespace = "dev.rhr.adb"
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
    // X.509 material for the ADB key (vendored client, Apache-2.0).
    api("org.bouncycastle:bcpkix-jdk18on:1.78.1")
    // The SPAKE2 pairing handshake derives its password from the TLS
    // keying-material export, which Android 16's platform Conscrypt dropped.
    api("org.conscrypt:conscrypt-android:2.5.3")
    implementation("androidx.core:core-ktx:1.13.1")
    // AdbMdns reports the discovered port through a lifecycle Observer.
    implementation("androidx.lifecycle:lifecycle-livedata-core:2.8.7")
}


