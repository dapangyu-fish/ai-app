// APNs 推送桥
// ─────────────────────────────────────────────────────────
// 仅 iOS 真机有意义（模拟器不会拿到真 deviceToken）。
// 生命周期：
//   1. 用户登录成功 → IMService 调 ApnsService.instance.start()
//   2. 弹系统通知权限弹窗（首次会弹，之后系统记住）
//   3. iOS 注册成功 → AppDelegate 通过 MethodChannel 把 hex 64 字符 deviceToken 推回来
//   4. 我们把 token 上传到后端 /api/im/push_token，与当前业务 user_id 绑定
//   5. 之后对方给我们发消息且我们离线时，OpenIM 调后端 webhook → 后端用这条 token 推 APNs
//
// 不做的事：
//   - 不依赖 OpenIM 的 push module（那个只支持 geTui/fcm/jpush，我们走纯 APNs）
//   - 不持久化 token 到本地（每次启动重新拿一次最稳；APNs token 本来就会变）

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';

class ApnsService {
  ApnsService._();
  static final ApnsService instance = ApnsService._();

  static const _channel = MethodChannel('dapangyu.fish.myapp/push');

  bool _started = false;
  String? _lastUploadedToken;

  /// 平台支持？只有 iOS 真机 / iOS 模拟器才有意义
  /// （模拟器不会真给 deviceToken，但调用本身不会崩）
  static bool get isPlatformSupported {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }

  /// 启动 APNs 流程：弹权限 → 拿 token → 上传后端
  /// 幂等，多次调只走一次
  Future<void> start() async {
    if (_started) return;
    if (!isPlatformSupported) return;
    _started = true;

    // 监听 iOS native 推过来的事件
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDeviceToken':
          final hex = call.arguments as String?;
          if (hex != null && hex.isNotEmpty) {
            await _uploadToken(hex);
          }
          break;
        case 'onRegisterError':
          // ignore: avoid_print
          print('[APNs] register error: ${call.arguments}');
          break;
        case 'onNotificationTap':
          // 用户点了通知——预留：解析 conversationID 跳转
          // 现在还没接路由，留个 TODO
          break;
      }
      return null;
    });

    // 触发权限弹窗 + registerForRemoteNotifications
    try {
      final res = await _channel.invokeMethod<Map>('requestPermissionAndRegister');
      // ignore: avoid_print
      print('[APNs] permission result: $res');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[APNs] permission error: ${e.message}');
    }
  }

  Future<void> _uploadToken(String hexToken) async {
    if (_lastUploadedToken == hexToken) return; // 同一 token 不重复传
    final authToken = AuthService.token;
    if (authToken == null) {
      // ignore: avoid_print
      print('[APNs] 拿到 deviceToken 但用户未登录，跳过上传');
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
          'platform': 'ios',
          'token': hexToken,
        }),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _lastUploadedToken = hexToken;
        // ignore: avoid_print
        print('[APNs] device token 已上传后端');
      } else {
        // ignore: avoid_print
        print('[APNs] 上传失败 ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[APNs] 上传异常: $e');
    }
  }
}
