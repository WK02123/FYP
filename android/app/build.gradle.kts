plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.gms.google-services")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "inti.edu.shuttle_bus_app"

    compileSdk = 36
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "inti.edu.shuttle_bus_app"
        minSdk = 23
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:32.3.1"))
    implementation("com.google.firebase:firebase-auth")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.multidex:multidex:2.0.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Copy APK to Flutter's expected location after evaluation
afterEvaluate {
    tasks.register<Copy>("copyFlutterApk") {
        from(layout.buildDirectory.dir("outputs/apk/debug"))
        into(layout.projectDirectory.dir("../../build/app/outputs/flutter-apk"))
        include("*.apk")
    }

    tasks.named("assembleDebug").configure {
        finalizedBy("copyFlutterApk")
    }
}