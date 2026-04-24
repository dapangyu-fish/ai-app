import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/auth_service.dart';

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

  ChatEvent({this.content, this.thinking, this.jsonApp, this.quota, this.error, this.isGeneratingJson = false, this.requestAction, this.failedJsonUrl, this.statusMessage});
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
  static const String _baseUrl = 'https://app-backend.dapangyu.work';
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
    _activeClient?.close();
    _activeClient = null;
  }

  /// 发送用户消息，返回 Stream<ChatEvent>
  /// 只发送最新消息 + session_id，CLI session 自动维护对话历史
  Stream<ChatEvent> sendStream(String userMessage) async* {
    abort();

    final client = http.Client();
    _activeClient = client;

    final isNew = !_sessionUsed;

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

      // 用 LineSplitter 保证跨 TCP chunk 的行完整性
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

          // 思考过程
          if (data.containsKey('thinking')) {
            final thinking = data['thinking'] as String? ?? '';
            if (thinking.isNotEmpty) {
              yield ChatEvent(thinking: thinking);
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

      // 流结束后，如果累积的文本包含 JSON 块，则提取并应用
      final jsonBlockRegex = RegExp(r'```json\s*(\{.*?\})\s*```', dotAll: true);
      final match = jsonBlockRegex.firstMatch(accumulated);
      if (match != null) {
        try {
          final jsonStr = match.group(1)!;
          final parsedApp = json.decode(jsonStr) as Map<String, dynamic>;
          yield ChatEvent(jsonApp: parsedApp);
        } catch (e) {
          // JSON 解析失败则忽略
        }
      }

    } on http.ClientException {
      // abort() 触发
    } catch (e) {
      yield ChatEvent(error: '网络错误: $e');
    } finally {
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
  }

  void commitPartial(String partialContent) {
    // Session 模式下不需要手动管理消息历史，CLI session 自动维护
  }

  /// 上传当前运行的 JSON-APP，返回包含链接的文本。
  /// 优先通过预签名 URL 上传到 MinIO，仅在消息中携带链接；失败时回退到内联 JSON。
  Future<String> uploadCurrentApp(Map<String, dynamic> jsonConfig) async {
    final jsonStr = json.encode(jsonConfig);
    String contextContent;

    try {
      final token = AuthService.token;
      // 1. 获取预签名上传 / 下载 URL
      final urlResp = await http
          .get(
            Uri.parse('$_baseUrl/api/ai/upload_url'),
            headers: token != null ? {'Authorization': 'Bearer $token'} : null,
          )
          .timeout(const Duration(seconds: 10));

      if (urlResp.statusCode == 200) {
        final urlData = json.decode(urlResp.body) as Map<String, dynamic>;
        final putUrl = urlData['put_url'] as String;
        final getUrl = urlData['get_url'] as String;

        // 2. PUT 上传 JSON 到 MinIO
        final uploadResp = await http
            .put(
              Uri.parse(putUrl),
              headers: {'Content-Type': 'application/json'},
              body: utf8.encode(jsonStr),
            )
            .timeout(const Duration(seconds: 15));

        if (uploadResp.statusCode == 200) {
          // 成功 → 只放链接
          contextContent =
              '以下是我当前正在运行的 JSON-APP 完整配置（已上传至临时存储），'
              '后续对话请基于这个配置进行修改或分析：\n\n'
              '[json_app_url]$getUrl[/json_app_url]';
        } else {
          throw Exception('MinIO PUT failed: ${uploadResp.statusCode}');
        }
      } else {
        throw Exception('upload_url API failed: ${urlResp.statusCode}');
      }
    } catch (e) {
      // 回退：直接内联 JSON
      contextContent =
          '以下是我当前正在运行的 JSON-APP 完整配置，'
          '后续对话请基于这个配置进行修改或分析：\n\n```json\n$jsonStr\n```';
    }

    return contextContent;
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
