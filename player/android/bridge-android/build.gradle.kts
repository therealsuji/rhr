import java.io.File

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
}

// Embeddable core of the rhr player: the native session service (relay dial,
// tunnel, VM-service discovery, presence), published as an AAR for the
// tier-2 "wrapped app" flow (see notes/PHASE2_CUSTOM_APP_WRAP.md). Deliberately
// Flutter-free: a wrapped app provides its own engine; this only owns the
// tunnel that lives outside it.
//
// Kotlin sources stay in the dev.rhr.rhr_player package so the player app and
// host apps reference identical class names; only the Gradle namespace (R
// class) differs.

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
    // Native WebRTC data channel for the opt-in direct payload path. The
    // relay remains the signaling and fallback transport.
    implementation("io.github.webrtc-sdk:android:144.7559.12")
}

android {
    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "dev.rhr"
                artifactId = "bridge-android"
                version = "0.1.0"
            }
        }
        repositories {
            maven {
                // Consumed by the rhr CLI's wrap/init-script injection
                // (rhr wrap adds this repo + a debugImplementation dependency).
                name = "rhr"
                url = uri(File(System.getProperty("user.home"), ".rhr/m2"))
            }
        }
    }
}
