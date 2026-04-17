import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../auth/auth_service.dart';

/// AI 对话事件
class ChatEvent {
  final String? content;      // 增量文本
  final Map<String, dynamic>? jsonApp;  // 检测到的 JSON-APP
  final Map<String, dynamic>? quota;    // 配额信息
  final String? error;

  ChatEvent({this.content, this.jsonApp, this.quota, this.error});
}

/// 管理对话历史并与后端 AI 服务通信（SSE 流式，支持中断）
class AiChatService {
  static const String _baseUrl = 'https://app-backend.dapangyu.work';

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
      request.body = json.encode({'messages': _messages});

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

      await for (final chunk in response.stream.transform(utf8.decoder)) {
        final parts = chunk.split('\n');
        for (final line in parts) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          if (trimmed == 'data: [DONE]') continue;
          if (!trimmed.startsWith('data: ')) continue;

          final dataStr = trimmed.substring(6);
          try {
            final data = json.decode(dataStr) as Map<String, dynamic>;

            // JSON-APP 检测
            if (data.containsKey('has_json') && data['has_json'] == true) {
              yield ChatEvent(
                jsonApp: data['json_app'] as Map<String, dynamic>?,
              );
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
              accumulated += data['error'] as String;
              yield ChatEvent(content: accumulated, error: data['error'] as String);
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

  void clear() {
    abort();
    _messages.clear();
  }
}
