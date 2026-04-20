import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 后端鉴权服务 — 所有请求通过 Flask 后端代理到 Supabase
class AuthService {
  static const String _baseUrl = 'https://app-backend.dapangyu.work';
  static const String _tokenKey = 'auth_access_token';
  static const String _refreshKey = 'auth_refresh_token';
  static const String _userKey = 'auth_user';

  static String? _accessToken;
  static String? _refreshToken;
  static Map<String, dynamic>? _user;

  // 通知监听者
  static final ValueNotifier<bool> authNotifier = ValueNotifier(false);

  static bool get isLoggedIn => _accessToken != null;
  static Map<String, dynamic>? get currentUser => _user;
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
      } catch (_) {
        // 刷新失败 → 清除登录态
        await _clearLocal();
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

    // 如果已自动确认，保存 token
    if (data['access_token'] != null) {
      _accessToken = data['access_token'];
      _refreshToken = data['refresh_token'];
      _user = data['user'];
      await _saveLocal();
    }

    return data;
  }

  /// 登录
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

    _accessToken = data['access_token'];
    _refreshToken = data['refresh_token'];
    _user = data['user'];
    await _saveLocal();
  }

  /// 验证邮箱 OTP
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

    // 验证成功，保存 token
    if (data['access_token'] != null) {
      _accessToken = data['access_token'];
      _refreshToken = data['refresh_token'];
      _user = data['user'];
      await _saveLocal();
    }
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

    final resp = await http.post(
      Uri.parse('$_baseUrl/api/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'refresh_token': _refreshToken}),
    ).timeout(const Duration(seconds: 10));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '刷新失败');
    }

    _accessToken = data['access_token'];
    _refreshToken = data['refresh_token'];
    _user = data['user'];
    await _saveLocal();
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

  /// 获取最新用户信息
  static Future<Map<String, dynamic>> fetchUser() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/api/auth/user'),
      headers: {'Authorization': 'Bearer $_accessToken'},
    ).timeout(const Duration(seconds: 10));

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

    final resp = await http.put(
      Uri.parse('$_baseUrl/api/auth/user'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
      body: json.encode(body),
    ).timeout(const Duration(seconds: 10));

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
    final resp = await http.post(
      Uri.parse('$_baseUrl/api/auth/avatar'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
      body: json.encode({'avatar_base64': base64Data}),
    ).timeout(const Duration(seconds: 15));

    final data = json.decode(resp.body);
    if (resp.statusCode >= 400) {
      throw Exception(data['error'] ?? '头像上传失败');
    }

    _user?['avatar_url'] = data['avatar_url'];
    await _saveLocal();
    return data['avatar_url'];
  }
}
