import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "jp.valaishasu.pecaone"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "jp.valaishasu.pecaone"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        externalNativeBuild { cmake { arguments += listOf("-DCMAKE_BUILD_TYPE=Release"); targets += "peercast_mobile" } }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    externalNativeBuild { cmake { path = file("../../native/mobile/CMakeLists.txt"); version = "3.22.1" } }
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                fun requiredProperty(name: String): String =
                    keystoreProperties.getProperty(name)?.takeIf { it.isNotBlank() }
                        ?: throw GradleException("Missing $name in android/key.properties")
                storeFile = file(requiredProperty("storeFile"))
                storePassword = requiredProperty("storePassword")
                keyAlias = requiredProperty("keyAlias")
                keyPassword = requiredProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            // Distribution builds must use the private release key.
            // Configure android/key.properties before building a release.
            signingConfig = signingConfigs.getByName("release")
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

// Allow debug builds without local signing secrets, but never emit an unsigned release.
gradle.taskGraph.whenReady {
    if (!keystorePropertiesFile.exists() && allTasks.any {
        it.project == project && it.name.contains("Release", ignoreCase = true)
    }) {
        throw GradleException("Release signing requires android/key.properties. See docs/DEVELOPMENT.md.")
    }
}
