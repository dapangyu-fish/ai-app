import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// 管理对话历史并与后端 AI 服务通信（SSE 流式，支持中断）
class AiChatService {
  static const String _baseUrl = 'http://103.233.254.179:5566';

  final List<Map<String, String>> _messages = [
    {
      'role': 'system',
      'content': '你是一个友好的 AI 助手，回答尽量简洁。用户可能用中文或英文与你交流，请用对应语言回复。',
    },
  ];

  http.Client? _activeClient;

  List<Map<String, String>> get messages =>
      _messages.where((m) => m['role'] != 'system').toList();

  /// 中断正在进行的流式请求
  void abort() {
    _activeClient?.close();
    _activeClient = null;
  }

  /// 发送用户消息，返回 Stream，每次 yield 累计的完整文本。
  Stream<String> sendStream(String userMessage) async* {
    // 先中断上一个还在跑的请求
    abort();

    _messages.add({'role': 'user', 'content': userMessage});

    final client = http.Client();
    _activeClient = client;

    try {
      final request = http.Request(
        'POST',
        Uri.parse('$_baseUrl/chat'),
      );
      request.headers['Content-Type'] = 'application/json';
      request.body = json.encode({'messages': _messages});

      final response = await client.send(request).timeout(
        const Duration(seconds: 60),
      );

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        _messages.removeLast();
        yield '服务器错误 (${response.statusCode}): $body';
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
            if (data.containsKey('error')) {
              accumulated += data['error'] as String;
              yield accumulated;
              continue;
            }
            final content = data['content'] as String? ?? '';
            if (content.isNotEmpty) {
              accumulated += content;
              yield accumulated;
            }
          } catch (_) {}
        }
      }

      if (accumulated.isNotEmpty) {
        _messages.add({'role': 'assistant', 'content': accumulated});
      } else {
        _messages.removeLast();
        yield '未收到回复';
      }
    } on http.ClientException {
      // abort() 关闭 client 会触发此异常 — 正常中断，不报错
      // 保留已收到的部分回复在历史里（由调用方处理）
    } catch (e) {
      _messages.removeLast();
      yield '网络错误: $e';
    } finally {
      if (_activeClient == client) {
        _activeClient = null;
      }
      client.close();
    }
  }

  /// 把当前的部分回复固化到对话历史（中断时调用）
  void commitPartial(String partialContent) {
    if (partialContent.isNotEmpty) {
      _messages.add({'role': 'assistant', 'content': partialContent});
    }
  }

  void clear() {
    abort();
    _messages.removeWhere((m) => m['role'] != 'system');
  }
}
