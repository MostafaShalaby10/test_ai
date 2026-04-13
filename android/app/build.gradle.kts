plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.test_ai"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.test_ai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

configurations.all {
    exclude(group = "com.google.ar.sceneform", module = "sceneform-base")
    exclude(group = "com.google.ar.sceneform", module = "core")
    exclude(group = "com.google.ar.sceneform", module = "rendering")
    exclude(group = "com.google.ar.sceneform", module = "ux")
    exclude(group = "com.google.ar.sceneform", module = "animation")
    exclude(group = "com.google.ar.sceneform.ux", module = "sceneform-ux")
}
dependencies {
    implementation("com.google.android.filament:filament-android:1.34.0")
        implementation("androidx.browser:browser:1.8.0")

}