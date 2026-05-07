import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// 客户端公共配置（紧急熔断 / 闪屏 / 公告等）。
///
/// 拉取目标：[AppConfig.configCenterUrl]/api/v1/public —— 一个独立部署的轻量服务，
/// 物理上和主后端不同机器；主后端挂了它仍可用，所以可以靠它下发"系统繁忙"提示。
///
/// 关键不变量：
/// - **fail-open**：任何拉取失败 / 超时 / 解析异常都退化到默认值或上次缓存，
///   绝不能因为配置中心挂了把用户卡住。
/// - **冷启动 1s 超时**：超时则用 SharedPreferences 里的上一次缓存；连缓存都
///   没有就用 hard-coded 默认值（[_defaults]）。
/// - **resume 自动 refetch**：但带 If-None-Match，命中 304 走极轻量路径。
class RemoteConfigService extends ChangeNotifier {
  RemoteConfigService._();

  static final RemoteConfigService instance = RemoteConfigService._();

  static const String _payloadKey = 'remote_config_payload';
  static const String _etagKey = 'remote_config_etag';
  static const Duration _bootstrapTimeout = Duration(seconds: 1);
  static const Duration _refreshTimeout = Duration(seconds: 3);

  /// 兜底默认值。即便配置中心从来没拉到过、prefs 里也没缓存，这套值也能让 app
  /// 正常工作。所有 pause_* 必须默认 false（fail-open）。
  static const Map<String, dynamic> _defaults = {
    'pause_login': false,
    'pause_register': false,
    'pause_request': false,
    'splash_text': 'Welcome',
    'splash_duration_ms': 1500,
  };

  Map<String, dynamic> _values = Map<String, dynamic>.from(_defaults);
  String? _etag;
  // 防止 resume / 手动 refresh 同时触发的重复请求
  Future<void>? _inFlight;

  // ── Getter（命中点） ─────────────────────────────────
  // 这些 getter 不会 throw，永远返回某个默认/缓存值。

  bool get pauseLogin => _bool('pause_login');
  bool get pauseRegister => _bool('pause_register');
  bool get pauseRequest => _bool('pause_request');

  String get splashText {
    final v = _values['splash_text'];
    if (v is String) return v;
    return _defaults['splash_text'] as String;
  }

  /// 闪屏的最小展示时长。客户端实际展示时长 = max(app 启动耗时, 这个值)。
  Duration get splashDuration {
    final v = _values['splash_duration_ms'];
    if (v is int && v >= 0) return Duration(milliseconds: v);
    if (v is double && v >= 0) return Duration(milliseconds: v.toInt());
    return Duration(milliseconds: _defaults['splash_duration_ms'] as int);
  }

  /// 任意 key 的 raw 读取（给以后扩展用）。
  dynamic raw(String key) => _values[key];

  bool _bool(String key) {
    final v = _values[key];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.toLowerCase() == 'true';
    return _defaults[key] as bool;
  }

  // ── 启动加载 ─────────────────────────────────

  /// app 启动早期调一次。
  /// 1. 先尝试从 prefs 加载上次缓存（同步，秒回，让 splash 立刻拿到值）
  /// 2. 异步发 HTTP，[_bootstrapTimeout] 内拿不到就放弃，用第 1 步的缓存
  /// 3. 后台请求即便超时也继续跑，结果到了再 notifyListeners 让 splash 期间
  ///    的 UI（如 splash_text）实时更新
  Future<void> bootstrap() async {
    // step 1：同步加载缓存到内存
    await _loadCache();

    // step 2：发起拉取，但只等 _bootstrapTimeout
    // 用 Completer 拼一个"先返回，后台继续"的语义
    final fetched = _fetchAndApply();
    try {
      await fetched.timeout(_bootstrapTimeout);
    } on TimeoutException {
      debugPrint('[RemoteConfig] bootstrap 超时 (${_bootstrapTimeout.inMilliseconds}ms)，先用缓存/默认值');
      // 后台继续跑；fetchedAndApply 完成会自己 notifyListeners
    } catch (e) {
      debugPrint('[RemoteConfig] bootstrap 失败 (忽略): $e');
    }
  }

  /// app 切回前台时调。带 ETag 走 304 极轻量。
  Future<void> refreshIfStale() async {
    try {
      await _fetchAndApply().timeout(_refreshTimeout);
    } on TimeoutException {
      debugPrint('[RemoteConfig] refresh 超时（忽略）');
    } catch (e) {
      debugPrint('[RemoteConfig] refresh 失败（忽略）: $e');
    }
  }

  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_payloadKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (decoded is Map<String, dynamic>) {
          _values = {..._defaults, ...decoded};
        }
      }
      _etag = prefs.getString(_etagKey);
    } catch (e) {
      debugPrint('[RemoteConfig] 加载缓存失败 (忽略): $e');
    }
  }

  Future<void> _fetchAndApply() async {
    // 复用进行中的请求，避免 bootstrap 后台 + resume 同时打两次
    if (_inFlight != null) return _inFlight!;
    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      final url = '${AppConfig.configCenterUrl}/api/v1/public';
      final headers = <String, String>{};
      if (_etag != null && _etag!.isNotEmpty) {
        headers['If-None-Match'] = _etag!;
      }
      final resp = await http.get(Uri.parse(url), headers: headers);
      if (resp.statusCode == 304) {
        // 服务端没变化；缓存已经是新鲜的
        debugPrint('[RemoteConfig] 304 not modified');
        return;
      }
      if (resp.statusCode != 200) {
        debugPrint('[RemoteConfig] 拉取返回 ${resp.statusCode}: ${resp.body}');
        return;
      }
      final body = utf8.decode(resp.bodyBytes);
      final decoded = json.decode(body);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('[RemoteConfig] payload 不是 object: $body');
        return;
      }
      final newEtag = resp.headers['etag'];
      final changed = !_mapsEqual(decoded, _values) || newEtag != _etag;
      // _defaults 在前 → 用户没下发的 key 仍有默认值兜底
      _values = {..._defaults, ...decoded};
      _etag = newEtag;
      // 持久化最新值
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_payloadKey, body);
        if (newEtag != null) {
          await prefs.setString(_etagKey, newEtag);
        }
      } catch (e) {
        debugPrint('[RemoteConfig] 缓存持久化失败 (忽略): $e');
      }
      if (changed) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[RemoteConfig] _fetchAndApply 异常 (忽略): $e');
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  bool _mapsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
