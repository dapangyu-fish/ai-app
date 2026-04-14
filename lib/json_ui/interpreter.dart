// JSON DSL v3.2 解释器
// 负责：
//   1. 解析 JSON 配置 → 维护全局 Context（variables, functions）
//   2. 执行 steps（业务逻辑入口）
//   3. 解析模板表达式 {{ $.global.xxx }}
//   4. 执行 action（call / navigate）
//   5. 支持双向绑定（bind 字段）
//   6. 支持 JsonLogic 表达式求值
//   7. 构建 Widget 树（递归调用 widget_builder）
import 'package:flutter/material.dart';
import 'widget_builder.dart';
import 'widgets/position_handler.dart';

class JsonInterpreter extends ChangeNotifier {
  /// 完整的 JSON 配置
  late Map<String, dynamic> _config;

  /// 全局变量存储
  late Map<String, dynamic> _variables;

  /// 全局函数定义
  late Map<String, dynamic> _functions;

  /// 当前屏幕 ID
  String _currentScreenId = '';

  /// UI 循环上下文栈（支持 $.loop.item / $.loop.index）
  final List<Map<String, dynamic>> _loopContextStack = [];

  /// JsonLogic filter 迭代变量栈（{ "var": "" } 使用此栈）
  final List<dynamic> _filterItemStack = [];

  /// 函数参数上下文栈（支持 $.params.xxx）
  final List<Map<String, dynamic>> _paramsStack = [];

  /// TextField 控制器缓存（按 bind path 缓存，避免重建）
  final Map<String, TextEditingController> _textControllers = {};

  /// 页面导航回调
  void Function(String screenId)? onNavigate;

  /// 获取所有 screens 定义
  List<dynamic> get screens =>
      (_config['ui'] as Map<String, dynamic>?)?['screens'] as List<dynamic>? ??
      [];

  /// 获取当前屏幕 ID
  String get currentScreenId => _currentScreenId;

  /// 获取应用名称
  String get appName =>
      (_config['meta'] as Map<String, dynamic>?)?['name'] ?? 'JSON App';

  // ---------- 初始化 ----------

  /// 加载 JSON 配置并初始化解释器
  void loadConfig(Map<String, dynamic> config) {
    _config = config;

    final global = config['global'] as Map<String, dynamic>? ?? {};
    _variables =
        _deepCopy(global['variables'] as Map<String, dynamic>? ?? {});
    _functions = global['functions'] as Map<String, dynamic>? ?? {};

    // 清除之前的状态
    _loopContextStack.clear();
    _filterItemStack.clear();
    _paramsStack.clear();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    _textControllers.clear();

    // 设置默认屏幕
    if (screens.isNotEmpty) {
      _currentScreenId =
          (screens.first as Map<String, dynamic>)['id'] ?? 'home';
    }
  }

  /// 执行启动 steps
  void executeSteps() {
    final steps = _config['steps'] as List<dynamic>? ?? [];
    for (final step in steps) {
      if (step is Map<String, dynamic>) {
        _executeStep(step);
      }
    }
  }

  // ---------- 变量读写 ----------

  /// 读取变量值（支持 $.global.xxx / $.loop.xxx / $.params.xxx）
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

    // $.global.xxx
    if (path.startsWith(r'$.global.')) {
      final key = path.substring(9);
      return _variables[key];
    }

    return null;
  }

  /// 设置变量值（支持 $.global.xxx 路径）
  void setVariable(String path, dynamic value) {
    if (path.startsWith(r'$.global.')) {
      final key = path.substring(9);
      _variables[key] = value;
      notifyListeners();
    }
  }

  // ---------- 模板解析 ----------

  /// 解析模板字符串，替换所有 {{ expression }} 占位符
  String resolveTemplate(String template) {
    final regex = RegExp(r'\{\{\s*(.+?)\s*\}\}');
    return template.replaceAllMapped(regex, (match) {
      final expression = match.group(1)!;
      final value = getVariable(expression);
      return value?.toString() ?? '';
    });
  }

  /// 解析表达式，返回原始值（不转字符串）
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

  // ---------- TextField 控制器管理 ----------

  /// 获取或创建 TextEditingController（按 bindPath 缓存）
  TextEditingController getTextController(
      String bindPath, String currentValue) {
    if (_textControllers.containsKey(bindPath)) {
      final controller = _textControllers[bindPath]!;
      // 如果变量值被外部修改（如 @set 清空），同步控制器
      if (controller.text != currentValue) {
        // 使用 addPostFrameCallback 避免在 build 期间修改
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

  // ---------- Action 执行 ----------

  /// 执行 action（按钮点击等交互触发）
  void executeAction(Map<String, dynamic> action, BuildContext context) {
    final type = action['type'] ?? 'call';

    switch (type) {
      case 'call':
        final callTarget = action['call'] as String?;
        final args = action['args'] as Map<String, dynamic>?;
        if (callTarget != null) {
          _executeCall(callTarget, args ?? {});
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

  /// 页面跳转
  void navigateTo(String screenId) {
    _currentScreenId = screenId;
    onNavigate?.call(screenId);
    notifyListeners();
  }

  // ---------- Steps / Call 执行 ----------

  /// 执行单个 step
  void _executeStep(Map<String, dynamic> step) {
    if (step.containsKey('call')) {
      final callTarget = step['call'] as String;
      final args = step['args'] as Map<String, dynamic>? ?? {};
      _executeCall(callTarget, args);
    }
  }

  /// 执行函数调用
  void _executeCall(String callTarget, Map<String, dynamic> args) {
    // 解析 args 中的模板
    final resolvedArgs = _resolveArgs(args);

    if (callTarget.startsWith('@global.')) {
      final funcName = callTarget.substring(8);
      _executeGlobalFunction(funcName, resolvedArgs);
    } else {
      // 内置函数
      switch (callTarget) {
        case '@print':
          final value = resolvedArgs['value'] ?? '';
          debugPrint('[JSON DSL] $value');
          break;
        case '@set':
          final varPath = resolvedArgs['var'] as String?;
          final value = resolvedArgs['value'];
          if (varPath != null) {
            final resolvedValue = _resolveJsonLogicValue(value);
            setVariable(varPath, resolvedValue);
          }
          break;
        case '@if':
          break;
        case '@while':
          break;
        case '@for_each':
          break;
      }
    }
  }

  /// 执行全局自定义函数
  void _executeGlobalFunction(
      String funcName, Map<String, dynamic> args) {
    final funcDef = _functions[funcName] as Map<String, dynamic>?;
    if (funcDef == null) {
      debugPrint('[JSON DSL] 未找到函数: $funcName');
      return;
    }

    // 压入参数上下文
    _paramsStack.add(args);

    // 执行函数逻辑
    final logic = funcDef['logic'] as List<dynamic>? ?? [];
    for (final step in logic) {
      if (step is Map<String, dynamic>) {
        _executeStep(step);
      }
    }

    // 弹出参数上下文
    _paramsStack.removeLast();
  }

  /// 解析参数中的模板表达式
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

  /// 解析 JsonLogic 风格的值表达式
  /// 支持 cat（数组拼接）、filter（过滤）、var（变量引用）
  dynamic _resolveJsonLogicValue(dynamic value) {
    if (value == null) return null;

    if (value is Map<String, dynamic>) {
      // cat 操作：数组拼接
      if (value.containsKey('cat')) {
        final parts = value['cat'] as List<dynamic>? ?? [];
        List<dynamic> result = [];
        for (final part in parts) {
          final resolved = _resolveJsonLogicValue(part);
          if (resolved is List) {
            result.addAll(resolved);
          } else if (resolved != null) {
            result.add(resolved);
          }
        }
        return result;
      }

      // var 操作：变量引用
      if (value.containsKey('var')) {
        final varPath = value['var'] as String;
        // { "var": "" } — 在 filter 上下文中表示当前迭代的元素
        if (varPath.isEmpty) {
          if (_filterItemStack.isNotEmpty) {
            return _filterItemStack.last;
          }
          if (_loopContextStack.isNotEmpty) {
            return _loopContextStack.last['item'];
          }
          return null;
        }
        return getVariable(varPath);
      }

      // filter 操作：数组过滤
      if (value.containsKey('filter')) {
        final filterArgs = value['filter'] as List<dynamic>? ?? [];
        if (filterArgs.length >= 2) {
          final sourceExpr = filterArgs[0];
          final conditionExpr = filterArgs[1];
          final source = _resolveJsonLogicValue(sourceExpr);
          if (source is List) {
            // 获取要删除的索引（从 params 传入）
            final indexParam = _paramsStack.isNotEmpty
                ? _paramsStack.last['index']
                : null;
            final deleteIndex = indexParam != null
                ? int.tryParse(indexParam.toString())
                : null;

            // 如果有索引参数，优先使用索引过滤（更可靠）
            if (deleteIndex != null) {
              return List<dynamic>.from(source)..removeAt(deleteIndex);
            }

            // 否则使用 JsonLogic 条件过滤
            return source.where((item) {
              _filterItemStack.add(item);
              final condResult = _evaluateCondition(conditionExpr);
              _filterItemStack.removeLast();
              return condResult;
            }).toList();
          }
        }
        return [];
      }

      // != 操作
      if (value.containsKey('!=')) {
        final operands = value['!='] as List<dynamic>? ?? [];
        if (operands.length >= 2) {
          final left = _resolveJsonLogicValue(operands[0]);
          final right = _resolveJsonLogicValue(operands[1]);
          return left != right;
        }
      }

      // == 操作
      if (value.containsKey('==')) {
        final operands = value['=='] as List<dynamic>? ?? [];
        if (operands.length >= 2) {
          final left = _resolveJsonLogicValue(operands[0]);
          final right = _resolveJsonLogicValue(operands[1]);
          return left == right;
        }
      }

      return value;
    }

    if (value is List) {
      return value.map((e) => _resolveJsonLogicValue(e)).toList();
    }

    // 字符串模板
    if (value is String && value.contains('{{')) {
      return resolveTemplate(value);
    }

    return value;
  }

  /// 求值条件表达式（用于 filter 等操作）
  bool _evaluateCondition(dynamic condition) {
    if (condition is Map<String, dynamic>) {
      if (condition.containsKey('!=')) {
        final operands = condition['!='] as List<dynamic>? ?? [];
        if (operands.length >= 2) {
          final left = _resolveJsonLogicValue(operands[0]);
          final right = _resolveJsonLogicValue(operands[1]);
          return left != right;
        }
      }
      if (condition.containsKey('==')) {
        final operands = condition['=='] as List<dynamic>? ?? [];
        if (operands.length >= 2) {
          final left = _resolveJsonLogicValue(operands[0]);
          final right = _resolveJsonLogicValue(operands[1]);
          return left == right;
        }
      }
    }
    if (condition is bool) return condition;
    return false;
  }

  // ---------- Widget 构建 ----------

  /// 构建单个 Widget（入口，包含 position 处理）
  Widget buildWidget(BuildContext context, Map<String, dynamic> json) {
    final widgetBuilder = JsonWidgetBuilder();
    final child = widgetBuilder.build(context, json, this);

    // 应用 position 定位
    final position = json['position'] as Map<String, dynamic>?;
    return applyPosition(child, position);
  }

  /// 在循环上下文中构建 Widget（用于 list 的 item_template）
  Widget buildWidgetInLoopContext({
    required BuildContext context,
    required Map<String, dynamic> json,
    required dynamic loopItem,
    required int loopIndex,
  }) {
    _loopContextStack.add({
      'item': loopItem,
      'index': loopIndex,
    });

    final widget = buildWidget(context, json);

    _loopContextStack.removeLast();

    return widget;
  }

  // ---------- 工具方法 ----------

  /// 深拷贝 Map
  Map<String, dynamic> _deepCopy(Map<String, dynamic> original) {
    final copy = <String, dynamic>{};
    for (final entry in original.entries) {
      if (entry.value is Map<String, dynamic>) {
        copy[entry.key] = _deepCopy(entry.value as Map<String, dynamic>);
      } else if (entry.value is List) {
        copy[entry.key] = List.from(entry.value as List);
      } else {
        copy[entry.key] = entry.value;
      }
    }
    return copy;
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
