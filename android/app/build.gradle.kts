plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Secrets are supplied only through the build process environment.
val releaseSigningEnvironment = listOf(
    "WORDNEST_KEYSTORE_PATH",
    "WORDNEST_STORE_PASSWORD",
    "WORDNEST_KEY_ALIAS",
    "WORDNEST_KEY_PASSWORD",
).associateWith { System.getenv(it) }
val hasReleaseSigning = releaseSigningEnvironment.values.all { !it.isNullOrBlank() }
require(releaseSigningEnvironment.values.all { it.isNullOrBlank() } || hasReleaseSigning) {
    "Set all four WORDNEST signing environment variables, or none for debug fallback."
}

android {
    namespace = "io.wordnest.wordnest"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 21 uses Java 8+ library APIs.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        multiDexEnabled = true
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.wordnest.wordnest"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("environmentRelease") {
                storeFile = file(releaseSigningEnvironment.getValue("WORDNEST_KEYSTORE_PATH")!!)
                storePassword = releaseSigningEnvironment.getValue("WORDNEST_STORE_PASSWORD")
                keyAlias = releaseSigningEnvironment.getValue("WORDNEST_KEY_ALIAS")
                keyPassword = releaseSigningEnvironment.getValue("WORDNEST_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Local builds without credentials may use debug; publication must inject all four variables.
            signingConfig = signingConfigs.getByName(
                if (hasReleaseSigning) "environmentRelease" else "debug",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
