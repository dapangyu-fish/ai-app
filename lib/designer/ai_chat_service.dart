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
  // 当前流读到的最后一条 Redis Stream entry id；断线重连传给后端实现"无丢失续读"
  String _lastEntryId = '0';

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
    // 后端 fire-and-forget abort：让 worker 真的停下来。如果没有 sessionId 也无所谓。
    _abortBackend(_sessionId);
  }

  void _abortBackend(String sid) {
    if (sid.isEmpty) return;
    final token = AuthService.token;
    if (token == null) return;
    // 不 await：abort 不能让 UI 卡住
    http.post(
      Uri.parse('$_baseUrl/api/ai/chat/$sid/abort'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 3)).catchError((e) {
      debugPrint('[AI_CHAT] abort backend error (ignored): $e');
      return http.Response('', 0);
    });
  }

  /// 检查后端对应 session 是否仍在跑（新架构：worker 是否还活）
  /// 等价语义：meta.status == "running" && process 还在
  Future<bool> isSessionAlive() async {
    if (_sessionId.isEmpty) return false;
    try {
      final token = AuthService.token;
      final headers = <String, String>{};
      if (token != null) headers['Authorization'] = 'Bearer $token';
      final resp = await http
          .get(
            Uri.parse('$_baseUrl/api/ai/chat/$_sessionId/status'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 404) return false;  // 已过期
      if (resp.statusCode != 200) return false;
      final data = json.decode(resp.body) as Map<String, dynamic>;
      // running 状态 + 进程还在（process_alive 是后端 supervisor-side 的真实进程检查）
      return data['status'] == 'running' && (data['process_alive'] == true);
    } catch (e) {
      debugPrint('[AI_CHAT] isSessionAlive error: $e');
      return false;
    }
  }

  /// 发送用户消息，返回 `Stream<ChatEvent>`。
  ///
  /// 新流程（feat/ai-background-push, Phase 1）：
  ///   1. POST /api/ai/chat/start  -> 后端线程池 spawn worker，立即返回
  ///   2. GET  /api/ai/chat/{id}/stream?last_id=N  -> SSE 读 Redis Stream
  ///   3. 网络断 / 切后台 → SSE 自然断 → 客户端拿 _lastEntryId 续读，
  ///      worker 仍在跑，不丢事件
  ///   4. 收到 [DONE] → 任务真的完成，退出
  Stream<ChatEvent> sendStream(String userMessage) async* {
    // 本地中止旧流；force_restart=true 时后端也会杀掉旧 worker
    abort();
    _aborting = false;
    _lastEntryId = '0';

    debugPrint('[AI_CHAT] ========== 发送消息 ==========');
    debugPrint('[AI_CHAT] 消息内容: $userMessage');
    debugPrint('[AI_CHAT] Session ID: $_sessionId');
    debugPrint('[AI_CHAT] Provider: $_selectedProvider');
    debugPrint('[AI_CHAT] ====================================');

    // ── 1. POST /start：起 worker ──
    final startResult = await _postStart(userMessage, forceRestart: true);
    if (startResult.error != null) {
      yield ChatEvent(error: startResult.error, quota: startResult.quota);
      return;
    }
    // start 成功 → 标记 session 已使用
    if (!_sessionUsed) {
      _sessionUsed = true;
      SharedPreferences.getInstance().then((prefs) {
        prefs.setBool(_sessionUsedKey, true);
      });
    }

    // ── 2. SSE 流式读 + 自动重连 ──
    final state = _StreamState();
    int reconnectCount = 0;
    while (true) {
      if (_aborting) {
        debugPrint('[AI_CHAT] 用户主动中止，不重连');
        return;
      }

      state.outcome = _StreamOutcome.retry;  // 默认假设需要重连，_readStreamOnce 内部会改
      await for (final ev in _readStreamOnce(state)) {
        yield ev;
      }

      if (state.outcome == _StreamOutcome.done) {
        debugPrint('[AI_CHAT] 流正常结束 (last_id=$_lastEntryId)');
        return;
      }

      // retry：等一下再连，最多 30 次（指数 backoff，封顶 5s）
      reconnectCount++;
      if (reconnectCount > 30) {
        yield ChatEvent(error: '连接持续不稳定，已停止重试');
        return;
      }
      final delayMs = (500 * (1 << (reconnectCount.clamp(1, 4) - 1))).clamp(500, 5000);
      debugPrint('[AI_CHAT] 第 $reconnectCount 次重连，${delayMs}ms 后...');
      await Future.delayed(Duration(milliseconds: delayMs));
    }
  }

  /// 内部：读一次 SSE 直到流结束或断线，把事件 yield 出去；
  /// 流结束后通过 [state.outcome] 告诉调用方下一步该重连还是退出。
  Stream<ChatEvent> _readStreamOnce(_StreamState state) async* {
    final client = http.Client();
    _activeClient = client;

    final token = AuthService.token;
    final url = '$_baseUrl/api/ai/chat/$_sessionId/stream?last_id=${Uri.encodeQueryComponent(_lastEntryId)}';
    debugPrint('[AI_CHAT] >>> SSE GET $url');

    try {
      final request = http.Request('GET', Uri.parse(url));
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept'] = 'text/event-stream';

      final response = await client.send(request).timeout(const Duration(seconds: 30));

      if (response.statusCode == 401 && token != null) {
        try {
          await AuthService.refreshSession();
          state.outcome = _StreamOutcome.retry;
          return;
        } catch (_) {
          yield ChatEvent(error: '请先登录');
          state.outcome = _StreamOutcome.done;
          return;
        }
      }
      if (response.statusCode == 404) {
        yield ChatEvent(error: 'Session 已过期，请重新发起对话');
        state.outcome = _StreamOutcome.done;
        return;
      }
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        debugPrint('[AI_CHAT] SSE HTTP ${response.statusCode}: $body');
        // 5xx → 重连；4xx → 报错
        if (response.statusCode >= 500) {
          state.outcome = _StreamOutcome.retry;
          return;
        }
        yield ChatEvent(error: '服务器错误 (${response.statusCode}): $body');
        state.outcome = _StreamOutcome.done;
        return;
      }

      // 解析 SSE：id:、data:、:heartbeat
      String? pendingId;
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (_aborting) {
          state.outcome = _StreamOutcome.done;
          return;
        }
        final trimmed = line.trimRight();

        if (trimmed.isEmpty) {
          continue;  // SSE event separator
        }
        if (trimmed.startsWith(':')) {
          continue;  // comment / heartbeat
        }
        if (trimmed.startsWith('id:')) {
          pendingId = trimmed.substring(3).trim();
          continue;
        }
        if (!trimmed.startsWith('data:')) continue;

        final dataStr = trimmed.substring(5).trimLeft();

        if (dataStr == '[DONE]') {
          debugPrint('[AI_CHAT] <<< SSE [DONE]');
          // 流结束后兜底解析累积文本里的标签
          await for (final ev in _emitTrailingTags(state)) {
            yield ev;
          }
          state.outcome = _StreamOutcome.done;
          return;
        }

        // 真正业务事件
        if (!dataStr.contains('"content"') && !dataStr.contains('"thinking"')) {
          debugPrint('[AI_CHAT] <<< SSE: ${dataStr.length > 200 ? "${dataStr.substring(0, 200)}..." : dataStr}');
        }

        try {
          final data = json.decode(dataStr) as Map<String, dynamic>;
          await for (final ev in _handleEvent(data, state)) {
            yield ev;
          }
          // 推进游标：data 处理成功后才更新（否则下次重连会跳过没处理完的事件）
          if (pendingId != null) {
            _lastEntryId = pendingId;
            pendingId = null;
          }
        } catch (e) {
          debugPrint('[AI_CHAT] 事件 JSON 解析失败: $e');
        }
      }

      // 流自然结束（后端 10min cutover 或 keep-alive 超时）但没收到 [DONE]
      // → 任务可能还在跑，重连续读
      debugPrint('[AI_CHAT] SSE 流自然结束，无 [DONE]，重连');
      state.outcome = _StreamOutcome.retry;
    } on http.ClientException catch (e) {
      debugPrint('[AI_CHAT] ClientException: $e');
      if (_aborting) {
        state.outcome = _StreamOutcome.done;
        return;
      }
      state.outcome = _StreamOutcome.retry;
    } on TimeoutException catch (_) {
      debugPrint('[AI_CHAT] SSE 连接超时');
      if (_aborting) {
        state.outcome = _StreamOutcome.done;
        return;
      }
      state.outcome = _StreamOutcome.retry;
    } catch (e) {
      debugPrint('[AI_CHAT] SSE 未知错误: $e');
      state.outcome = _StreamOutcome.retry;
    } finally {
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
  }

  /// 处理单条业务事件（JSON shape 与老版本完全一致）
  Stream<ChatEvent> _handleEvent(Map<String, dynamic> data, _StreamState state) async* {
    if (data.containsKey('generating_json') && data['generating_json'] == true) {
      yield ChatEvent(isGeneratingJson: true);
      return;
    }
    if (data.containsKey('generating_json') && data['generating_json'] == false) {
      return;
    }
    if (data.containsKey('request_action')) {
      yield ChatEvent(requestAction: data['request_action'] as String);
      return;
    }
    if (data.containsKey('status')) {
      yield ChatEvent(statusMessage: data['message'] as String? ?? '');
      return;
    }
    if (data.containsKey('final_content')) {
      final finalText = data['final_content'] as String? ?? '';
      if (finalText.isNotEmpty) {
        debugPrint('[AI_CHAT] 收到最终完整内容，长度: ${finalText.length}');
        if (finalText.length >= state.accumulated.length) {
          state.accumulated = finalText;
          yield ChatEvent(content: state.accumulated);
        } else {
          debugPrint('[AI_CHAT] final_content 比累积还短，忽略避免回退');
        }
      }
      return;
    }
    if (data.containsKey('assistant_content')) {
      final chunk = data['assistant_content'] as String? ?? '';
      if (chunk.isNotEmpty) {
        if (!state.accumulated.contains(chunk)) state.accumulated += chunk;
        yield ChatEvent(content: state.accumulated);
      }
      return;
    }
    if (data.containsKey('final_thinking')) {
      final ft = data['final_thinking'] as String? ?? '';
      if (ft.isNotEmpty && ft.length >= state.accumulatedThinking.length) {
        state.accumulatedThinking = ft;
        yield ChatEvent(thinking: state.accumulatedThinking);
      }
      return;
    }
    if (data.containsKey('assistant_thinking')) {
      final chunk = data['assistant_thinking'] as String? ?? '';
      if (chunk.isNotEmpty) {
        if (!state.accumulatedThinking.contains(chunk)) state.accumulatedThinking += chunk;
        yield ChatEvent(thinking: state.accumulatedThinking);
      }
      return;
    }
    if (data.containsKey('has_json') && data['has_json'] == true) {
      Map<String, dynamic>? parsedApp;
      if (data['json_url'] != null) {
        final url = data['json_url'] as String;
        try {
          final getResp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
          if (getResp.statusCode == 200) {
            parsedApp = json.decode(utf8.decode(getResp.bodyBytes)) as Map<String, dynamic>;
          } else {
            yield ChatEvent(failedJsonUrl: url, error: '下载生成的 JSON 失败 (HTTP ${getResp.statusCode})');
          }
        } catch (e) {
          yield ChatEvent(failedJsonUrl: url, error: '下载 JSON 异常: $e');
        }
      } else {
        parsedApp = data['json_app'] as Map<String, dynamic>?;
      }
      if (parsedApp != null) yield ChatEvent(jsonApp: parsedApp);
      return;
    }
    if (data.containsKey('quota')) {
      yield ChatEvent(quota: data['quota'] as Map<String, dynamic>?);
      return;
    }
    if (data.containsKey('error')) {
      yield ChatEvent(error: data['error'] as String);
      return;
    }
    if (data.containsKey('thinking')) {
      final t = data['thinking'] as String? ?? '';
      if (t.isNotEmpty) {
        state.accumulatedThinking += t;
        yield ChatEvent(thinking: state.accumulatedThinking);
      }
      return;
    }
    final content = data['content'] as String? ?? '';
    if (content.isNotEmpty) {
      state.accumulated += content;
      yield ChatEvent(content: state.accumulated);
    }
  }

  /// 流真的结束（[DONE]）后兜底解析累积文本里的 [json_app_url] / [request_action] / ```json``` 标签
  Stream<ChatEvent> _emitTrailingTags(_StreamState state) async* {
    final accumulated = state.accumulated;

    // 1. [json_app_url]…[/json_app_url] - 等用户确认下载
    final urlRegex = RegExp(r'\[json_app_url\]([^\[]+?)\[/json_app_url\]');
    final urlMatch = urlRegex.firstMatch(accumulated);
    if (urlMatch != null) {
      final raw = urlMatch.group(1)!.trim();
      final httpMatch = RegExp(r'https?://[^\s\)\]\(\<\>"]+').firstMatch(raw);
      final url = httpMatch?.group(0) ?? raw;
      debugPrint('[AI_CHAT] 流结束，检测到 JSON URL: $url');
      yield ChatEvent(pendingJsonUrl: url);
    }

    // 2. [request_action]
    final actionRegex = RegExp(r'\[request_action\]([^\]]+)\[/request_action\]');
    final actionMatch = actionRegex.firstMatch(accumulated);
    if (actionMatch != null) {
      yield ChatEvent(requestAction: actionMatch.group(1)!);
    }

    // 3. 内联 ```json``` 块（仅当没有 url 时）
    if (urlMatch == null) {
      final jsonBlockRegex = RegExp(r'```json\s*(\{.*?\})\s*```', dotAll: true);
      final match = jsonBlockRegex.firstMatch(accumulated);
      if (match != null) {
        try {
          final parsed = json.decode(match.group(1)!) as Map<String, dynamic>;
          yield ChatEvent(jsonApp: parsed);
        } catch (_) {}
      }
    }
  }

  /// POST /api/ai/chat/start，处理 401 刷新、429 配额、5xx 重试
  Future<_StartResult> _postStart(String userMessage, {required bool forceRestart}) async {
    const maxAttempts = 3;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        await Future.delayed(Duration(seconds: attempt - 1));
        if (_aborting) return _StartResult.error('已取消');
      }
      try {
        final token = AuthService.token;
        final headers = <String, String>{'Content-Type': 'application/json'};
        if (token != null) headers['Authorization'] = 'Bearer $token';
        final body = json.encode({
          'messages': [{'role': 'user', 'content': userMessage}],
          'session_id': _sessionId,
          'provider': _selectedProvider,
          'force_restart': forceRestart,
        });
        var resp = await http
            .post(Uri.parse('$_baseUrl/api/ai/chat/start'), headers: headers, body: body)
            .timeout(const Duration(seconds: 30));

        if (resp.statusCode == 401 && token != null) {
          try {
            await AuthService.refreshSession();
            final newToken = AuthService.token;
            if (newToken != null) headers['Authorization'] = 'Bearer $newToken';
            resp = await http
                .post(Uri.parse('$_baseUrl/api/ai/chat/start'), headers: headers, body: body)
                .timeout(const Duration(seconds: 30));
          } catch (_) {
            return _StartResult.error('请先登录');
          }
        }

        if (resp.statusCode == 429) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          return _StartResult.error(data['error'] as String? ?? '配额已用完',
              quota: data['quota'] as Map<String, dynamic>?);
        }
        if (resp.statusCode == 401) return _StartResult.error('请先登录');
        if (resp.statusCode >= 500) {
          lastError = 'HTTP ${resp.statusCode}';
          continue;  // retry
        }
        if (resp.statusCode != 200) {
          return _StartResult.error('服务器错误 (${resp.statusCode}): ${resp.body}');
        }

        final data = json.decode(resp.body) as Map<String, dynamic>;
        debugPrint('[AI_CHAT] start ok: $data');
        return _StartResult.ok(data['session_id'] as String? ?? _sessionId);
      } on TimeoutException {
        lastError = '连接超时';
      } on http.ClientException catch (e) {
        if (_aborting) return _StartResult.error('已取消');
        lastError = e;
      } catch (e) {
        lastError = e;
      }
    }
    return _StartResult.error('网络错误: $lastError');
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

// ────────────── 内部辅助类型（仅 sendStream 重连循环用）──────────────

enum _StreamOutcome { done, retry }

class _StreamState {
  String accumulated = '';
  String accumulatedThinking = '';
  _StreamOutcome outcome = _StreamOutcome.retry;
}

class _StartResult {
  final String? sessionId;
  final String? error;
  final Map<String, dynamic>? quota;

  _StartResult._(this.sessionId, this.error, this.quota);

  factory _StartResult.ok(String sid) => _StartResult._(sid, null, null);
  factory _StartResult.error(String msg, {Map<String, dynamic>? quota}) =>
      _StartResult._(null, msg, quota);
}
