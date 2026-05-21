# Flutter / OpenIM SDK / Firebase 的 keep 规则
# release 模式下 R8/proguard 默认会裁掉"看似没引用"的类，但 OpenIM SDK
# 内部用 gomobile 生成的 JNI 绑定 + 反射，被裁掉就会卡死或 ClassNotFound
# 现象：debug 完全正常，release 下 OpenIM.initSDK() 永不返回（_loginInFlight 死锁）

# ── OpenIM SDK (flutter_openim_sdk) ──
# gomobile 绑定 + 反射全部要保
-keep class open_im_sdk.** { *; }
-keep class open_im_sdk_callback.** { *; }
-keep class io.openim.** { *; }
-keep class io.openim_sdk.** { *; }
-keep class io.flutter_openim_sdk.** { *; }
-dontwarn open_im_sdk.**
-dontwarn io.openim.**

# ── Firebase / FCM ──
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**

# ── Flutter 框架自身（一般 Flutter 默认 rules 已含，加一层兜底）──
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# ── Flutter Play Core deferred components ──
# Flutter embedding 静态引用了 com.google.android.play.core.*（动态特性模块用），
# 但我们没用 deferred components，也没引这个库 → R8 报 "missing class" 编译失败。
# 既然根本不会真的调到这些类，让 R8 闭嘴，dangling 引用没人会去链接
-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# ── 通用：native 方法 + 反射 ──
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepattributes Signature,InnerClasses,EnclosingMethod
-keepattributes RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations
