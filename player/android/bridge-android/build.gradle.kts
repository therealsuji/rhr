import java.io.File

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
}

// Embeddable core of the rhr player: the native session service (relay dial,
// tunnel, VM-service discovery, presence), published as an AAR so the
// standalone connector can consume it. Deliberately Flutter-free: the host
// provides its own engine; this only owns the tunnel that lives outside it.
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
    // Native WebRTC data channel for direct tunnel payloads. The relay carries
    // signaling and control messages only unless relay-only mode is explicit.
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
                // Consumed by the connector's Gradle build, which resolves
                // dev.rhr:bridge-android from this local repo.
                name = "rhr"
                url = uri(File(System.getProperty("user.home"), ".rhr/m2"))
            }
        }
    }
}
