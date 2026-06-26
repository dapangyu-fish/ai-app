// GeTui / 个推推送桥（Android only；iOS 保持 APNs）
// ─────────────────────────────────────────────────────────
// 真实 AppID/AppKey/AppSecret 不写仓库：
//   Android: GETUI_APP_ID 通过 Gradle local.properties / 环境变量写入 manifest 占位符；
//            Dart 侧同样用 --dart-define=GETUI_APP_ID=... 控制是否启动。
// MasterSecret 只能在服务端环境变量中使用，绝不能进入客户端。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';

class GetuiService {
  GetuiService._();
  static final GetuiService instance = GetuiService._();

  static const bool _enabled = bool.fromEnvironment(
    'GETUI_ENABLED',
    defaultValue: false,
  );
  static const String _appId = String.fromEnvironment('GETUI_APP_ID');
  static const MethodChannel _channel = MethodChannel(
    'dapangyu.fish.myapp/getui',
  );

  bool _started = false;
  bool _handlerInstalled = false;
  String? _lastUploadedCid;

  static bool get isPlatformSupported {
    if (kIsWeb) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  static bool get isConfigured {
    if (!_enabled || !isPlatformSupported || _appId.isEmpty) return false;
    return true;
  }

  Future<void> start() async {
    if (_started) return;
    if (!isConfigured) return;
    _started = true;

    _installEventHandler();

    try {
      await _channel.invokeMethod('init');
      await _channel.invokeMethod('turnOnPush');
    } catch (e) {
      // ignore: avoid_print
      print('[GeTui] SDK start error: $e');
    }

    // 某些机型回调稍晚，启动后主动轮询几次，拿到 CID 即上传。
    for (final delay in const [
      Duration(milliseconds: 800),
      Duration(seconds: 2),
      Duration(seconds: 5),
    ]) {
      Future.delayed(delay, _tryUploadCurrentCid);
    }
  }

  Future<void> unregister() async {
    if (!isPlatformSupported) return;
    final cached = _lastUploadedCid;
    final authToken = AuthService.token;
    if (cached != null && authToken != null) {
      try {
        await http
            .delete(
              Uri.parse('${AppConfig.backendUrl}/api/im/push_token'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $authToken',
              },
              body: json.encode({'channel': 'getui', 'token': cached}),
            )
            .timeout(const Duration(seconds: 5));
        // ignore: avoid_print
        print('[GeTui] CID 已从后端注销');
      } catch (e) {
        // ignore: avoid_print
        print('[GeTui] 注销 CID 失败 (忽略): $e');
      }
    }

    try {
      await _channel.invokeMethod('turnOffPush');
    } catch (_) {}
    _started = false;
    _lastUploadedCid = null;
  }

  void _installEventHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onReceiveClientId':
          final cid = (call.arguments ?? '').toString();
          // ignore: avoid_print
          print('[GeTui] receive CID ...${_tail(cid)}');
          await _uploadCid(cid);
          break;
        case 'onReceiveOnlineState':
          // ignore: avoid_print
          print('[GeTui] online state: ${call.arguments}');
          break;
        case 'onReceivePayload':
        case 'onNotificationMessageClicked':
        case 'onNotificationMessageArrived':
          // ignore: avoid_print
          print('[GeTui] ${call.method}: ${call.arguments}');
          break;
      }
    });
  }

  Future<void> _tryUploadCurrentCid() async {
    if (!_started || !isConfigured) return;
    try {
      final cid = await _channel.invokeMethod<String>('getClientId');
      await _uploadCid(cid ?? '');
    } catch (e) {
      // ignore: avoid_print
      print('[GeTui] getClientId error (忽略): $e');
    }
  }

  Future<void> _uploadCid(String cid) async {
    final value = cid.trim();
    if (value.isEmpty || _lastUploadedCid == value) return;
    final authToken = AuthService.token;
    if (authToken == null) {
      // ignore: avoid_print
      print('[GeTui] 拿到 CID 但用户未登录，跳过上传');
      return;
    }
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/im/push_token'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $authToken',
            },
            body: json.encode({
              'channel': 'getui',
              'token': value,
              'meta': {
                'app_id': _appId,
                'platform': defaultTargetPlatform.name,
              },
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _lastUploadedCid = value;
        // ignore: avoid_print
        print('[GeTui] CID 已上传 ...${_tail(value)}');
      } else {
        // ignore: avoid_print
        print('[GeTui] CID 上传失败 ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[GeTui] CID 上传异常: $e');
    }
  }

  String _tail(String value) {
    if (value.length <= 8) return value;
    return value.substring(value.length - 8);
  }
}
