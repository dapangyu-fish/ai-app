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

val localPropertiesFile = rootProject.file("local.properties")
val localProperties = Properties()
if (localPropertiesFile.exists()) {
    localProperties.load(FileInputStream(localPropertiesFile))
}

fun envOrLocal(envName: String, localName: String): String =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: localProperties.getProperty(localName)?.takeIf { it.isNotBlank() }
        ?: ""

fun androidVersionCodeFromName(versionName: String): Int {
    val parts = versionName.substringBefore("-").substringBefore("+").split(".")
    require(parts.size == 3) {
        "Android versionName must use major.minor.patch, got: $versionName"
    }
    val major = parts[0].toInt()
    val minor = parts[1].toInt()
    val patch = parts[2].toInt()
    require(minor in 0..99 && patch in 0..99) {
        "Android versionName minor/patch must be 0..99 for versionCode mapping, got: $versionName"
    }
    return major * 10000 + minor * 100 + patch
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
        // Keep Android build number aligned with versionName:
        // 1.2.0 -> 010200 -> 10200, 1.12.3 -> 011203 -> 11203.
        versionCode = androidVersionCodeFromName(flutter.versionName)
        versionName = flutter.versionName
        manifestPlaceholders.putAll(
            mapOf(
                "GETUI_APPID" to envOrLocal("GETUI_APP_ID", "getui.appId"),
                "GETUI_APP_ID" to envOrLocal("GETUI_APP_ID", "getui.appId"),
                "XIAOMI_APP_ID" to envOrLocal("XIAOMI_APP_ID", "xiaomi.appId"),
                "XIAOMI_APP_KEY" to envOrLocal("XIAOMI_APP_KEY", "xiaomi.appKey"),
                "MEIZU_APP_ID" to envOrLocal("MEIZU_APP_ID", "meizu.appId"),
                "MEIZU_APP_KEY" to envOrLocal("MEIZU_APP_KEY", "meizu.appKey"),
                "HUAWEI_APP_ID" to envOrLocal("HUAWEI_APP_ID", "huawei.appId"),
                "OPPO_APP_KEY" to envOrLocal("OPPO_APP_KEY", "oppo.appKey"),
                "OPPO_APP_SECRET" to envOrLocal("OPPO_APP_SECRET", "oppo.appSecret"),
                "VIVO_APP_ID" to envOrLocal("VIVO_APP_ID", "vivo.appId"),
                "VIVO_APP_KEY" to envOrLocal("VIVO_APP_KEY", "vivo.appKey"),
            )
        )
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

dependencies {
    implementation("com.getui:gtsdk:3.3.12.0")
    implementation("com.getui:gtc:3.2.18.0")
}
