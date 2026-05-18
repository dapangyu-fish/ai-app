// FCM 推送桥（Android）
// ─────────────────────────────────────────────────────────
// 设计对照 [ApnsService]（iOS）：
//   - 只跑 Android（kIsWeb / iOS 都直接 noop）
//   - 用户登录后调 start()，拿 FCM token，POST 到 /api/im/push_token 跟 user_id 绑定
//   - logout 调 unregister()：DELETE 后端那条 + reset 本地状态
//   - token 会刷新（Firebase 不定时换），用 onTokenRefresh 监听后再上传一次
//
// 跟 APNs 的区别：
//   - APNs token 是 hex 字符串，FCM token 是不透明长字符串，反正照原样发给后端
//   - APNs 走 native MethodChannel 拿；FCM 走 firebase_messaging 插件
//   - FCM 没有 sandbox/production 区分，meta 留空即可
//   - Android 13+ 必须运行时申请 POST_NOTIFICATIONS（plugin 内置 requestPermission()）

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';

class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  bool _started = false;
  String? _lastUploadedToken;

  /// 平台支持？只有 Android 真机有意义。
  /// iOS 走 [ApnsService]；Web / 桌面这版不支持。
  static bool get isPlatformSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// 启动 FCM 流程：申请权限 → 拿 token → 上传 → 监听刷新
  /// 幂等（多次调只走一次注册流程，但 token 上传本身有 dedupe）
  Future<void> start() async {
    if (_started) return;
    if (!isPlatformSupported) return;
    _started = true;

    final messaging = FirebaseMessaging.instance;

    // 1. 请求通知权限（Android 13+ 必须，低版本是 no-op，iOS 也兼容）
    try {
      final settings = await messaging.requestPermission(
        alert: true, badge: true, sound: true,
      );
      // ignore: avoid_print
      print('[FCM] notification permission: ${settings.authorizationStatus}');
    } catch (e) {
      // ignore: avoid_print
      print('[FCM] requestPermission error (忽略): $e');
    }

    // 2. 拿当前 token
    try {
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _uploadToken(token);
      } else {
        // ignore: avoid_print
        print('[FCM] getToken 返回空（可能 google-services.json 没配 / 没 Google Play Services）');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FCM] getToken 异常: $e');
    }

    // 3. token 刷新时再传一次（Firebase 不定时换 token，比如重装/清数据）
    messaging.onTokenRefresh.listen((newToken) {
      _lastUploadedToken = null;  // 重置 dedupe，下次必传
      _uploadToken(newToken);
    });

    // 4. 前台收到推送的回调（仅 log；UI 提示走 OpenIM 现有逻辑，不在此处弹）
    FirebaseMessaging.onMessage.listen((msg) {
      // ignore: avoid_print
      print('[FCM] foreground message: ${msg.messageId}  data=${msg.data}');
    });
  }

  /// logout / 切账号时调：从后端注销当前 device token，重置内部状态
  Future<void> unregister() async {
    if (!isPlatformSupported) return;
    final cached = _lastUploadedToken;
    final authToken = AuthService.token;
    if (cached != null && authToken != null) {
      try {
        await http.delete(
          Uri.parse('${AppConfig.backendUrl}/api/im/push_token'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $authToken',
          },
          body: json.encode({'channel': 'fcm', 'token': cached}),
        ).timeout(const Duration(seconds: 5));
        // ignore: avoid_print
        print('[FCM] device token 已从后端注销');
      } catch (e) {
        // ignore: avoid_print
        print('[FCM] 注销 token 失败 (忽略): $e');
      }
    }
    // 同时让 firebase_messaging 本地清掉（防止重新登录后又拿同 token 没被重新绑）
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      // ignore: avoid_print
      print('[FCM] deleteToken 失败 (忽略): $e');
    }
    _started = false;
    _lastUploadedToken = null;
  }

  // 上传 token —— 协议跟 APNs 完全一致 {channel, token, meta}，后端按 channel 路由
  Future<void> _uploadToken(String token) async {
    if (_lastUploadedToken == token) return;  // dedupe
    final authToken = AuthService.token;
    if (authToken == null) {
      // ignore: avoid_print
      print('[FCM] 拿到 token 但用户未登录，跳过上传');
      return;
    }
    try {
      final resp = await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/im/push_token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
        body: json.encode({
          'channel': 'fcm',
          'token': token,
          'meta': {},  // FCM 没 sandbox/production 区分，留空
        }),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _lastUploadedToken = token;
        // ignore: avoid_print
        print('[FCM] device token 已上传');
      } else {
        // ignore: avoid_print
        print('[FCM] 上传失败 ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[FCM] 上传异常: $e');
    }
  }
}
