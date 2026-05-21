import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase —— 在编译期读 google-services.json 注入 BuildConfig；
    // 没这个文件 build 会 fail，所以同 contributor 必须自己建 Firebase 项目下一份
    id("com.google.gms.google-services")
}

// ── Release 签名配置 ─────────────────────────────────────
// 从 android/key.properties 读签名信息（key.properties 已经在 .gitignore，不会进仓库）。
// key.properties 不存在时 release 会 fallback 到 debug key（dev 本地 flutter run --release
// 也能跑），但是这种包**绝对不能上 Play**，Play 后台一看就拒。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasReleaseKey = keystorePropertiesFile.exists() &&
    keystoreProperties.getProperty("storeFile") != null

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

    signingConfigs {
        // release 签名：只有 key.properties 存在时才注册，否则 release block 会 fallback debug
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                // 没 key.properties → 用 debug key 签，方便本地 flutter run --release 调试。
                // ⚠️ 这种包 Play Store 不接受，正式发布前必须配 key.properties
                signingConfigs.getByName("debug")
            }
            // R8 minify 暂时不开 —— 之前发现 OpenIM SDK / Firebase 反射会被裁。
            // proguard-rules.pro 已写好 keep 规则备用，要开就把这俩改 true
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
