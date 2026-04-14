// JSON DSL v3.2 解释器 — 深度重构版
// ───────────────────────────────────────────────
// 核心职责：
//   1. 解析 JSON 配置 → 维护全局 Context
//   2. 完整的 async steps 执行引擎
//   3. 模板表达式 {{ }} 与 JsonLogic 表达式求值
//   4. 丰富的内置函数（HTTP / JSON / 字符串 / 数组 / 类型转换 / 控制流）
//   5. 并发执行 @parallel
//   6. Widget 树构建
// ───────────────────────────────────────────────
import 'dart:convert';
import 'package:flutter/material.dart';
import 'expression_engine.dart';
import 'http_client.dart';
import 'widget_builder.dart';
import 'widgets/position_handler.dart';

class JsonInterpreter extends ChangeNotifier {
  // ============ 配置 & 状态 ============

  late Map<String, dynamic> _config;
  late Map<String, dynamic> _variables;
  late Map<String, dynamic> _functions;
  String _currentScreenId = '';

  /// 循环上下文栈
  final List<Map<String, dynamic>> _loopContextStack = [];

  /// 函数参数上下文栈
  final List<Map<String, dynamic>> _paramsStack = [];

  /// TextField 控制器缓存
  final Map<String, TextEditingController> _textControllers = {};

  /// 表达式引擎
  late ExpressionEngine _expressionEngine;

  /// HTTP 客户端
  final DslHttpClient _httpClient = DslHttpClient();

  /// 页面导航回调
  void Function(String screenId)? onNavigate;

  /// 全局 BuildContext（用于 toast / dialog）
  BuildContext? globalContext;

  // ============ Getters ============

  List<dynamic> get screens =>
      (_config['ui'] as Map<String, dynamic>?)?['screens'] as List<dynamic>? ??
      [];

  String get currentScreenId => _currentScreenId;

  String get appName =>
      (_config['meta'] as Map<String, dynamic>?)?['name'] ?? 'JSON App';

  // ============ 初始化 ============

  JsonInterpreter() {
    _config = {};
    _variables = {};
    _functions = {};
    _expressionEngine = ExpressionEngine(
      variableResolver: getVariable,
      templateResolver: resolveTemplate,
    );
  }

  void loadConfig(Map<String, dynamic> config) {
    _config = config;

    final global = config['global'] as Map<String, dynamic>? ?? {};
    _variables =
        _deepCopy(global['variables'] as Map<String, dynamic>? ?? {});
    _functions = global['functions'] as Map<String, dynamic>? ?? {};

    // 清除旧状态
    _loopContextStack.clear();
    _paramsStack.clear();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    _textControllers.clear();

    // 重建表达式引擎
    _expressionEngine = ExpressionEngine(
      variableResolver: getVariable,
      templateResolver: resolveTemplate,
    );

    // 默认屏幕
    if (screens.isNotEmpty) {
      _currentScreenId =
          (screens.first as Map<String, dynamic>)['id'] ?? 'home';
    }
  }

  /// 执行启动 steps
  Future<void> executeSteps() async {
    final steps = _config['steps'] as List<dynamic>? ?? [];
    for (final step in steps) {
      if (step is Map<String, dynamic>) {
        await _executeStep(step);
      }
    }
  }

  // ============ 变量读写 ============

  dynamic getVariable(String path) {
    // $.loop.item / $.loop.index
    if (path.startsWith(r'$.loop.')) {
      final key = path.substring(7);
      if (_loopContextStack.isNotEmpty) {
        return _loopContextStack.last[key];
      }
      return null;
    }

    // $.params.xxx
    if (path.startsWith(r'$.params.')) {
      final key = path.substring(9);
      if (_paramsStack.isNotEmpty) {
        return _paramsStack.last[key];
      }
      return null;
    }

    // $.global.xxx — 支持点号嵌套路径 $.global.user.name
    if (path.startsWith(r'$.global.')) {
      final subPath = path.substring(9);
      return _getNestedValue(_variables, subPath);
    }

    return null;
  }

  void setVariable(String path, dynamic value) {
    if (path.startsWith(r'$.global.')) {
      final subPath = path.substring(9);
      _setNestedValue(_variables, subPath, value);
      notifyListeners();
    }
  }

  /// 嵌套读取：a.b.c → _variables['a']['b']['c']
  dynamic _getNestedValue(Map<String, dynamic> map, String dotPath) {
    final keys = dotPath.split('.');
    dynamic current = map;
    for (final key in keys) {
      if (current is Map<String, dynamic> && current.containsKey(key)) {
        current = current[key];
      } else {
        return null;
      }
    }
    return current;
  }

  /// 嵌套写入
  void _setNestedValue(Map<String, dynamic> map, String dotPath, dynamic value) {
    final keys = dotPath.split('.');
    if (keys.length == 1) {
      map[keys[0]] = value;
      return;
    }
    dynamic current = map;
    for (var i = 0; i < keys.length - 1; i++) {
      if (current is Map<String, dynamic>) {
        current.putIfAbsent(keys[i], () => <String, dynamic>{});
        current = current[keys[i]];
      } else {
        return;
      }
    }
    if (current is Map<String, dynamic>) {
      current[keys.last] = value;
    }
  }

  // ============ 模板解析 ============

  String resolveTemplate(String template) {
    final regex = RegExp(r'\{\{\s*(.+?)\s*\}\}');
    return template.replaceAllMapped(regex, (match) {
      final expression = match.group(1)!;
      final value = getVariable(expression);
      return value?.toString() ?? '';
    });
  }

  dynamic resolveExpression(dynamic raw) {
    if (raw is String) {
      final regex = RegExp(r'^\{\{\s*(.+?)\s*\}\}$');
      final match = regex.firstMatch(raw);
      if (match != null) {
        return getVariable(match.group(1)!);
      }
      return resolveTemplate(raw);
    }
    return raw;
  }

  // ============ TextField 控制器 ============

  TextEditingController getTextController(
      String bindPath, String currentValue) {
    if (_textControllers.containsKey(bindPath)) {
      final controller = _textControllers[bindPath]!;
      if (controller.text != currentValue) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (controller.text != currentValue) {
            controller.text = currentValue;
            controller.selection = TextSelection.fromPosition(
              TextPosition(offset: currentValue.length),
            );
          }
        });
      }
      return controller;
    }
    final controller = TextEditingController(text: currentValue);
    _textControllers[bindPath] = controller;
    return controller;
  }

  // ============ Action 执行 ============

  Future<void> executeAction(
      Map<String, dynamic> action, BuildContext context) async {
    final type = action['type'] ?? 'call';

    switch (type) {
      case 'call':
        final callTarget = action['call'] as String?;
        final args = action['args'] as Map<String, dynamic>?;
        if (callTarget != null) {
          await _executeCall(callTarget, args ?? {});
        }
        break;
      case 'navigate':
        final screenId = action['screen'] as String?;
        if (screenId != null) {
          navigateTo(screenId);
        }
        break;
    }
  }

  void navigateTo(String screenId) {
    _currentScreenId = screenId;
    onNavigate?.call(screenId);
    notifyListeners();
  }

  // ============ Steps 执行引擎 ============

  Future<dynamic> _executeStep(Map<String, dynamic> step) async {
    // 函数调用
    if (step.containsKey('call')) {
      final callTarget = step['call'] as String;
      final args = step['args'] as Map<String, dynamic>? ?? {};
      final assignVar = step['assign'] as String?;

      final result = await _executeCall(callTarget, args);

      if (assignVar != null && result != null) {
        setVariable(assignVar, result);
      }
      return result;
    }

    // 表达式求值
    if (step.containsKey('expression')) {
      final expr = step['expression'];
      final assignVar = step['assign'] as String?;
      final result = _expressionEngine.evaluate(expr);
      if (assignVar != null) {
        setVariable(assignVar, result);
      }
      return result;
    }
    return null;
  }

  /// 执行函数调用（内置 + 自定义），返回结果
  Future<dynamic> _executeCall(
      String callTarget, Map<String, dynamic> args) async {
    final resolvedArgs = _resolveArgs(args);

    // 自定义全局函数
    if (callTarget.startsWith('@global.')) {
      final funcName = callTarget.substring(8);
      return await _executeGlobalFunction(funcName, resolvedArgs);
    }

    // ──── 内置函数 ────
    switch (callTarget) {
      // ── 基础 ──
      case '@print':
        final value = resolvedArgs['value'] ?? '';
        debugPrint('[JSON DSL] $value');
        return null;

      case '@set':
        final varPath = resolvedArgs['var'] as String?;
        final value = resolvedArgs['value'];
        if (varPath != null) {
          final resolved = _resolveJsonLogicValue(value);
          setVariable(varPath, resolved);
        }
        return null;

      case '@navigate':
        final screen = resolvedArgs['screen'] as String?;
        if (screen != null) navigateTo(screen);
        return null;

      // ── 控制流 ──
      case '@if':
        return await _builtinIf(resolvedArgs);
      case '@while':
        return await _builtinWhile(resolvedArgs);
      case '@for_each':
        return await _builtinForEach(resolvedArgs);
      case '@loop_by_num':
        return await _builtinLoopByNum(resolvedArgs);
      case '@try_catch':
        return await _builtinTryCatch(resolvedArgs);
      case '@parallel':
        return await _builtinParallel(resolvedArgs);
      case '@delay':
        final ms = _toInt(resolvedArgs['ms'] ?? resolvedArgs['milliseconds'] ?? 0);
        await Future.delayed(Duration(milliseconds: ms));
        return null;

      // ── HTTP ──
      case '@http_get':
        return await _builtinHttpGet(resolvedArgs);
      case '@http_post':
        return await _builtinHttpPost(resolvedArgs);
      case '@http_put':
        return await _builtinHttpPut(resolvedArgs);
      case '@http_delete':
        return await _builtinHttpDelete(resolvedArgs);

      // ── JSON ──
      case '@json_decode':
        return _builtinJsonDecode(resolvedArgs);
      case '@json_encode':
        return _builtinJsonEncode(resolvedArgs);

      // ── 字符串 ──
      case '@str_contains':
        final str = resolvedArgs['value']?.toString() ?? '';
        final search = resolvedArgs['search']?.toString() ?? '';
        return str.contains(search);
      case '@str_split':
        final str = resolvedArgs['value']?.toString() ?? '';
        final sep = resolvedArgs['separator']?.toString() ?? '';
        return str.split(sep);
      case '@str_replace':
        final str = resolvedArgs['value']?.toString() ?? '';
        final from = resolvedArgs['from']?.toString() ?? '';
        final to = resolvedArgs['to']?.toString() ?? '';
        return str.replaceAll(from, to);
      case '@str_length':
        return (resolvedArgs['value']?.toString() ?? '').length;
      case '@str_upper':
        return (resolvedArgs['value']?.toString() ?? '').toUpperCase();
      case '@str_lower':
        return (resolvedArgs['value']?.toString() ?? '').toLowerCase();
      case '@str_trim':
        return (resolvedArgs['value']?.toString() ?? '').trim();
      case '@str_substring':
        final str = resolvedArgs['value']?.toString() ?? '';
        final start = _toInt(resolvedArgs['start'] ?? 0);
        final end = resolvedArgs['end'] != null
            ? _toInt(resolvedArgs['end']!)
            : str.length;
        return str.substring(
          start.clamp(0, str.length),
          end.clamp(start, str.length),
        );
      case '@str_starts_with':
        final str = resolvedArgs['value']?.toString() ?? '';
        final prefix = resolvedArgs['prefix']?.toString() ?? '';
        return str.startsWith(prefix);
      case '@str_ends_with':
        final str = resolvedArgs['value']?.toString() ?? '';
        final suffix = resolvedArgs['suffix']?.toString() ?? '';
        return str.endsWith(suffix);

      // ── 数组 ──
      case '@list_length':
        final list = _resolveJsonLogicValue(resolvedArgs['value']);
        return list is List ? list.length : 0;
      case '@list_add':
        final listPath = resolvedArgs['var'] as String?;
        final item = _resolveJsonLogicValue(resolvedArgs['item']);
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final newList = List<dynamic>.from(current)..add(item);
            setVariable(listPath, newList);
            return newList;
          }
        }
        return null;
      case '@list_remove_at':
        final listPath = resolvedArgs['var'] as String?;
        final index = _toInt(resolvedArgs['index'] ?? -1);
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List && index >= 0 && index < current.length) {
            final newList = List<dynamic>.from(current)..removeAt(index);
            setVariable(listPath, newList);
            return newList;
          }
        }
        return null;
      case '@list_insert':
        final listPath = resolvedArgs['var'] as String?;
        final index = _toInt(resolvedArgs['index'] ?? 0);
        final item = _resolveJsonLogicValue(resolvedArgs['item']);
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final newList = List<dynamic>.from(current);
            newList.insert(index.clamp(0, newList.length), item);
            setVariable(listPath, newList);
            return newList;
          }
        }
        return null;
      case '@list_clear':
        final listPath = resolvedArgs['var'] as String?;
        if (listPath != null) {
          setVariable(listPath, []);
        }
        return [];

      // ── 类型转换 ──
      case '@to_string':
        return _resolveJsonLogicValue(resolvedArgs['value'])?.toString() ?? '';
      case '@to_int':
        return _toInt(_resolveJsonLogicValue(resolvedArgs['value']));
      case '@to_double':
        return _toDouble(_resolveJsonLogicValue(resolvedArgs['value']));

      // ── UI 反馈 ──
      case '@show_toast':
        _showToast(resolvedArgs['message']?.toString() ?? '');
        return null;
      case '@show_dialog':
        return await _showAlertDialog(
          resolvedArgs['title']?.toString() ?? '',
          resolvedArgs['message']?.toString() ?? '',
        );

      default:
        debugPrint('[JSON DSL] 未知内置函数: $callTarget');
        return null;
    }
  }

  // ============ 控制流内置函数 ============

  Future<dynamic> _builtinIf(Map<String, dynamic> args) async {
    final condition = args['condition'];
    final thenSteps = args['then'] as List<dynamic>? ?? [];
    final elseSteps = args['else'] as List<dynamic>? ?? [];

    final condResult = _expressionEngine.evaluateBool(condition);

    final steps = condResult ? thenSteps : elseSteps;
    dynamic lastResult;
    for (final step in steps) {
      if (step is Map<String, dynamic>) {
        lastResult = await _executeStep(step);
      }
    }
    return lastResult;
  }

  Future<dynamic> _builtinWhile(Map<String, dynamic> args) async {
    final condition = args['condition'];
    final body = args['body'] as List<dynamic>? ?? [];
    final maxIterations = _toInt(args['max_iterations'] ?? 10000);

    int count = 0;
    while (_expressionEngine.evaluateBool(condition) &&
        count < maxIterations) {
      for (final step in body) {
        if (step is Map<String, dynamic>) {
          await _executeStep(step);
        }
      }
      count++;
    }
    return count;
  }

  Future<dynamic> _builtinForEach(Map<String, dynamic> args) async {
    final sourceExpr = args['source'];
    final body = args['body'] as List<dynamic>? ?? [];

    dynamic source = _resolveJsonLogicValue(sourceExpr);
    if (source is! List) return null;

    for (var i = 0; i < source.length; i++) {
      _loopContextStack.add({
        'item': source[i],
        'index': i,
      });

      for (final step in body) {
        if (step is Map<String, dynamic>) {
          await _executeStep(step);
        }
      }

      _loopContextStack.removeLast();
    }
    return source.length;
  }

  Future<dynamic> _builtinLoopByNum(Map<String, dynamic> args) async {
    final count = _toInt(args['count'] ?? 0);
    final body = args['body'] as List<dynamic>? ?? [];

    for (var i = 0; i < count; i++) {
      _loopContextStack.add({'item': i, 'index': i});

      for (final step in body) {
        if (step is Map<String, dynamic>) {
          await _executeStep(step);
        }
      }

      _loopContextStack.removeLast();
    }
    return count;
  }

  Future<dynamic> _builtinTryCatch(Map<String, dynamic> args) async {
    final trySteps = args['try'] as List<dynamic>? ?? [];
    final catchSteps = args['catch'] as List<dynamic>? ?? [];
    final errorVar = args['error_var'] as String?;

    try {
      dynamic lastResult;
      for (final step in trySteps) {
        if (step is Map<String, dynamic>) {
          lastResult = await _executeStep(step);
        }
      }
      return lastResult;
    } catch (e) {
      if (errorVar != null) {
        setVariable(errorVar, e.toString());
      }
      dynamic lastResult;
      for (final step in catchSteps) {
        if (step is Map<String, dynamic>) {
          lastResult = await _executeStep(step);
        }
      }
      return lastResult;
    }
  }

  Future<dynamic> _builtinParallel(Map<String, dynamic> args) async {
    final stepsList = args['steps'] as List<dynamic>? ?? [];

    final futures = <Future<void>>[];
    for (final step in stepsList) {
      if (step is Map<String, dynamic>) {
        futures.add(_executeStep(step));
      }
    }
    await Future.wait(futures);
    return null;
  }

  // ============ HTTP 内置函数 ============

  Future<Map<String, dynamic>> _builtinHttpGet(
      Map<String, dynamic> args) async {
    final url = args['url']?.toString() ?? '';
    final query = args['query'] as Map<String, dynamic>?;
    final headers = _toStringMap(args['headers']);
    return await _httpClient.get(url, queryParams: query, headers: headers);
  }

  Future<Map<String, dynamic>> _builtinHttpPost(
      Map<String, dynamic> args) async {
    final url = args['url']?.toString() ?? '';
    final body = _resolveJsonLogicValue(args['body']);
    final headers = _toStringMap(args['headers']);
    final contentType = args['content_type']?.toString() ?? 'application/json';
    return await _httpClient.post(url,
        body: body, headers: headers, contentType: contentType);
  }

  Future<Map<String, dynamic>> _builtinHttpPut(
      Map<String, dynamic> args) async {
    final url = args['url']?.toString() ?? '';
    final body = _resolveJsonLogicValue(args['body']);
    final headers = _toStringMap(args['headers']);
    return await _httpClient.put(url, body: body, headers: headers);
  }

  Future<Map<String, dynamic>> _builtinHttpDelete(
      Map<String, dynamic> args) async {
    final url = args['url']?.toString() ?? '';
    final headers = _toStringMap(args['headers']);
    return await _httpClient.delete(url, headers: headers);
  }

  // ============ JSON 内置函数 ============

  dynamic _builtinJsonDecode(Map<String, dynamic> args) {
    final str = args['value']?.toString() ?? '';
    try {
      return json.decode(str);
    } catch (e) {
      debugPrint('[JSON DSL] json_decode 失败: $e');
      return null;
    }
  }

  String _builtinJsonEncode(Map<String, dynamic> args) {
    final value = _resolveJsonLogicValue(args['value']);
    try {
      return json.encode(value);
    } catch (e) {
      debugPrint('[JSON DSL] json_encode 失败: $e');
      return '';
    }
  }

  // ============ UI 反馈 ============

  void _showToast(String message) {
    final ctx = globalContext;
    if (ctx != null && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<bool> _showAlertDialog(String title, String message) async {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return false;

    final result = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ============ 自定义函数执行 ============

  Future<dynamic> _executeGlobalFunction(
      String funcName, Map<String, dynamic> args) async {
    final funcDef = _functions[funcName] as Map<String, dynamic>?;
    if (funcDef == null) {
      debugPrint('[JSON DSL] 未找到函数: $funcName');
      return null;
    }

    // 将实参映射到形参名
    final params = funcDef['params'] as List<dynamic>? ?? [];
    final paramMap = <String, dynamic>{};
    for (final p in params) {
      final paramName = p.toString();
      paramMap[paramName] = args[paramName];
    }

    _paramsStack.add(paramMap);

    dynamic lastResult;
    final logic = funcDef['logic'] as List<dynamic>? ?? [];
    for (final step in logic) {
      if (step is Map<String, dynamic>) {
        lastResult = await _executeStep(step);
      }
    }

    _paramsStack.removeLast();
    return lastResult;
  }

  // ============ 参数解析 ============

  Map<String, dynamic> _resolveArgs(Map<String, dynamic> args) {
    final resolved = <String, dynamic>{};
    for (final entry in args.entries) {
      if (entry.value is String) {
        final str = entry.value as String;
        if (str.contains('{{') && str.contains('}}')) {
          resolved[entry.key] = resolveTemplate(str);
        } else {
          resolved[entry.key] = str;
        }
      } else {
        resolved[entry.key] = entry.value;
      }
    }
    return resolved;
  }

  // ============ JsonLogic 值解析 ============

  dynamic _resolveJsonLogicValue(dynamic value) {
    if (value == null) return null;

    if (value is Map<String, dynamic>) {
      return _expressionEngine.evaluate(value);
    }

    if (value is List) {
      return value.map((e) => _resolveJsonLogicValue(e)).toList();
    }

    if (value is String && value.contains('{{')) {
      return resolveTemplate(value);
    }

    return value;
  }

  // ============ Widget 构建 ============

  Widget buildWidget(BuildContext context, Map<String, dynamic> json) {
    final widgetBuilder = JsonWidgetBuilder();
    final child = widgetBuilder.build(context, json, this);
    final position = json['position'] as Map<String, dynamic>?;
    return applyPosition(child, position);
  }

  Widget buildWidgetInLoopContext({
    required BuildContext context,
    required Map<String, dynamic> json,
    required dynamic loopItem,
    required int loopIndex,
  }) {
    _loopContextStack.add({'item': loopItem, 'index': loopIndex});
    final widget = buildWidget(context, json);
    _loopContextStack.removeLast();
    return widget;
  }

  // ============ 工具方法 ============

  Map<String, dynamic> _deepCopy(Map<String, dynamic> original) {
    final copy = <String, dynamic>{};
    for (final entry in original.entries) {
      if (entry.value is Map<String, dynamic>) {
        copy[entry.key] = _deepCopy(entry.value as Map<String, dynamic>);
      } else if (entry.value is List) {
        copy[entry.key] = _deepCopyList(entry.value as List);
      } else {
        copy[entry.key] = entry.value;
      }
    }
    return copy;
  }

  List<dynamic> _deepCopyList(List<dynamic> original) {
    return original.map((item) {
      if (item is Map<String, dynamic>) return _deepCopy(item);
      if (item is List) return _deepCopyList(item);
      return item;
    }).toList();
  }

  int _toInt(dynamic val) {
    if (val is int) return val;
    if (val is double) return val.toInt();
    if (val is String) return int.tryParse(val) ?? 0;
    return 0;
  }

  double _toDouble(dynamic val) {
    if (val is double) return val;
    if (val is int) return val.toDouble();
    if (val is String) return double.tryParse(val) ?? 0.0;
    return 0.0;
  }

  Map<String, String>? _toStringMap(dynamic val) {
    if (val is Map) {
      return val.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return null;
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    _textControllers.clear();
    super.dispose();
  }
}
