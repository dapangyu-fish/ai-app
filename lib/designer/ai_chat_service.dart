import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/auth_service.dart';
import '../config/app_config.dart';

/// AI 对话事件
class ChatEvent {
  final String? content;      // 增量文本
  final String? thinking;     // 思考过程
  final Map<String, dynamic>? jsonApp;  // 检测到的 JSON-APP
  final Map<String, dynamic>? quota;    // 配额信息
  final String? error;
  final bool isGeneratingJson; // 正在生成 JSON
  final String? requestAction; // 比如 "upload_current_app"
  final String? failedJsonUrl; // 下载失败的 JSON URL
  final String? statusMessage; // 动态状态文案（思考中/阅读文件/写入代码/上传...）
  final String? pendingJsonUrl; // 待用户确认下载的 JSON URL（不自动下载）

  ChatEvent({this.content, this.thinking, this.jsonApp, this.quota, this.error, this.isGeneratingJson = false, this.requestAction, this.failedJsonUrl, this.statusMessage, this.pendingJsonUrl});
}

/// AI 供应商信息
class AiProvider {
  final String id;
  final String name;
  final String description;
  final String defaultModel;

  AiProvider({
    required this.id,
    required this.name,
    required this.description,
    required this.defaultModel,
  });

  factory AiProvider.fromJson(Map<String, dynamic> json) {
    return AiProvider(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      defaultModel: json['default_model'] as String? ?? '',
    );
  }
}

/// 管理对话历史并与后端 AI 服务通信（SSE 流式，支持中断）
class AiChatService {
  // 使用统一配置管理的后端地址
  static String get _baseUrl => AppConfig.backendUrl;
  static const String _providerKey = 'ai_provider';
  static const String _sessionKey = 'ai_session_id';
  static const String _sessionUsedKey = 'ai_session_used';

  static String _selectedProvider = 'deepseek';
  static List<AiProvider> _providers = [];

  static String get selectedProvider => _selectedProvider;
  static List<AiProvider> get providers => _providers;

  static Future<void> loadProvider() async {
    final prefs = await SharedPreferences.getInstance();
    _selectedProvider = prefs.getString(_providerKey) ?? 'deepseek';
  }

  static Future<void> setProvider(String providerId) async {
    _selectedProvider = providerId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerKey, providerId);
  }

  static Future<List<AiProvider>> fetchProviders() async {
    try {
      final resp = await http
          .get(Uri.parse('$_baseUrl/api/ai/providers'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        _providers = (data['providers'] as List<dynamic>)
            .map((e) => AiProvider.fromJson(e as Map<String, dynamic>))
            .toList();
        return _providers;
      }
    } catch (_) {}
    return _providers;
  }

  // ── Session 管理 ──
  String _sessionId = '';
  bool _sessionUsed = false;  // 该 session 是否已发过消息（用于判断 is_new_session）

  http.Client? _activeClient;
  bool _aborting = false;

  String get sessionId => _sessionId;

  /// 初始化/加载 session（app 启动时调用）
  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    String? cachedId = prefs.getString(_sessionKey);
    // 验证缓存的 UUID 长度是否合法 (36字符)
    if (cachedId == null || cachedId.length != 36) {
      _sessionId = _generateSessionId();
      _sessionUsed = false;
    } else {
      _sessionId = cachedId;
      _sessionUsed = prefs.getBool(_sessionUsedKey) ?? false;
    }
    await prefs.setString(_sessionKey, _sessionId);
    await prefs.setBool(_sessionUsedKey, _sessionUsed);
  }

  /// 重置 session（用户点击清除按钮）
  Future<void> resetSession() async {
    abort();
    _sessionId = _generateSessionId();
    _sessionUsed = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionKey, _sessionId);
    await prefs.setBool(_sessionUsedKey, false);
  }

  String _generateSessionId() {
    final random = Random();
    final hexDigits = '0123456789abcdef';
    
    String generateHex(int length) {
      return List.generate(length, (_) => hexDigits[random.nextInt(16)]).join('');
    }
    
    // UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx (y = 8, 9, a, b)
    final y = hexDigits[random.nextInt(4) + 8];
    return '${generateHex(8)}-${generateHex(4)}-4${generateHex(3)}-$y${generateHex(3)}-${generateHex(12)}';
  }

  void abort() {
    _aborting = true;
    _activeClient?.close();
    _activeClient = null;
  }

  /// 检查后端对应 session 的 CLI 进程是否仍然存活
  Future<bool> isSessionAlive() async {
    if (_sessionId.isEmpty) return false;
    try {
      final token = AuthService.token;
      final headers = <String, String>{};
      if (token != null) headers['Authorization'] = 'Bearer $token';
      final resp = await http
          .get(
            Uri.parse('$_baseUrl/api/ai/session_status?session_id=$_sessionId'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return false;
      final data = json.decode(resp.body) as Map<String, dynamic>;
      return data['alive'] == true;
    } catch (e) {
      debugPrint('[AI_CHAT] isSessionAlive error: $e');
      return false;
    }
  }

  /// 发送用户消息，返回 Stream<ChatEvent>
  /// 只发送最新消息 + session_id，CLI session 自动维护对话历史
  /// 支持自动重连：网络中断时自动重试
  Stream<ChatEvent> sendStream(String userMessage) async* {
    abort();
    _aborting = false;

    final isNew = !_sessionUsed;

    debugPrint('[AI_CHAT] ========== 发送消息 ==========');
    debugPrint('[AI_CHAT] 消息内容: $userMessage');
    debugPrint('[AI_CHAT] Session ID: $_sessionId');
    debugPrint('[AI_CHAT] Provider: $_selectedProvider');
    debugPrint('[AI_CHAT] Is New Session: $isNew');
    debugPrint('[AI_CHAT] ====================================');

    // 自动重连参数
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 2);
    int retryCount = 0;

    while (retryCount <= maxRetries) {
      if (retryCount > 0) {
        debugPrint('[AI_CHAT] 第 $retryCount 次重连尝试...');
        yield ChatEvent(statusMessage: '连接中断，正在重连... ($retryCount/$maxRetries)');
        await Future.delayed(retryDelay);
      }

      final client = http.Client();
      _activeClient = client;

    try {
      final request = http.Request('POST', Uri.parse('$_baseUrl/chat'));
      request.headers['Content-Type'] = 'application/json';
      final token = AuthService.token;
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      request.body = json.encode({
        'messages': [{'role': 'user', 'content': userMessage}],
        'session_id': _sessionId,
        'is_new_session': isNew,
        'provider': _selectedProvider,
      });

      var response = await client.send(request).timeout(
        const Duration(seconds: 300),
      );

      if (response.statusCode == 401 && AuthService.token != null) {
        try {
          await AuthService.refreshSession();
          final retryRequest = http.Request('POST', Uri.parse('$_baseUrl/chat'));
          retryRequest.headers['Content-Type'] = 'application/json';
          final newToken = AuthService.token;
          if (newToken != null) {
            retryRequest.headers['Authorization'] = 'Bearer $newToken';
          }
          retryRequest.body = json.encode({
            'messages': [{'role': 'user', 'content': userMessage}],
            'session_id': _sessionId,
            'is_new_session': isNew,
            'provider': _selectedProvider,
          });
          response = await client.send(retryRequest).timeout(
            const Duration(seconds: 300),
          );
        } catch (_) {
          // 刷新失败，保持原 401 response，后续逻辑会处理
        }
      }

      if (response.statusCode == 429) {
        final body = await response.stream.bytesToString();
        final data = json.decode(body);
        yield ChatEvent(error: data['error'] ?? '配额已用完', quota: data['quota']);
        return;
      }

      if (response.statusCode == 401) {
        yield ChatEvent(error: '请先登录');
        return;
      }

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        yield ChatEvent(error: '服务器错误 (${response.statusCode}): $body');
        return;
      }

      // 标记 session 已使用
      if (!_sessionUsed) {
        _sessionUsed = true;
        SharedPreferences.getInstance().then((prefs) {
          prefs.setBool(_sessionUsedKey, true);
        });
      }

      String accumulated = '';
      String accumulatedThinking = ''; // 累积思考过程
      int contentEventCount = 0;  // 内容事件计数
      int thinkingEventCount = 0;  // 思考事件计数

      // 用 LineSplitter 保证跨 TCP chunk 的行完整性
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();

        // 只记录非内容事件的 SSE 行
        if (trimmed.isNotEmpty && !trimmed.contains('"content"') && !trimmed.contains('"thinking"')) {
          debugPrint('[AI_CHAT] <<< SSE: ${trimmed.length > 200 ? trimmed.substring(0, 200) + "..." : trimmed}');
        }

        if (trimmed.isEmpty) continue;
        if (trimmed == 'data: [DONE]') {
          debugPrint('[AI_CHAT] <<< SSE 流结束');
          debugPrint('[AI_CHAT] 总计: 内容事件 $contentEventCount 次, 思考事件 $thinkingEventCount 次');
          if (accumulated.isNotEmpty) {
            debugPrint('[AI_CHAT] === 完整回复内容 ===');
            debugPrint('[AI_CHAT] $accumulated');
            debugPrint('[AI_CHAT] === 回复结束 (${accumulated.length} 字符) ===');
          }
          if (accumulatedThinking.isNotEmpty) {
            debugPrint('[AI_CHAT] === 完整思考过程 ===');
            debugPrint('[AI_CHAT] $accumulatedThinking');
            debugPrint('[AI_CHAT] === 思考结束 (${accumulatedThinking.length} 字符) ===');
          }
          continue;
        }
        if (!trimmed.startsWith('data: ')) continue;

          final dataStr = trimmed.substring(6);
          try {
            final data = json.decode(dataStr) as Map<String, dynamic>;

            // 只记录非内容/思考事件的解析结果
            if (!data.containsKey('content') && !data.containsKey('thinking') &&
                !data.containsKey('final_content') && !data.containsKey('final_thinking')) {
              debugPrint('[AI_CHAT] >>> 解析事件: ${data.keys.join(", ")}');
            }

            if (data.containsKey('generating_json') && data['generating_json'] == true) {
              yield ChatEvent(isGeneratingJson: true);
              continue;
            }
            // 生成结束（失败时后端会发 generating_json: false）
            if (data.containsKey('generating_json') && data['generating_json'] == false) {
              continue;
            }

            // 动作请求 (比如上传当前 app)
            if (data.containsKey('request_action')) {
              yield ChatEvent(requestAction: data['request_action'] as String);
              continue;
            }

            // 动态状态更新（思考中/阅读文件/写入代码/上传等）
            if (data.containsKey('status')) {
              final msg = data['message'] as String? ?? '';
              yield ChatEvent(statusMessage: msg);
              continue;
            }

            // 最终完整内容（用于替换之前的增量累积，修正误差）
            // 仅在确定下发了完整结果时才覆盖：长度不应小于已累积的内容
            if (data.containsKey('final_content')) {
              final finalText = data['final_content'] as String? ?? '';
              if (finalText.isNotEmpty) {
                debugPrint('[AI_CHAT] 收到最终完整内容，长度: ${finalText.length}');
                if (finalText.length >= accumulated.length) {
                  accumulated = finalText;
                  yield ChatEvent(content: accumulated);
                } else {
                  debugPrint('[AI_CHAT] final_content 比当前累积还短，已忽略以避免字幕回退');
                }
              }
              continue;
            }

            // assistant_content：resume 流里整块下发的文本，作为追加，不覆盖
            if (data.containsKey('assistant_content')) {
              final chunk = data['assistant_content'] as String? ?? '';
              if (chunk.isNotEmpty) {
                debugPrint('[AI_CHAT] 收到 assistant 文本块，长度: ${chunk.length}');
                if (!accumulated.contains(chunk)) {
                  accumulated += chunk;
                }
                yield ChatEvent(content: accumulated);
              }
              continue;
            }

            // 最终完整思考（用于替换之前的增量累积）
            if (data.containsKey('final_thinking')) {
              final finalThinking = data['final_thinking'] as String? ?? '';
              if (finalThinking.isNotEmpty) {
                debugPrint('[AI_CHAT] 收到最终完整思考，长度: ${finalThinking.length}');
                if (finalThinking.length >= accumulatedThinking.length) {
                  accumulatedThinking = finalThinking;
                  yield ChatEvent(thinking: accumulatedThinking);
                }
              }
              continue;
            }

            // assistant_thinking：resume 流里的整块思考
            if (data.containsKey('assistant_thinking')) {
              final chunk = data['assistant_thinking'] as String? ?? '';
              if (chunk.isNotEmpty) {
                if (!accumulatedThinking.contains(chunk)) {
                  accumulatedThinking += chunk;
                }
                yield ChatEvent(thinking: accumulatedThinking);
              }
              continue;
            }

          // JSON-APP 检测
          if (data.containsKey('has_json') && data['has_json'] == true) {
            Map<String, dynamic>? parsedApp;
            if (data.containsKey('json_url') && data['json_url'] != null) {
              final url = data['json_url'] as String;
              try {
                final getResp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
                if (getResp.statusCode == 200) {
                  final jsonBody = utf8.decode(getResp.bodyBytes);
                  parsedApp = json.decode(jsonBody) as Map<String, dynamic>;
                } else {
                  yield ChatEvent(failedJsonUrl: url, error: '下载生成的 JSON 失败 (HTTP ${getResp.statusCode})');
                }
              } catch (e) {
                yield ChatEvent(failedJsonUrl: url, error: '下载 JSON 异常: $e');
              }
            } else {
              parsedApp = data['json_app'] as Map<String, dynamic>?;
            }
            
            if (parsedApp != null) {
              yield ChatEvent(jsonApp: parsedApp);
            }
            continue;
          }

          // 配额信息
          if (data.containsKey('quota')) {
            yield ChatEvent(
              quota: data['quota'] as Map<String, dynamic>?,
            );
            continue;
          }

          // 错误
          if (data.containsKey('error')) {
            yield ChatEvent(error: data['error'] as String);
            continue;
          }

          // 思考过程（增量累积）
          if (data.containsKey('thinking')) {
            final thinking = data['thinking'] as String? ?? '';
            if (thinking.isNotEmpty) {
              accumulatedThinking += thinking;
              yield ChatEvent(thinking: accumulatedThinking);
            }
            continue;
          }

          // 普通文本
          final content = data['content'] as String? ?? '';
          if (content.isNotEmpty) {
            accumulated += content;
            yield ChatEvent(content: accumulated);
          }
        } catch (_) {}
      }

      // 流结束后，统一解析标签指令（避免流式传输过程中重复解析）

      // 1. 检测 [json_app_url] 标记 → 不自动下载，仅通知 UI 显示按钮
      // AI 偶尔会把 URL 包成 markdown 链接 [json_app_url](URL)[/json_app_url]，
      // 容错处理：从匹到的内容里抽出真正的 http(s) URL。
      final urlRegex = RegExp(r'\[json_app_url\]([^\[]+?)\[/json_app_url\]');
      final urlMatch = urlRegex.firstMatch(accumulated);
      if (urlMatch != null) {
        final raw = urlMatch.group(1)!.trim();
        final httpMatch = RegExp(r'https?://[^\s\)\]\(\<\>"]+').firstMatch(raw);
        final url = httpMatch?.group(0) ?? raw;
        debugPrint('[AI_CHAT] 流结束，检测到 JSON URL，等待用户确认下载: $url');
        yield ChatEvent(pendingJsonUrl: url);
      }

      // 2. 检测 [request_action] 标记
      final actionRegex = RegExp(r'\[request_action\]([^\]]+)\[/request_action\]');
      final actionMatch = actionRegex.firstMatch(accumulated);
      if (actionMatch != null) {
        final action = actionMatch.group(1)!;
        debugPrint('[AI_CHAT] 流结束，检测到请求动作: $action');
        yield ChatEvent(requestAction: action);
      }

      // 3. 如果累积的文本包含 JSON 块，则提取并应用
      final jsonBlockRegex = RegExp(r'```json\s*(\{.*?\})\s*```', dotAll: true);
      final match = jsonBlockRegex.firstMatch(accumulated);
      if (match != null && urlMatch == null) {  // 有 URL 时不再重复处理
        try {
          final jsonStr = match.group(1)!;
          final parsedApp = json.decode(jsonStr) as Map<String, dynamic>;
          yield ChatEvent(jsonApp: parsedApp);
        } catch (e) {
          // JSON 解析失败则忽略
        }
      }

      // 流正常结束，跳出重连循环
      debugPrint('[AI_CHAT] 流正常结束');
      return;

    } on http.ClientException catch (e) {
      debugPrint('[AI_CHAT] ClientException: $e');
      if (_aborting) {
        // 只有显式 abort() 才认为是用户主动中止
        debugPrint('[AI_CHAT] 用户主动中止，不重连');
        return;
      }
      retryCount++;
      if (retryCount > maxRetries) {
        yield ChatEvent(error: '连接失败，已达到最大重试次数: $e');
        return;
      }
      yield ChatEvent(statusMessage: '网络波动，正在自动重试... ($retryCount/$maxRetries)');
      // 继续重连循环
    } catch (e) {
      debugPrint('[AI_CHAT] 未知错误: $e');
      retryCount++;
      if (retryCount > maxRetries) {
        yield ChatEvent(error: '网络错误: $e');
        return;
      }
      // 继续重连循环
    } finally {
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
    }  // while 循环结束
  }

  void commitPartial(String partialContent) {
    // Session 模式下不需要手动管理消息历史，CLI session 自动维护
  }

  /// 上传当前运行的 JSON-APP，返回包含链接的文本。
  /// 通过预签名 URL 上传到 MinIO；失败时按指数退避重试 3 次，
  /// 全部失败则向上抛出异常（由调用方决定如何提示用户重试）。
  Future<String> uploadCurrentApp(Map<String, dynamic> jsonConfig) async {
    final jsonStr = json.encode(jsonConfig);
    debugPrint('[AI_CHAT] ========== 上传当前应用配置 ==========');
    debugPrint('[AI_CHAT] JSON 大小: ${jsonStr.length} bytes');

    const maxAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        // 指数退避：1s, 2s（attempt=2 → 1s, attempt=3 → 2s）
        final delay = Duration(seconds: 1 << (attempt - 2));
        debugPrint(
            '[AI_CHAT] 第 $attempt/$maxAttempts 次重试，等待 ${delay.inSeconds}s...');
        await Future.delayed(delay);
      }
      try {
        final result = await _uploadCurrentAppOnce(jsonStr);
        debugPrint(
            '[AI_CHAT] ✅ 上传成功（第 $attempt 次尝试）');
        debugPrint('[AI_CHAT] ==========================================');
        return result;
      } catch (e) {
        lastError = e;
        debugPrint('[AI_CHAT] ❌ 第 $attempt/$maxAttempts 次尝试失败: $e');
      }
    }

    debugPrint(
        '[AI_CHAT] ❌ 已重试 $maxAttempts 次仍失败，向上抛出（不再 fallback 到内联 JSON）');
    debugPrint('[AI_CHAT] ==========================================');
    throw Exception('上传失败（已重试 $maxAttempts 次）：$lastError');
  }

  /// 单次上传尝试（不带重试）。任何失败抛出 Exception 由 uploadCurrentApp 处理重试。
  Future<String> _uploadCurrentAppOnce(String jsonStr) async {
    final token = AuthService.token;

    // 1. 获取预签名上传 / 下载 URL
    debugPrint('[AI_CHAT] 请求预签名 URL: $_baseUrl/api/ai/upload_url');
    final urlResp = await http
        .get(
          Uri.parse('$_baseUrl/api/ai/upload_url'),
          headers: token != null ? {'Authorization': 'Bearer $token'} : null,
        )
        .timeout(const Duration(seconds: 30));

    debugPrint('[AI_CHAT] 预签名 URL 响应: ${urlResp.statusCode}');
    if (urlResp.statusCode != 200) {
      throw Exception(
          'upload_url API failed: HTTP ${urlResp.statusCode} body=${urlResp.body}');
    }

    final urlData = json.decode(urlResp.body) as Map<String, dynamic>;
    final putUrl = urlData['put_url'] as String?;
    final getUrl = urlData['get_url'] as String?;
    if (putUrl == null || getUrl == null) {
      throw Exception('upload_url API 返回缺少 put_url/get_url 字段');
    }

    // 2. PUT 上传 JSON 到 MinIO
    debugPrint('[AI_CHAT] 开始上传到 MinIO...');
    final uploadResp = await http
        .put(
          Uri.parse(putUrl),
          headers: {'Content-Type': 'application/json'},
          body: utf8.encode(jsonStr),
        )
        .timeout(const Duration(seconds: 15));

    debugPrint('[AI_CHAT] MinIO 上传响应: ${uploadResp.statusCode}');
    if (uploadResp.statusCode != 200) {
      throw Exception(
          'MinIO PUT failed: HTTP ${uploadResp.statusCode} body=${uploadResp.body}');
    }

    return '以下是我当前正在运行的 JSON-APP 完整配置（已上传至临时存储），'
        '后续对话请基于这个配置进行修改或分析：\n\n'
        '[json_app_url]$getUrl[/json_app_url]';
  }

  /// 使用 Claude CLI 生成/修改/修复 JSON-APP
  /// [userPrompt] 用户的需求描述
  /// [currentApp] 当前运行的 APP JSON（修改/修复场景）
  /// [crashLog] 崩溃日志（修复场景）
  Stream<ChatEvent> generateApp(String userPrompt, {
    Map<String, dynamic>? currentApp,
    String? crashLog,
  }) async* {
    abort();

    final client = http.Client();
    _activeClient = client;

    try {
      final request = http.Request('POST', Uri.parse('$_baseUrl/api/ai/generate'));
      request.headers['Content-Type'] = 'application/json';
      final token = AuthService.token;
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      request.body = json.encode({
        'prompt': userPrompt,
        if (currentApp != null) 'current_app': currentApp,
        if (crashLog != null) 'crash_log': crashLog,
        'provider': _selectedProvider,
      });

      final response = await client.send(request).timeout(
        const Duration(seconds: 300), // Claude CLI 可能运行较久
      );

      if (response.statusCode == 429) {
        final body = await response.stream.bytesToString();
        final data = json.decode(body);
        yield ChatEvent(error: data['error'] ?? '配额已用完', quota: data['quota']);
        return;
      }

      if (response.statusCode == 401) {
        yield ChatEvent(error: '请先登录');
        return;
      }

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        yield ChatEvent(error: '服务器错误 (${response.statusCode}): $body');
        return;
      }

      String accumulated = '';

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed == 'data: [DONE]') continue;
        if (!trimmed.startsWith('data: ')) continue;

        final dataStr = trimmed.substring(6);
        try {
          final data = json.decode(dataStr) as Map<String, dynamic>;

          // JSON-APP 检测
          if (data.containsKey('has_json') && data['has_json'] == true) {
            Map<String, dynamic>? parsedApp;
            if (data.containsKey('json_url') && data['json_url'] != null) {
              try {
                final url = data['json_url'] as String;
                final getResp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
                if (getResp.statusCode == 200) {
                  final jsonBody = utf8.decode(getResp.bodyBytes);
                  parsedApp = json.decode(jsonBody) as Map<String, dynamic>;
                }
              } catch (e) {
                yield ChatEvent(error: '下载 JSON 异常: $e');
              }
            } else {
              parsedApp = data['json_app'] as Map<String, dynamic>?;
            }
            if (parsedApp != null) {
              yield ChatEvent(jsonApp: parsedApp);
            }
            continue;
          }

          // 配额
          if (data.containsKey('quota')) {
            yield ChatEvent(quota: data['quota'] as Map<String, dynamic>?);
            continue;
          }

          // 错误
          if (data.containsKey('error')) {
            yield ChatEvent(content: accumulated, error: data['error'] as String);
            continue;
          }

          // 普通文本（Claude CLI 的输出）
          final content = data['content'] as String? ?? '';
          if (content.isNotEmpty) {
            accumulated += content;
            yield ChatEvent(content: accumulated);
          }
        } catch (_) {}
      }
    } on http.ClientException {
      // abort()
    } catch (e) {
      yield ChatEvent(error: '网络错误: $e');
    } finally {
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
  }

  /// 重试下载 JSON
  Future<Map<String, dynamic>> retryDownloadJson(String url) async {
    final getResp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
    if (getResp.statusCode == 200) {
      final jsonBody = utf8.decode(getResp.bodyBytes);
      return json.decode(jsonBody) as Map<String, dynamic>;
    } else {
      throw Exception('HTTP ${getResp.statusCode}');
    }
  }

  Future<void> clear() async {
    abort();
    await resetSession();
  }
}
