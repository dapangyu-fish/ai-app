import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/auth_service.dart';

/// AI 对话事件
class ChatEvent {
  final String? content;      // 增量文本
  final Map<String, dynamic>? jsonApp;  // 检测到的 JSON-APP
  final Map<String, dynamic>? quota;    // 配额信息
  final String? error;
  final bool isGeneratingJson; // 正在生成 JSON

  ChatEvent({this.content, this.jsonApp, this.quota, this.error, this.isGeneratingJson = false});
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

  final List<Map<String, String>> _messages = [];

  http.Client? _activeClient;

  List<Map<String, String>> get messages =>
      _messages.where((m) => m['role'] != 'system').toList();

  void abort() {
    _activeClient?.close();
    _activeClient = null;
  }

  /// 发送用户消息，返回 Stream<ChatEvent>
  Stream<ChatEvent> sendStream(String userMessage) async* {
    abort();
    _messages.add({'role': 'user', 'content': userMessage});

    final client = http.Client();
    _activeClient = client;

    try {
      final request = http.Request('POST', Uri.parse('$_baseUrl/chat'));
      request.headers['Content-Type'] = 'application/json';
      // 带上 auth token
      final token = AuthService.token;
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      request.body = json.encode({
        'messages': _messages,
        'provider': _selectedProvider,
      });

      final response = await client.send(request).timeout(
        const Duration(seconds: 120),
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
        _messages.removeLast();
        yield ChatEvent(error: '服务器错误 (${response.statusCode}): $body');
        return;
      }

      String accumulated = '';

      // 用 LineSplitter 保证跨 TCP chunk 的行完整性
      // （has_json 事件包含完整 JSON-APP，可能几 KB，单行会被拆到多个 chunk）
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
              // 不需要额外处理，后续的 error 事件会重置状态
              continue;
            }

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
                } else {
                  yield ChatEvent(error: '下载生成的 JSON 失败 (HTTP ${getResp.statusCode})');
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

          // 普通文本
          final content = data['content'] as String? ?? '';
          if (content.isNotEmpty) {
            accumulated += content;
            yield ChatEvent(content: accumulated);
          }
        } catch (_) {}
      }

      if (accumulated.isNotEmpty) {
        _messages.add({'role': 'assistant', 'content': accumulated});
      } else {
        _messages.removeLast();
      }
    } on http.ClientException {
      // abort() 触发
    } catch (e) {
      _messages.removeLast();
      yield ChatEvent(error: '网络错误: $e');
    } finally {
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
  }

  void commitPartial(String partialContent) {
    if (partialContent.isNotEmpty) {
      _messages.add({'role': 'assistant', 'content': partialContent});
    }
  }

  /// 注入当前运行的 JSON-APP 作为对话上下文（放在消息列表最前面）
  /// 优先通过预签名 URL 上传到 MinIO，仅在消息中携带链接；失败时回退到内联 JSON。
  Future<void> setAppContext(Map<String, dynamic> jsonConfig) async {
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

    _messages.insert(0, {
      'role': 'user',
      'content': contextContent,
    });
    _messages.insert(1, {
      'role': 'assistant',
      'content': '好的，我已了解你当前运行的 JSON-APP。请告诉我你需要什么修改或帮助。',
    });
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

  void clear() {
    abort();
    _messages.clear();
  }
}
