plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// RHR Agent: the accessibility service that lets a developer's agent see and
// tap anywhere on the tester's phone, system dialogs included.
//
// A separate APK from the player on purpose. Play Protect blocks any APK that
// declares an accessibility service when it is installed from a browser or a
// file manager, which is how testers get the player. Installed by the player
// itself, it only gets the usual unknown-app prompt (verified on Android 16,
// 2026-09-30). The player and the agent must be signed with the same key: the
// agent only serves callers signed like itself.

android {
    namespace = "dev.rhr.agent"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.rhr.agent"
        minSdk = 30
        targetSdk = 36
        // Set by the release workflow; an update needs a code no lower
        // than the installed one.
        versionCode = (project.findProperty("rhr.agentVersionCode") as String?)?.toInt() ?: 1
        versionName = (project.findProperty("rhr.agentVersion") as String?) ?: "0.0.0-dev"
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
    testImplementation("junit:junit:4.13.2")
    // org.json is an Android framework class; the JVM tests need a real one.
    testImplementation("org.json:json:20240303")
}
