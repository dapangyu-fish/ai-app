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
          // 新协议：{token: hex, env: 'development' | 'production'}
          // env 由 native 从 embedded.mobileprovision 的 aps-environment 读取，
          // 不能用 kReleaseMode 替代 —— TF 也是 release mode 但 env=production
          final args = call.arguments;
          String? hex;
          String? env;
          if (args is Map) {
            hex = args['token']?.toString();
            env = args['env']?.toString();
          }
          if (hex != null && hex.isNotEmpty) {
            // env 缺失兜底为 production（兜不到对的话客户端重启时 native 还会再注册一次）
            await _uploadToken(hex, apsEnv: env ?? 'production');
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

  // 后端协议：{channel, token, meta} —— 通用结构，未来加 fcm/getui 用同一接口
  Future<void> _uploadToken(String hexToken, {required String apsEnv}) async {
    // 后端 meta.env 只认 'sandbox' / 'production'，把 iOS 的 'development' 名规约一下
    final metaEnv = (apsEnv == 'development') ? 'sandbox' : 'production';
    final dedupeKey = '$hexToken|$metaEnv';
    if (_lastUploadedToken == dedupeKey) return; // 同 token+env 不重复传
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
          'channel': 'apns',
          'token': hexToken,
          'meta': {'env': metaEnv},
        }),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _lastUploadedToken = dedupeKey;
        // ignore: avoid_print
        print('[APNs] device token 已上传 (env=$metaEnv)');
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
