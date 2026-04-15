// JSON DSL v3.2 解释器 — jsonlogic 标准版
// ───────────────────────────────────────────────
// 表达式引擎替换为 pub.dev/packages/jsonlogic (2.0.2)
// 自定义扩展操作符通过 jl.add() 注册
// 变量路径格式：global.xxx / loop.item / params.xxx（兼容 $.global.xxx 旧格式）
// ───────────────────────────────────────────────
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:jsonlogic/jsonlogic.dart';
import 'http_client.dart';
import 'dependency_loader.dart';
import 'widget_builder.dart';
import 'widgets/position_handler.dart';

class JsonInterpreter extends ChangeNotifier {
  // ============ 配置 & 状态 ============

  late Map<String, dynamic> _config;
  late Map<String, dynamic> _variables;
  late Map<String, dynamic> _functions;
  String _currentScreenId = '';

  final List<Map<String, dynamic>> _loopContextStack = [];
  final List<Map<String, dynamic>> _paramsStack = [];
  final Map<String, TextEditingController> _textControllers = {};

  /// jsonlogic 标准引擎 + 自定义操作符
  late Jsonlogic _jl;

  final DslHttpClient _httpClient = DslHttpClient();

  /// 依赖加载器
  final DependencyLoader _depLoader = DependencyLoader();

  void Function(String screenId)? onNavigate;
  BuildContext? globalContext;

  // ============ Getters ============

  List<dynamic> get screens =>
      (_config['ui'] as Map<String, dynamic>?)?['screens'] as List<dynamic>? ??
      [];

  String get currentScreenId => _currentScreenId;

  String get appName =>
      (_config['meta'] as Map<String, dynamic>?)?['name'] ?? 'JSON App';

  /// 获取依赖加载器（供 ref 控件使用）
  DependencyLoader get depLoader => _depLoader;

  // ============ 初始化 ============

  JsonInterpreter() {
    _config = {};
    _variables = {};
    _functions = {};
    _jl = _createJsonLogic();
  }

  Jsonlogic _createJsonLogic() {
    final jl = Jsonlogic(); // 已包含标准操作符

    // ── 字符串扩展 ──
    jl.add('str_len', (applier, data, params) {
      if (params.isEmpty) return 0;
      return applier(params[0], data)?.toString().length ?? 0;
    });
    jl.add('str_upper', (applier, data, params) {
      if (params.isEmpty) return '';
      return (applier(params[0], data)?.toString() ?? '').toUpperCase();
    });
    jl.add('str_lower', (applier, data, params) {
      if (params.isEmpty) return '';
      return (applier(params[0], data)?.toString() ?? '').toLowerCase();
    });
    jl.add('str_trim', (applier, data, params) {
      if (params.isEmpty) return '';
      return (applier(params[0], data)?.toString() ?? '').trim();
    });
    jl.add('str_contains', (applier, data, params) {
      if (params.length < 2) return false;
      final str = applier(params[0], data)?.toString() ?? '';
      final search = applier(params[1], data)?.toString() ?? '';
      return str.contains(search);
    });
    jl.add('str_replace', (applier, data, params) {
      if (params.length < 3) return applier(params[0], data)?.toString() ?? '';
      final str = applier(params[0], data)?.toString() ?? '';
      final from = applier(params[1], data)?.toString() ?? '';
      final to = applier(params[2], data)?.toString() ?? '';
      return str.replaceAll(from, to);
    });
    jl.add('str_split', (applier, data, params) {
      if (params.length < 2) return [applier(params[0], data)?.toString() ?? ''];
      final str = applier(params[0], data)?.toString() ?? '';
      final sep = applier(params[1], data)?.toString() ?? '';
      return str.split(sep);
    });
    jl.add('str_join', (applier, data, params) {
      if (params.isEmpty) return '';
      final list = applier(params[0], data);
      final sep = params.length > 1 ? applier(params[1], data)?.toString() ?? '' : '';
      if (list is List) return list.map((e) => e?.toString() ?? '').join(sep);
      return list?.toString() ?? '';
    });

    // ── 数组扩展 ──
    jl.add('length', (applier, data, params) {
      if (params.isEmpty) return 0;
      final val = applier(params[0], data);
      if (val is List) return val.length;
      if (val is String) return val.length;
      if (val is Map) return val.length;
      return 0;
    });
    jl.add('at', (applier, data, params) {
      if (params.length < 2) return null;
      final source = applier(params[0], data);
      final index = _toInt(applier(params[1], data));
      if (source is List && index >= 0 && index < source.length) {
        return source[index];
      }
      return null;
    });
    jl.add('slice', (applier, data, params) {
      if (params.isEmpty) return [];
      final source = applier(params[0], data);
      if (source is! List) return [];
      final start = (params.length > 1 ? _toInt(applier(params[1], data)) : 0)
          .clamp(0, source.length);
      final end = (params.length > 2
              ? _toInt(applier(params[2], data))
              : source.length)
          .clamp(start, source.length);
      return source.sublist(start, end);
    });
    jl.add('sort', (applier, data, params) {
      if (params.isEmpty) return [];
      final source = applier(params[0], data);
      if (source is! List) return [];
      final copy = List<dynamic>.from(source);
      copy.sort((a, b) {
        if (a is num && b is num) return a.compareTo(b);
        return a.toString().compareTo(b.toString());
      });
      return copy;
    });
    jl.add('reverse', (applier, data, params) {
      if (params.isEmpty) return [];
      final source = applier(params[0], data);
      if (source is! List) return [];
      return source.reversed.toList();
    });

    // ── 类型转换 ──
    jl.add('to_string', (applier, data, params) {
      if (params.isEmpty) return '';
      return applier(params[0], data)?.toString() ?? '';
    });
    jl.add('to_int', (applier, data, params) {
      if (params.isEmpty) return 0;
      return _toInt(applier(params[0], data));
    });
    jl.add('to_double', (applier, data, params) {
      if (params.isEmpty) return 0.0;
      return _toDouble(applier(params[0], data));
    });

    // ── 数学扩展 ──
    jl.add('abs', (applier, data, params) {
      if (params.isEmpty) return 0;
      final v = applier(params[0], data);
      if (v is num) return v.abs();
      return 0;
    });

    return jl;
  }

  // ============ jsonlogic 数据上下文 ============

  /// 每次求值前，将当前状态组装为 jsonlogic 的 data 参数
  Map<String, dynamic> _buildDataContext() {
    return {
      'global': _variables,
      'loop': _loopContextStack.isNotEmpty ? _loopContextStack.last : {},
      'params': _paramsStack.isNotEmpty ? _paramsStack.last : {},
    };
  }

  /// 通过 jsonlogic 求值表达式
  /// 仅用于原始 JSON 配置中的 jsonlogic 表达式（Map），不用于已解析的运行时数据
  dynamic _evaluateExpression(dynamic value) {
    if (value == null) return null;
    if (value is num || value is bool) return value;

    if (value is String) {
      if (value.contains('{{') && value.contains('}}')) {
        return resolveExpression(value);
      }
      return value;
    }

    // Map → JsonLogic 表达式（来自原始 JSON 配置，不会是运行时数据）
    if (value is Map<String, dynamic>) {
      final preprocessed = _resolveTemplatesInRule(value);
      return _jl.apply(preprocessed, _buildDataContext());
    }

    // List → 解析字符串模板，Map/其他类型原样保留
    if (value is List) {
      return value.map((e) {
        if (e is String && e.contains('{{') && e.contains('}}')) {
          return resolveExpression(e);
        }
        return e;
      }).toList();
    }

    return value;
  }

  /// 求值为布尔
  bool _evaluateBool(dynamic condition) {
    final result = _evaluateExpression(condition);
    if (result == null) return false;
    if (result is bool) return result;
    if (result is num) return result != 0;
    if (result is String) return result.isNotEmpty;
    if (result is List) return result.isNotEmpty;
    return true;
  }

  /// 递归预处理规则中的 {{ }} 模板字符串
  dynamic _resolveTemplatesInRule(dynamic rule) {
    if (rule is String && rule.contains('{{') && rule.contains('}}')) {
      return resolveTemplate(rule);
    }
    if (rule is List) {
      return rule.map((e) => _resolveTemplatesInRule(e)).toList();
    }
    if (rule is Map<String, dynamic>) {
      return rule.map((k, v) => MapEntry(k, _resolveTemplatesInRule(v)));
    }
    return rule;
  }

  // ============ 加载配置 ============

  void loadConfig(Map<String, dynamic> config) {
    _config = config;

    final global = config['global'] as Map<String, dynamic>? ?? {};
    _variables =
        _deepCopy(global['variables'] as Map<String, dynamic>? ?? {});
    _functions = global['functions'] as Map<String, dynamic>? ?? {};

    _loopContextStack.clear();
    _paramsStack.clear();
    _depLoader.clear();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    _textControllers.clear();

    if (screens.isNotEmpty) {
      _currentScreenId =
          (screens.first as Map<String, dynamic>)['id'] ?? 'home';
    }
  }

  Future<void> executeSteps() async {
    // 先加载依赖
    final deps = _config['dependencies'] as Map<String, dynamic>?;
    if (deps != null && deps.isNotEmpty) {
      await _depLoader.loadDependencies(deps);
    }

    // 再执行 steps
    final steps = _config['steps'] as List<dynamic>? ?? [];
    for (final step in steps) {
      if (step is Map<String, dynamic>) {
        await _executeStep(step);
      }
    }
  }

  // ============ 变量读写 ============

  /// 读取变量（支持 global.xxx / loop.xxx / params.xxx，兼容 $.global.xxx 旧格式）
  dynamic getVariable(String path) {
    // 兼容旧格式：去掉 $. 前缀
    if (path.startsWith(r'$.')) {
      path = path.substring(2);
    }

    if (path.startsWith('loop.')) {
      final subPath = path.substring(5);
      if (_loopContextStack.isNotEmpty) {
        return _getNestedValue(_loopContextStack.last, subPath);
      }
      return null;
    }

    if (path.startsWith('params.')) {
      final subPath = path.substring(7);
      if (_paramsStack.isNotEmpty) {
        return _getNestedValue(_paramsStack.last, subPath);
      }
      return null;
    }

    if (path.startsWith('global.')) {
      final subPath = path.substring(7);
      return _getNestedValue(_variables, subPath);
    }

    // 没有前缀：先查 global 变量，再查依赖模块变量
    final globalResult = _getNestedValue(_variables, path);
    if (globalResult != null) return globalResult;

    // 尝试作为依赖变量: "depName.varPath"
    return _getDependencyVariable(path);
  }

  /// 读取依赖模块的变量（只读）: "depName.varPath"
  dynamic _getDependencyVariable(String fullPath) {
    final dotIndex = fullPath.indexOf('.');
    if (dotIndex < 0) return null;
    final depName = fullPath.substring(0, dotIndex);
    final varPath = fullPath.substring(dotIndex + 1);
    return _depLoader.findVariable(depName, varPath);
  }

  void setVariable(String path, dynamic value) {
    if (path.startsWith(r'$.')) {
      path = path.substring(2);
    }

    if (path.startsWith('global.')) {
      final subPath = path.substring(7);
      _setNestedValue(_variables, subPath, value);
      notifyListeners();
    } else if (!path.startsWith('loop.') && !path.startsWith('params.')) {
      // 没有前缀的直接当 global 变量（与 getVariable 行为一致）
      _setNestedValue(_variables, path, value);
      notifyListeners();
    }
  }

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

  void _setNestedValue(
      Map<String, dynamic> map, String dotPath, dynamic value) {
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

  /// 解析表达式，返回原始值（{{ path }} 返回实际类型，非字符串化）
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
    // 支持 depName:screenId 格式导航到依赖的页面
    if (screenId.contains(':')) {
      final parts = screenId.split(':');
      final depName = parts[0];
      final depScreenId = parts[1];
      final depScreen = _depLoader.findScreen(depName, depScreenId);
      if (depScreen != null) {
        // 将依赖的 screen 注入到当前 screens 列表中（如果不存在）
        final localScreens = screens;
        final exists = localScreens.any((s) =>
            s is Map<String, dynamic> && s['id'] == screenId);
        if (!exists) {
          // 用 depName:screenId 作为唯一 ID 避免冲突
          final injectedScreen = Map<String, dynamic>.from(depScreen);
          injectedScreen['id'] = screenId;
          ((_config['ui'] as Map<String, dynamic>)['screens'] as List)
              .add(injectedScreen);
        }
      }
    }
    _currentScreenId = screenId;
    onNavigate?.call(screenId);
    notifyListeners();
  }

  // ============ Steps 执行引擎 ============

  Future<dynamic> _executeStep(Map<String, dynamic> step) async {
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

    if (step.containsKey('expression')) {
      final expr = step['expression'];
      final assignVar = step['assign'] as String?;
      final result = _evaluateExpression(expr);
      if (assignVar != null) {
        setVariable(assignVar, result);
      }
      return result;
    }
    return null;
  }

  Future<dynamic> _executeCall(
      String callTarget, Map<String, dynamic> args) async {
    final resolvedArgs = _resolveArgs(args);

    // 自定义全局函数: @global.funcName
    if (callTarget.startsWith('@global.')) {
      final funcName = callTarget.substring(8);
      return await _executeGlobalFunction(funcName, resolvedArgs);
    }

    // 依赖模块的函数: @depName.funcName
    if (callTarget.startsWith('@') && callTarget.contains('.')) {
      final dotIndex = callTarget.indexOf('.');
      final depName = callTarget.substring(1, dotIndex);
      final funcName = callTarget.substring(dotIndex + 1);

      // 在依赖中查找函数
      final funcDef = _depLoader.findFunction(depName, funcName);
      if (funcDef != null) {
        return await _executeDependencyFunction(depName, funcDef, resolvedArgs);
      }
      debugPrint('[JSON DSL] 未找到依赖函数: $callTarget');
      return null;
    }

    // ──── 内置函数 ────
    switch (callTarget) {
      case '@print':
        final value = resolvedArgs['value'] ?? '';
        debugPrint('[JSON DSL] $value');
        return null;

      case '@set':
        final varPath = resolvedArgs['var'] as String?;
        // 关键区分：取原始 value 判断类型
        //   - 原始是 Map → jsonlogic 表达式，走 _evaluateExpression
        //   - 原始是 String "{{ }}" → _resolveArgs 已解析为最终值，直接用
        //   - 原始是其他（数字/布尔/数组等）→ 直接用
        final rawValue = args['value'];
        final dynamic finalValue;
        if (rawValue is Map<String, dynamic>) {
          // jsonlogic 表达式，需要求值
          finalValue = _evaluateExpression(rawValue);
        } else {
          // 模板或原始值，_resolveArgs 已处理完毕
          finalValue = resolvedArgs['value'];
        }
        if (varPath != null) {
          setVariable(varPath, finalValue);
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
        final ms =
            _toInt(resolvedArgs['ms'] ?? resolvedArgs['milliseconds'] ?? 0);
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
        final list = _evaluateExpression(resolvedArgs['value']);
        return list is List ? list.length : 0;
      case '@list_add':
        final listPath = resolvedArgs['var'] as String?;
        final item = _evaluateExpression(resolvedArgs['item']);
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
        final item = _evaluateExpression(resolvedArgs['item']);
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
        return _evaluateExpression(resolvedArgs['value'])?.toString() ?? '';
      case '@to_int':
        return _toInt(_evaluateExpression(resolvedArgs['value']));
      case '@to_double':
        return _toDouble(_evaluateExpression(resolvedArgs['value']));

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

  // ============ 控制流 ============

  Future<dynamic> _builtinIf(Map<String, dynamic> args) async {
    final condition = args['condition'];
    final thenSteps = args['then'] as List<dynamic>? ?? [];
    final elseSteps = args['else'] as List<dynamic>? ?? [];

    final condResult = _evaluateBool(condition);

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
    while (_evaluateBool(condition) && count < maxIterations) {
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

    dynamic source = _evaluateExpression(sourceExpr);
    if (source is! List) return null;

    for (var i = 0; i < source.length; i++) {
      _loopContextStack.add({'item': source[i], 'index': i});

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

  // ============ HTTP ============

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
    final body = _evaluateExpression(args['body']);
    final headers = _toStringMap(args['headers']);
    final contentType = args['content_type']?.toString() ?? 'application/json';
    return await _httpClient.post(url,
        body: body, headers: headers, contentType: contentType);
  }

  Future<Map<String, dynamic>> _builtinHttpPut(
      Map<String, dynamic> args) async {
    final url = args['url']?.toString() ?? '';
    final body = _evaluateExpression(args['body']);
    final headers = _toStringMap(args['headers']);
    return await _httpClient.put(url, body: body, headers: headers);
  }

  Future<Map<String, dynamic>> _builtinHttpDelete(
      Map<String, dynamic> args) async {
    final url = args['url']?.toString() ?? '';
    final headers = _toStringMap(args['headers']);
    return await _httpClient.delete(url, headers: headers);
  }

  // ============ JSON ============

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
    final value = _evaluateExpression(args['value']);
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

  // ============ 自定义函数 ============

  Future<dynamic> _executeGlobalFunction(
      String funcName, Map<String, dynamic> args) async {
    final funcDef = _functions[funcName] as Map<String, dynamic>?;
    if (funcDef == null) {
      debugPrint('[JSON DSL] 未找到函数: $funcName');
      return null;
    }
    return await _executeFunctionDef(funcDef, args);
  }

  /// 执行依赖模块中的函数
  Future<dynamic> _executeDependencyFunction(
      String depName, Map<String, dynamic> funcDef, Map<String, dynamic> args) async {
    return await _executeFunctionDef(funcDef, args);
  }

  /// 通用函数执行器
  Future<dynamic> _executeFunctionDef(
      Map<String, dynamic> funcDef, Map<String, dynamic> args) async {

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
          // resolveExpression: 整体 {{ path }} 返回原始类型，混合文本返回 String
          resolved[entry.key] = resolveExpression(str);
        } else {
          resolved[entry.key] = str;
        }
      } else {
        resolved[entry.key] = entry.value;
      }
    }
    return resolved;
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
