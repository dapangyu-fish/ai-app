import 'package:flutter/foundation.dart';

/// FCM 推送集成 (Android 优先)
///
/// 使用步骤:
/// 1. 在 Firebase Console 创建项目并下载 google-services.json
/// 2. 将 google-services.json 放到 android/app/
/// 3. 在 android/build.gradle.kts 添加 google-services 插件
/// 4. 在 pubspec.yaml 添加 firebase_core + firebase_messaging
/// 5. App 启动后调用 IMPushService.instance.init()
///
/// 当前为结构占位, 待 firebase_messaging 依赖添加后激活
class IMPushService {
  static final IMPushService _instance = IMPushService._();
  static IMPushService get instance => _instance;
  IMPushService._();

  bool _initialized = false;

  /// 初始化 FCM 推送
  /// 需要在 Firebase.initializeApp() 之后调用
  Future<void> init() async {
    if (_initialized) return;

    try {
      // 注: 以下代码需要 firebase_messaging 依赖
      // 当前作为结构预留, 取消注释即可激活
      //
      // final messaging = FirebaseMessaging.instance;
      //
      // // 请求通知权限 (Android 13+ 需要)
      // final settings = await messaging.requestPermission(
      //   alert: true,
      //   badge: true,
      //   sound: true,
      // );
      // debugPrint('[FCM] 权限状态: ${settings.authorizationStatus}');
      //
      // // 获取 FCM token
      // final fcmToken = await messaging.getToken();
      // if (fcmToken != null) {
      //   debugPrint('[FCM] Token: ${fcmToken.substring(0, 20)}...');
      //   await IMService.instance.registerFCMToken(fcmToken);
      // }
      //
      // // 监听 token 刷新
      // messaging.onTokenRefresh.listen((newToken) {
      //   debugPrint('[FCM] Token 刷新');
      //   IMService.instance.registerFCMToken(newToken);
      // });
      //
      // // 前台消息处理
      // FirebaseMessaging.onMessage.listen((message) {
      //   debugPrint('[FCM] 前台消息: ${message.notification?.title}');
      //   // OpenIM SDK 会自动处理消息, 此处只需处理通知展示
      //   _showLocalNotification(message);
      // });
      //
      // // 后台/退出时点击通知
      // FirebaseMessaging.onMessageOpenedApp.listen((message) {
      //   debugPrint('[FCM] 点击通知打开: ${message.data}');
      //   _handleNotificationTap(message);
      // });

      _initialized = true;
      debugPrint('[FCM] 推送服务初始化完成 (占位模式)');
    } catch (e) {
      debugPrint('[FCM] 初始化失败: $e');
    }
  }

  // void _showLocalNotification(RemoteMessage message) {
  //   // 使用 flutter_local_notifications 展示本地通知
  //   // OpenIM 消息由 SDK 处理, 这里只做通知栏提示
  // }

  // void _handleNotificationTap(RemoteMessage message) {
  //   // 解析 data 中的 conversationID, 跳转到对应聊天页
  // }
}
