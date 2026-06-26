// HTTP 客户端封装
// 基于 dio 实现 GET / POST，供解释器 @http_get / @http_post 调用
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';
import '../i18n/framework_strings.dart';
import '../platform/http_sse_bridge.dart';

class DslHttpClient {
  static final DslHttpClient _instance = DslHttpClient._internal();
  factory DslHttpClient() => _instance;

  late final Dio _dio;

  DslHttpClient._internal() {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
      ),
    );
  }

  String _resolveUrl(String rawUrl) {
    final url = rawUrl.trim();
    if (url.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasScheme) return url;
    if (url.startsWith('//')) return 'https:$url';
    final base = AppConfig.backendUrl.replaceFirst(RegExp(r'/+$'), '');
    final path = url.startsWith('/') ? url : '/$url';
    return '$base$path';
  }

  /// HTTP GET
  /// 返回 { "status": int, "data": dynamic, "headers": Map, "error": String? }
  Future<Map<String, dynamic>> get(
    String url, {
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.get(
        _resolveUrl(url),
        queryParameters: queryParams,
        options: Options(headers: headers),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP POST
  /// 返回 { "status": int, "data": dynamic, "headers": Map, "error": String? }
  Future<Map<String, dynamic>> post(
    String url, {
    dynamic body,
    Map<String, String>? headers,
    String contentType = 'application/json',
  }) async {
    try {
      final response = await _dio.post(
        _resolveUrl(url),
        data: contentType == 'application/json'
            ? (body is String ? json.decode(body) : body)
            : body,
        options: Options(headers: headers, contentType: contentType),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP PUT
  Future<Map<String, dynamic>> put(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.put(
        _resolveUrl(url),
        data: body,
        options: Options(headers: headers, contentType: 'application/json'),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP DELETE
  Future<Map<String, dynamic>> delete(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.delete(
        _resolveUrl(url),
        options: Options(headers: headers),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP PATCH（部分更新）
  Future<Map<String, dynamic>> patch(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.patch(
        _resolveUrl(url),
        data: body,
        options: Options(headers: headers, contentType: 'application/json'),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP HEAD（只取状态码 + 响应头，无 body；常用于存在性/鉴权探测）
  Future<Map<String, dynamic>> head(
    String url, {
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.head(
        _resolveUrl(url),
        queryParameters: queryParams,
        options: Options(headers: headers),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP OPTIONS（探测允许的方法 / CORS 预检，取状态码 + 响应头）
  Future<Map<String, dynamic>> options(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.request(
        _resolveUrl(url),
        options: Options(method: 'OPTIONS', headers: headers),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP Server-Sent Events stream.
  ///
  /// Returns a summary map and invokes [onEvent] for each parsed SSE event.
  /// The event map contains:
  ///   raw, event, id, data, json, done, delta
  Future<Map<String, dynamic>> sse(
    String url, {
    String method = 'POST',
    dynamic body,
    Map<String, String>? headers,
    String contentType = 'application/json',
    Future<void> Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final events = <Map<String, dynamic>>[];
    try {
      if (kIsWeb && HttpSseWebBridge.isSupported) {
        return await HttpSseWebBridge.stream(
          {
            'url': _resolveUrl(url),
            'method': method,
            'body': body,
            'headers': headers ?? const <String, String>{},
            'contentType': contentType,
          },
          (event) async {
            events.add(event);
            if (onEvent != null) await onEvent(event);
          },
        );
      }

      final response = await _dio.request<ResponseBody>(
        _resolveUrl(url),
        data: contentType == 'application/json'
            ? (body is String ? json.decode(body) : body)
            : body,
        options: Options(
          method: method.toUpperCase(),
          headers: {
            'Accept': 'text/event-stream',
            if (headers != null) ...headers,
          },
          contentType: contentType,
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(minutes: 10),
        ),
      );

      final status = response.statusCode ?? 0;
      final responseBody = response.data;
      if (responseBody == null) {
        return {
          'status': status,
          'events': events,
          'done': false,
          'error': 'Empty stream response',
        };
      }

      var buffer = '';
      await for (final chunk in responseBody.stream) {
        buffer += utf8.decode(_asBytes(chunk), allowMalformed: true);
        buffer = buffer.replaceAll('\r\n', '\n');
        while (true) {
          final idx = buffer.indexOf('\n\n');
          if (idx < 0) break;
          final block = buffer.substring(0, idx);
          buffer = buffer.substring(idx + 2);
          final event = _parseSseBlock(block);
          if (event == null) continue;
          events.add(event);
          if (onEvent != null) await onEvent(event);
          if (event['done'] == true) {
            return {
              'status': status,
              'events': events,
              'done': true,
              'error': null,
            };
          }
        }
      }

      final tail = buffer.trim();
      if (tail.isNotEmpty) {
        final event = _parseSseBlock(tail);
        if (event != null) {
          events.add(event);
          if (onEvent != null) await onEvent(event);
        }
      }

      return {'status': status, 'events': events, 'done': true, 'error': null};
    } on DioException catch (e) {
      return {
        'status': e.response?.statusCode ?? -1,
        'events': events,
        'done': false,
        'error': e.message ?? T.current.widgetHttpNetworkFailed,
      };
    } catch (e) {
      return {
        'status': -1,
        'events': events,
        'done': false,
        'error': e.toString(),
      };
    }
  }

  List<int> _asBytes(dynamic chunk) {
    if (chunk is Uint8List) return chunk;
    if (chunk is List<int>) return chunk;
    return utf8.encode(chunk?.toString() ?? '');
  }

  Map<String, dynamic>? _parseSseBlock(String block) {
    final trimmed = block.trim();
    if (trimmed.isEmpty) return null;
    final dataLines = <String>[];
    String? eventName;
    String? id;
    int? retry;

    for (final rawLine in block.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty || line.startsWith(':')) continue;
      final sep = line.indexOf(':');
      final field = sep >= 0 ? line.substring(0, sep) : line;
      var value = sep >= 0 ? line.substring(sep + 1) : '';
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          eventName = value;
          break;
        case 'data':
          dataLines.add(value);
          break;
        case 'id':
          id = value;
          break;
        case 'retry':
          retry = int.tryParse(value);
          break;
      }
    }

    final data = dataLines.join('\n');
    final done = data.trim() == '[DONE]';
    dynamic jsonData;
    if (!done && data.trim().isNotEmpty) {
      try {
        jsonData = json.decode(data);
      } catch (_) {
        jsonData = null;
      }
    }

    return {
      'raw': block,
      'event': eventName,
      'id': id,
      'retry': retry,
      'data': data,
      'json': jsonData,
      'done': done,
      'delta': _extractTextDelta(jsonData),
    };
  }

  String _extractTextDelta(dynamic jsonData) {
    if (jsonData is! Map) return '';

    // OpenAI-compatible Chat Completions:
    // choices[0].delta.content
    final choices = jsonData['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final delta = first['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String) return content;
        }
        final text = first['text'];
        if (text is String) return text;
      }
    }

    // OpenAI Responses API:
    // { type: response.output_text.delta, delta: "..." }
    final type = jsonData['type']?.toString() ?? '';
    final delta = jsonData['delta'];
    if (type == 'response.output_text.delta' && delta is String) return delta;

    return '';
  }

  Map<String, dynamic> _buildResult(Response response) {
    return {
      'status': response.statusCode ?? 0,
      'data': response.data,
      'headers': response.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
      'error': null,
    };
  }

  Map<String, dynamic> _buildError(DioException e) {
    debugPrint('[JSON DSL HTTP] 请求失败: ${e.message}');
    return {
      'status': e.response?.statusCode ?? -1,
      'data': e.response?.data,
      'headers': {},
      'error': e.message ?? T.current.widgetHttpNetworkFailed,
    };
  }
}
