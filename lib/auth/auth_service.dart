import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import 'local_data_wiper.dart';

/// 检测到切换账号时的信息载体（旧账号 → 新账号）。
/// UI 拿到非空对象就意味着 token 还**没有**写入本地，得先弹确认框。
class AccountSwitchInfo {
  final String prevEmail;
  final String newEmail;
  const AccountSwitchInfo({required this.prevEmail, required this.newEmail});
}

/// 后端鉴权服务 — 所有请求通过 Flask 后端代理到 Supabase
class AuthService {
  // 使用统一配置管理的后端地址
  static String get _baseUrl => AppConfig.backendUrl;
  static const String _tokenKey = 'auth_access_token';
  static const String _refreshKey = 'auth_refresh_token';
  static const String _userKey = 'auth_user';
  // 上一次成功登录的 email；切账号检测的依据。
  // 复用历史上 AuthPage 用来"prefill 上次邮箱"的同名 key（值语义一致：上次登录成功的 email）。
  static const String _lastEmailKey = 'auth_last_email';

  static String? _accessToken;
  static String? _refreshToken;
  static Map<String, dynamic>? _user;

  // 检测到切换账号时缓存的 pending 数据。等用户确认/取消后才落地。
  // 不变量：_pendingAuthData != null 时，prefs 里**没有**对应的 token；
  // 反之亦然。任何登录路径成功后都必须先复位这两个字段（要么提交、要么丢弃）。
  static Map<String, dynamic>? _pendingAuthData;
  static String? _pendingEmail;
  static AccountSwitchInfo? _pendingAccountSwitch;

  static String avatarCacheBuster = DateTime.now().millisecondsSinceEpoch.toString();

  // 通知监听者
  static final ValueNotifier<bool> authNotifier = ValueNotifier(false);

  /// 上次成功登录的 email；首次登录返回 null。
  static Future<String?> getLastLoginEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastEmailKey);
  }

  /// 当前是否有"待确认的切账号" pending —— UI 用来决定要不要弹确认框。
  static AccountSwitchInfo? get pendingAccountSwitch => _pendingAccountSwitch;

  static bool get isLoggedIn => _accessToken != null;
  static Map<String, dynamic>? get currentUser {
    if (_user == null) return null;
    final u = Map<String, dynamic>.from(_user!);
    if (u['avatar_url'] is String) {
      String url = u['avatar_url'];
      if (url.contains('127.0.0.1')) {
        // 使用统一配置管理的Supabase地址
        url = url.replaceAll(RegExp(r'http://127\.0\.0\.1:\d+'), AppConfig.supabaseUrl);
      }
      u['avatar_url'] = url;
    }
    return u;
  }
  static String? get token => _accessToken;

  /// 从本地存储恢复登录状态（App 启动时调用）
  static Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_tokenKey);
    _refreshToken = prefs.getString(_refreshKey);
    final userJson = prefs.getString(_userKey);
    if (userJson != null) {
      _user = json.decode(userJson);
    }

    if (_accessToken != null) {
      // 尝试刷新 token 确保有效
      try {
        await refreshSession();
      } catch (e) {
        // refreshSession 内部已经在 token 真无效（HTTP 4xx）时主动 _clearLocal 过了。
        // 走到这里都是网络 / 解析异常：飞行模式 / DNS 挂 / 服务端短暂不可达。
        // 此时 token 大概率还有效——保留本地登录态，让用户能进主界面。
        // 后续真正的 API 调用走 _authRequest，碰到 401 会再触发刷新；只要那时网络
        // 恢复就能正常衔接。如果网络始终不通，业务调用自己会 fail，但用户体感比
        // "断网就被踢回登录页"好得多。
        debugPrint('[Auth] restoreSession 刷新失败但保留登录态（网络/解析错误）: $e');
      }
    }
    authNotifier.value = isLoggedIn;
  }

  /// 持久化 token 到本地
  static Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) {
      await prefs.setString(_tokenKey, _accessToken!);
    }
    if (_refreshToken != null) {
      await prefs.setString(_refreshKey, _refreshToken!);
    }
    if (_user != null) {
      await prefs.setString(_userKey, json.encode(_user));
    }
    authNotifier.value = isLoggedIn;
  }

  static Future<void> _clearLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_refreshKey);
    await prefs.remove(_userKey);
    _accessToken = null;
    _refreshToken = null;
    _user = null;
    authNotifier.value = false;
  }

  /// 注册
  ///
  /// 调用方拿到结果后：
  /// - 如果 `data['needs_confirm'] == true` → 跳到 OTP 页让用户输验证码
  /// - 否则成功登录；此时再检查 [pendingAccountSwitch]，非空就要弹确认框
  static Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    String? username,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'email': email,
        'password': password,
        'username': username ?? email.split('@')[0],
      }),
    ).timeout(const Duration(seconds: 15));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '注册失败');
    }

    // 如果已自动确认（拿到 token），按账号切换规则处理
    if (data['access_token'] != null) {
      await _commitOrStashAuth(data, email);
    }

    return data;
  }

  /// 登录。成功返回后，UI **必须**检查 [pendingAccountSwitch]：
  /// - null：正常登录完成（首次登录 / 同邮箱重登），可以直接进首页
  /// - 非 null：检测到切换账号，token 还没落地，调
  ///   [confirmAccountSwitchAndWipe] 或 [cancelPendingAccountSwitch]
  static Future<void> signIn({
    required String email,
    required String password,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email, 'password': password}),
    ).timeout(const Duration(seconds: 15));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '登录失败');
    }

    await _commitOrStashAuth(data, email);
  }

  /// 验证邮箱 OTP。和 [signIn] 一样，成功返回后 UI 必须检查
  /// [pendingAccountSwitch] 决定是否弹确认框。
  static Future<void> verifyOtp({
    required String email,
    required String token,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/api/auth/verify'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email, 'token': token}),
    ).timeout(const Duration(seconds: 15));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '验证失败');
    }

    // 验证成功，按账号切换规则处理 token
    if (data['access_token'] != null) {
      await _commitOrStashAuth(data, email);
    }
  }

  /// 拿到 server 返回的 access_token 后调这个：
  /// - 如果 email 与 prefs 里"上次登录的 email"不同 → 暂存 pending，**不**写 prefs
  /// - 否则直接落地（_saveLocal + 写 _lastEmailKey）
  ///
  /// 调用前会先把上一次悬挂着的 pending 清掉（避免不同登录路径互相干扰）。
  static Future<void> _commitOrStashAuth(
      Map<String, dynamic> data, String email) async {
    // 复位老 pending（保护：例如先 register 拿到 pending，又走 signIn 成功覆盖）
    _pendingAuthData = null;
    _pendingEmail = null;
    _pendingAccountSwitch = null;

    final prefs = await SharedPreferences.getInstance();
    final prevEmail = prefs.getString(_lastEmailKey);
    final isSwitch = prevEmail != null &&
        prevEmail.isNotEmpty &&
        prevEmail.toLowerCase() != email.toLowerCase();

    if (isSwitch) {
      // 不写 prefs / 不动 _accessToken。等 UI 弹完确认框再决定
      _pendingAuthData = data;
      _pendingEmail = email;
      _pendingAccountSwitch =
          AccountSwitchInfo(prevEmail: prevEmail, newEmail: email);
      return;
    }

    // 同邮箱重登 / 首次登录：直接落地
    _accessToken = data['access_token'];
    _refreshToken = data['refresh_token'];
    _user = data['user'];
    await _saveLocal();
    await prefs.setString(_lastEmailKey, email);
  }

  /// 用户在确认框点了"确认清除并继续"。
  /// 步骤：先清除一切磁盘数据 → 再把 pending token 落地。
  static Future<void> confirmAccountSwitchAndWipe() async {
    final pending = _pendingAuthData;
    final pendingEmail = _pendingEmail;
    if (pending == null || pendingEmail == null) {
      throw StateError('confirmAccountSwitchAndWipe: 没有 pending');
    }

    // 1. 清除（包括所有 prefs，所以 _lastEmailKey 也会被清掉，下面再写回）
    await wipeAllLocalAccountData();

    // 2. 把新账号 token 写入（此时 prefs 是空的）
    _accessToken = pending['access_token'];
    _refreshToken = pending['refresh_token'];
    _user = pending['user'];
    await _saveLocal();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastEmailKey, pendingEmail);

    // 3. 复位 pending
    _pendingAuthData = null;
    _pendingEmail = null;
    _pendingAccountSwitch = null;
  }

  /// 用户在确认框点了"取消"。丢弃 pending token，停留在登录页。
  /// 旧账号的 prefs / 数据原样保留。
  static void cancelPendingAccountSwitch() {
    _pendingAuthData = null;
    _pendingEmail = null;
    _pendingAccountSwitch = null;
  }

  /// 重新发送验证邮件
  static Future<void> resendVerification(String email) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/api/auth/resend'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email}),
    ).timeout(const Duration(seconds: 15));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '发送失败');
    }
  }

  /// 刷新 token
  static Future<void> refreshSession() async {
    if (_refreshToken == null) throw Exception('无 refresh token');

    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/api/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'refresh_token': _refreshToken}),
      ).timeout(const Duration(seconds: 10));

      final data = json.decode(resp.body);
      if (resp.statusCode >= 400) {
        // 明确被服务器拒绝（如过期/无效），清理本地状态
        await _clearLocal();
        throw Exception(data['error'] ?? '刷新失败');
      }

      _accessToken = data['access_token'];
      _refreshToken = data['refresh_token'];
      _user = data['user'];
      await _saveLocal();
    } catch (e) {
      // 网络错误等保留本地状态，上抛异常
      rethrow;
    }
  }

  /// 登出
  static Future<void> signOut() async {
    try {
      await http.post(
        Uri.parse('$_baseUrl/api/auth/logout'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_accessToken',
        },
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
    await _clearLocal();
  }

  /// 带自动刷新 Token 的 HTTP 请求包装器
  static Future<http.Response> _authRequest(
    Future<http.Response> Function() requestFunc,
  ) async {
    var response = await requestFunc();
    if (response.statusCode == 401 && _refreshToken != null) {
      try {
        await refreshSession();
        // 刷新成功，重试请求
        response = await requestFunc();
      } catch (_) {
        // 刷新失败，保持原响应，上层会抛出异常
      }
    }
    return response;
  }

  /// 获取最新用户信息
  static Future<Map<String, dynamic>> fetchUser() async {
    final resp = await _authRequest(() => http.get(
      Uri.parse('$_baseUrl/api/auth/user'),
      headers: {'Authorization': 'Bearer $_accessToken'},
    ).timeout(const Duration(seconds: 10)));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '获取用户信息失败');
    }

    _user = data;
    await _saveLocal();
    return data;
  }

  /// 更新用户名/头像
  static Future<Map<String, dynamic>> updateProfile({
    String? username,
    String? avatarUrl,
  }) async {
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;

    final resp = await _authRequest(() => http.put(
      Uri.parse('$_baseUrl/api/auth/user'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
      body: json.encode(body),
    ).timeout(const Duration(seconds: 10)));

    if (resp.statusCode >= 400 && !resp.body.trimLeft().startsWith('{')) {
      throw Exception('服务器错误 (${resp.statusCode})');
    }
    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '更新失败');
    }

    _user = data['user'];
    await _saveLocal();
    return data;
  }

  /// 上传头像 (base64)
  static Future<String> uploadAvatar(String base64Data) async {
    final resp = await _authRequest(() => http.post(
      Uri.parse('$_baseUrl/api/auth/avatar'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
      body: json.encode({'avatar_base64': base64Data}),
    ).timeout(const Duration(seconds: 15)));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '头像上传失败');
    }

    String avatarUrl = data['avatar_url'];
    avatarCacheBuster = DateTime.now().millisecondsSinceEpoch.toString();

    _user?['avatar_url'] = avatarUrl;
    await _saveLocal();
    return avatarUrl;
  }
}
