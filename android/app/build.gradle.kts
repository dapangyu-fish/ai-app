plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase —— 在编译期读 google-services.json 注入 BuildConfig；
    // 没这个文件 build 会 fail，所以同 contributor 必须自己建 Firebase 项目下一份
    id("com.google.gms.google-services")
}

android {
    namespace = "dapangyu.fish.myapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dapangyu.fish.myapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // 先关 minify 做对照实验 —— 验证 release 下 OpenIM DNS 失败是否
            // 是 R8 引起。如果关了之后 IM 能连上，就肯定是 keep 规则还差几条；
            // 如果关了仍然挂，问题在别处（native lib / 网络栈等）。
            // proguard-rules.pro 留着备用
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
