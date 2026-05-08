// JSON DSL v3.2 解释器 — jsonlogic 标准版
// ───────────────────────────────────────────────
// 表达式引擎替换为 pub.dev/packages/jsonlogic (2.0.2)
// 自定义扩展操作符通过 jl.add() 注册
// 变量路径格式：global.xxx / loop.item / params.xxx（兼容 $.global.xxx 旧格式）
// ───────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:jsonlogic/jsonlogic.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:local_auth/local_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'http_client.dart';
import 'dependency_loader.dart';
import 'widget_builder.dart';
import 'widgets/position_handler.dart';
import '../auth/auth_service.dart';
import '../designer/app_storage.dart';
import '../im/im_service.dart';
import 'drift_database.dart';
import '../main.dart' show appThemeMode, appLifecycleEvent;
import '../i18n/locale_controller.dart' show LocaleController;

class JsonInterpreter extends ChangeNotifier {
  // ============ 配置 & 状态 ============

  late Map<String, dynamic> _config;
  late Map<String, dynamic> _variables;
  late Map<String, dynamic> _functions;
  String _currentScreenId = '';
  String _appId = 'default';

  final List<Map<String, dynamic>> _loopContextStack = [];
  final List<Map<String, dynamic>> _paramsStack = [];

  /// 事件作用域栈：给嵌入控件（如 flame_game）的回调注入临时数据。
  /// JSON 在 onXxx action 里可以用 `{{ event.foo }}` 拿到事件 payload。
  /// 跟 loop / params 一样的 push-execute-pop 语义，由 [executeActionWithEvent] 管。
  final List<Map<String, dynamic>> _eventContextStack = [];

  /// 当前挂着的 flame_game widget 注册的 reset 回调。
  /// 给 @flame_game_reset 这个 action 用 — JSON-APP 层（比如结算 dialog
  /// 的"再来一局"按钮）能从外面调进去重置游戏。
  final List<void Function()> _flameGameResetters = [];

  void registerFlameGameResetter(void Function() resetter) {
    _flameGameResetters.add(resetter);
  }

  void unregisterFlameGameResetter(void Function() resetter) {
    _flameGameResetters.remove(resetter);
  }

  /// 当前还活着的 modal route（dialog / bottom sheet / picker）数。
  /// _showXxxDialog 系列在 push 时 +1，await 完成时 -1。
  /// 给 [dismissAllModals] 用，退出 JSON-APP 前把残留 dialog 全 pop 掉。
  int _activeModalCount = 0;

  /// 把 interpreter push 过的、还没 dismiss 的 modal 全部 pop 掉。
  /// 典型用法：用户点 back action 退出 JSON-APP 时，先清理掉 dialog
  /// 再 pop screen route，避免 dialog 飘到主页面上。
  void dismissAllModals() {
    if (_activeModalCount <= 0) return;
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return;
    final nav = Navigator.of(ctx, rootNavigator: true);
    while (_activeModalCount > 0 && nav.canPop()) {
      nav.pop();
      _activeModalCount--;
    }
  }

  final Map<String, TextEditingController> _textControllers = {};

  /// 屏幕导航历史栈（不含当前页）。
  /// PopScope / Android 物理返回键 / iOS 边缘滑动 都会调 navigateBack 弹出栈顶。
  /// navigateTo 时把当前页推入；若目标已在栈中则弹到那一帧（防止历史无限增长）。
  final List<String> _navigationHistory = [];

  /// jsonlogic 标准引擎 + 自定义操作符
  late Jsonlogic _jl;

  final DslHttpClient _httpClient = DslHttpClient();

  /// 依赖加载器
  final DependencyLoader _depLoader = DependencyLoader();

  void Function(String screenId)? onNavigate;
  BuildContext? globalContext;

  // ============ Toast 重叠显示管理 ============
  final List<OverlayEntry> _activeToasts = [];
  static const int _maxOverlappingToasts = 20;

  // ============ IM 反应式订阅 ============
  // @im_subscribe_inbox 第一次被调用时挂上 IMService.newMessageStream 监听，
  // 整个 interpreter 生命周期复用同一个订阅，避免重入创建多个 listener。
  StreamSubscription<Message>? _imInboxSub;

  // ============ Getters ============

  List<dynamic> get screens =>
      (_config['ui'] as Map<String, dynamic>?)?['screens'] as List<dynamic>? ??
      [];

  String get currentScreenId => _currentScreenId;

  /// 原始 JSON 配置（用于崩溃分析时发给 AI）
  Map<String, dynamic>? get rawConfig => _config.isNotEmpty ? _config : null;

  String get appName =>
      (_config['meta'] as Map<String, dynamic>?)?['name'] ?? 'JSON App';

  /// 获取依赖加载器（供 ref 控件使用）
  DependencyLoader get depLoader => _depLoader;

  /// 全局运行时崩溃回调。框架在 [executeAction] / [executeActionWithResult] /
  /// [executeSteps] 抛异常时调用，由 main.dart 在 app 启动时注册并把崩溃路由到
  /// `_CrashPage`（带 AI 一键修复按钮）。
  ///
  /// 这条路径专门给"动作执行类异常"（按钮 onPressed、on_start steps 跑炸了）
  /// 兜底——它们和 widget build 异常不一样，不会触发 [JsonScreenView] 里的
  /// try/catch，老代码下要么静默 debugPrint，要么只在启动页显示一行红字，
  /// AI 修复按钮根本看不到。
  static void Function(Object error, StackTrace stack, String fileName)?
      onActionCrash;

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

  /// 正在求值中的 computed key，用于防递归（A→B→A 时第二次进入 A 直接 null）
  final Set<String> _computingNow = {};

  /// 每次求值前，将当前状态组装为 jsonlogic 的 data 参数
  /// global.computed.* 会被即时求值，作为 global 名空间下的"派生字段"暴露
  Map<String, dynamic> _buildDataContext() {
    Map<String, dynamic> globalView = _variables;
    final computed =
        (_config['global'] as Map<String, dynamic>?)?['computed'];
    if (computed is Map && computed.isNotEmpty) {
      // 只有真存在 computed 时才浅拷贝并注入，避免每次求值都付拷贝成本
      globalView = Map<String, dynamic>.from(_variables);
      for (final entry in computed.entries) {
        final key = entry.key.toString();
        // 真实变量同名时以真实变量为准（shadow）
        if (globalView.containsKey(key)) continue;
        if (_computingNow.contains(key)) continue;
        _computingNow.add(key);
        try {
          globalView[key] = _evaluateExpression(entry.value);
        } catch (_) {
          // 求值失败留 null，避免整个上下文构建失败
        } finally {
          _computingNow.remove(key);
        }
      }
    }
    return {
      'global': globalView,
      'loop': _loopContextStack.isNotEmpty ? _loopContextStack.last : {},
      'params': _paramsStack.isNotEmpty ? _paramsStack.last : {},
      'event': _eventContextStack.isNotEmpty ? _eventContextStack.last : {},
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

    // Map → 区分 JsonLogic 表达式 vs 普通数据 Map：
    //   - 单 key + key 在已知 jsonlogic operator 集合里 → 走 jsonlogic 求值
    //   - 其它（多 key、单 key 但 key 不是 op、空 Map）→ 当数据 Map，
    //     递归把内部值再 _evaluateExpression（保留模板/嵌套表达式都能展开）
    //
    // 这里曾经是无脑把所有 Map 都 jl.apply()，导致 AI 写
    //   @list_add args.item = {"id":..., "display":..., "bg":...}
    // 这种正常数据 Map 时，jsonlogic 把第一个 key 当 operator → "operator id not defined"
    // 崩溃。框架契约（CLAUDE.md §3）：合法 JSON 数据不能让框架崩。
    if (value is Map<String, dynamic>) {
      if (_looksLikeJsonLogic(value)) {
        final preprocessed = _resolveTemplatesInRule(value);
        return _jl.apply(preprocessed, _buildDataContext());
      }
      // 数据 Map：值再走一遍 evaluate，模板 / 嵌套 jsonlogic 都能正确展开
      final out = <String, dynamic>{};
      value.forEach((k, v) {
        out[k] = _evaluateExpression(v);
      });
      return out;
    }

    // List → 元素再走 evaluate（之前只处理字符串模板，这里改成全递归
    // 保持一致：List<Map> 里如果有数据 Map，里面的 {{ }} 现在也能解开）
    if (value is List) {
      return value.map(_evaluateExpression).toList();
    }

    return value;
  }

  /// 判断一个 Map 是否是 jsonlogic 表达式（而不是普通数据 Map）：
  /// 单 key 且 key 在已知 operator 白名单里。
  ///
  /// 标准 jsonlogic operator 由 `Jsonlogic()` 构造器内置，自定义的通过
  /// `_jl.add()` 注册。两份合在一起就是当前引擎认识的全部 op。
  static bool _looksLikeJsonLogic(Map<String, dynamic> m) {
    if (m.length != 1) return false;
    return _knownJsonLogicOps.contains(m.keys.first);
  }

  /// jsonlogic 标准 operator + 本文件 _createJsonLogic 里 jl.add 注册的自定义 op。
  /// 维护提示：在 _createJsonLogic 里加新的 jl.add('xxx', ...) 时，**记得把
  /// 'xxx' 加到这里**，否则该 op 写法会被当作数据 Map 不再触发 jsonlogic 求值。
  static const Set<String> _knownJsonLogicOps = {
    // 标准（来自 jsonlogic 包）
    'var', 'missing', 'missing_some',
    'if', '?:',
    'and', 'or', '!', '!!',
    '==', '!=', '===', '!==', '<', '<=', '>', '>=',
    '+', '-', '*', '/', '%',
    'min', 'max',
    'cat', 'substr', 'in',
    'map', 'filter', 'reduce', 'all', 'some', 'none', 'merge', 'method',
    'log',
    // 本文件自定义
    'str_len', 'str_upper', 'str_lower', 'str_trim', 'str_contains',
    'str_replace', 'str_split', 'str_join',
    'length', 'at', 'slice', 'sort', 'reverse',
    'to_string', 'to_int', 'to_double',
    'abs',
  };

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

    // 提取 appid，用于 Drift 数据库隔离
    _appId = config['appid']?.toString() ?? config['meta']?['name']?.toString() ?? 'default';

    final global = config['global'] as Map<String, dynamic>? ?? {};
    _variables =
        _deepCopy(global['variables'] as Map<String, dynamic>? ?? {});
    _functions = global['functions'] as Map<String, dynamic>? ?? {};

    _loopContextStack.clear();
    _paramsStack.clear();
    _eventContextStack.clear();
    _navigationHistory.clear();
    _depLoader.clear();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    _textControllers.clear();

    // 切 app 时清掉旧 IM 监听，避免老 app 的 inbox 还在写新 app 的 _variables
    _imInboxSub?.cancel();
    _imInboxSub = null;

    if (screens.isNotEmpty) {
      _currentScreenId =
          (screens.first as Map<String, dynamic>)['id'] ?? 'home';
    }

    // 单向同步：把当前框架 locale 一次性写到 global.locale。
    // 之后两边各自演化——框架切语言不会回头改 app；app 调 @set_locale 不会影响框架。
    // 只在 JSON-APP 没显式预设 locale 时才注入，保留 JSON 自己的优先级。
    if (!_variables.containsKey('locale')) {
      _variables['locale'] = _normalizeLocaleTag(
          LocaleController.currentLocaleTag());
    }

    // 注册生命周期 hook（resume/pause/...）
    _attachLifecycleListener();
  }

  /// 把 BCP 47 tag 简化成 JSON-APP 习惯用的语言代码（zh-CN → zh / en-US → en）。
  /// JSON-APP 的 i18n 字典通常用 'zh' / 'en' 作 key，简化后命中率更高。
  /// 如果 JSON-APP 想精细到 zh-TW / zh-HK，自己用完整 tag 也支持（_i18nLookup 会精确匹配）。
  String _normalizeLocaleTag(String tag) {
    final dash = tag.indexOf(RegExp(r'[-_]'));
    if (dash < 0) return tag;
    return tag.substring(0, dash);
  }

  Future<void> executeSteps() async {
    try {
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
    } catch (e, st) {
      // 启动期 steps 抛错：先调一遍崩溃回调（路由到 _CrashPage 显示 AI 修复按钮），
      // 再 rethrow 让外层 loadConfig 调用方自己也能感知（避免还推 JsonScreenView 进去）。
      onActionCrash?.call(e, st, appName);
      rethrow;
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

    if (path.startsWith('event.')) {
      final subPath = path.substring(6);
      if (_eventContextStack.isNotEmpty) {
        return _getNestedValue(_eventContextStack.last, subPath);
      }
      return null;
    }

    if (path.startsWith('global.')) {
      final subPath = path.substring(7);
      // 优先返回普通变量；普通变量没有时再看是否为 computed 派生值
      if (_hasNestedKey(_variables, subPath)) {
        return _getNestedValue(_variables, subPath);
      }
      final computedExpr = _findComputedExpr(subPath);
      if (computedExpr != null) {
        return _evaluateExpression(computedExpr);
      }
      return _getNestedValue(_variables, subPath);
    }

    // 没有前缀：先查 global 变量，再查依赖模块变量
    if (_hasNestedKey(_variables, path)) {
      return _getNestedValue(_variables, path);
    }

    // 尝试作为依赖变量: "depName.varPath"
    return _getDependencyVariable(path);
  }

  /// 在 global.computed 字典里查表达式（按 dot 路径匹配）
  /// 例: global.computed = { fullName: <expr> }, subPath="fullName" → 命中
  dynamic _findComputedExpr(String subPath) {
    final computed =
        (_config['global'] as Map<String, dynamic>?)?['computed'];
    if (computed is! Map) return null;
    if (computed[subPath] != null) return computed[subPath];
    // 也支持嵌套 dot 路径（极少需要，但成本几乎为零）
    return _getNestedValue(
        Map<String, dynamic>.from(computed), subPath);
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
      if (current is Map<String, dynamic>) {
        if (!current.containsKey(key)) return null;
        current = current[key];
      } else if (current is List) {
        // List 段：key 必须能解析为合法 int 下标
        // Map 分支放在前面，避免 Map 里恰好有一个 String 键名是数字时被误判成 List
        final idx = int.tryParse(key);
        if (idx == null || idx < 0 || idx >= current.length) return null;
        current = current[idx];
      } else {
        return null;
      }
    }
    return current;
  }

  bool _hasNestedKey(Map<String, dynamic> map, String dotPath) {
    final keys = dotPath.split('.');
    dynamic current = map;
    for (final key in keys) {
      if (current is Map<String, dynamic>) {
        if (!current.containsKey(key)) return false;
        current = current[key];
      } else if (current is List) {
        final idx = int.tryParse(key);
        if (idx == null || idx < 0 || idx >= current.length) return false;
        current = current[idx];
      } else {
        return false;
      }
    }
    return true;
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
      } else if (current is List) {
        // 走到 List 中段：只能按现有下标穿过，越界不会自动扩展（List 不像 Map 能 putIfAbsent）
        final idx = int.tryParse(keys[i]);
        if (idx == null || idx < 0 || idx >= current.length) return;
        current = current[idx];
      } else {
        return;
      }
    }
    final lastKey = keys.last;
    if (current is Map<String, dynamic>) {
      current[lastKey] = value;
    } else if (current is List) {
      // 末段 List 下标：原地 mutate（跟 @list_add 的"创建新 List 替换"模式不同，
      // 但 setVariable 上层的 notifyListeners 仍会触发整体重建，UI 能看到）
      final idx = int.tryParse(lastKey);
      if (idx != null && idx >= 0 && idx < current.length) {
        current[idx] = value;
      }
    }
  }

  // ============ 模板解析 ============

  String resolveTemplate(String template) {
    final regex = RegExp(r'\{\{\s*(.+?)\s*\}\}');
    return template.replaceAllMapped(regex, (match) {
      final expression = match.group(1)!;
      // loop / event 作用域没建立时保留模板原文，跟 resolveExpression 一致
      if ((expression.startsWith('loop.') && _loopContextStack.isEmpty) ||
          (expression.startsWith('event.') && _eventContextStack.isEmpty)) {
        return match.group(0)!;
      }
      final value = _resolveTemplateExpression(expression);
      return _stringifyForTemplate(value);
    });
  }

  /// 把任意值字符串化用于模板插值。
  ///
  /// 关键：**整数值的 double 不带 ".0"**。
  ///
  /// 为什么必要：jsonlogic 2.0.2 的 `+` / `*` 算子累加器初值是 `0.0` / `1.0`，
  /// 任何 `int + int` / `int * int` 都自动升级成 double。AI 写
  ///   `_i = _i + 1`        → _i 变成 1.0
  ///   `"global.board.{{ _i }}"` → "global.board.1.0"
  /// 然后 jsonlogic var op 按 "." 切成 4 段去走数据，到 List 那一步只能访问
  /// 一层下标，剩下的 ".0" 走不下去 → 返回 null → findMatches 用 null==null
  /// 误判到处是 match、removeMatches 写路径全断 → 整个 List 索引模型崩盘。
  ///
  /// 把 1.0 显示成 "1" 同时也让 UI 友好（"Score: 100" 而不是 "Score: 100.0"）。
  static String _stringifyForTemplate(dynamic value) {
    if (value == null) return '';
    if (value is double && value.isFinite && value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  /// 解析模板内表达式：
  ///   - `t('key.path')` / `t("key.path")` → i18n 字典查找
  ///   - 其他 → 走 getVariable
  dynamic _resolveTemplateExpression(String expr) {
    final trimmed = expr.trim();
    // 形如 t('home.title') 或 t("home.title")
    final tMatch =
        RegExp(r'''^t\(\s*['"](.+?)['"]\s*\)$''').firstMatch(trimmed);
    if (tMatch != null) {
      return _i18nLookup(tMatch.group(1)!);
    }
    return getVariable(trimmed);
  }

  /// i18n 嵌套模板解析最大深度。一个 t('A') 命中的字符串里再写 {{ t('B') }}
  /// 是常见用法（句式 / 单位词跨语言）；万一翻译者写了循环引用，这里截断保命。
  static const int _maxI18nDepth = 6;
  int _i18nDepth = 0;

  /// i18n 字典查找：global.i18n[locale][key.path]
  /// locale 取自 global.locale；找不到回退当前 key 本身（方便快速调试）
  ///
  /// 翻译值里允许嵌 `{{ ... }}` 模板（变量 / 嵌套 t()），命中后会再次跑
  /// resolveTemplate 把内部插值解开。这是 i18n 的标准用法 —— 比如英文
  /// "You have {{ global.count }} messages" / 中文 "你有 {{ global.count }} 条消息"，
  /// 翻译者控制变量在句子里的位置，不能强制把字符串切碎让调用方拼。
  String _i18nLookup(String keyPath) {
    final locale = (_variables['locale'] ??
            (_config['global'] as Map<String, dynamic>?)?['locale'] ??
            'zh')
        .toString();
    final dict =
        (_config['global'] as Map<String, dynamic>?)?['i18n'] as Map?;
    if (dict == null) return keyPath;
    final localeDict = dict[locale];
    if (localeDict is! Map) return keyPath;
    final raw = _getNestedValue(
        Map<String, dynamic>.from(localeDict), keyPath);
    final value = raw?.toString() ?? keyPath;
    // 翻译值里没模板：原样返回（绝大多数情况）
    if (!value.contains('{{') || !value.contains('}}')) return value;
    // 含模板：再过一次 resolveTemplate，最深递归 _maxI18nDepth 层
    if (_i18nDepth >= _maxI18nDepth) return value;
    _i18nDepth++;
    try {
      return resolveTemplate(value);
    } finally {
      _i18nDepth--;
    }
  }

  /// 解析表达式，返回原始值（{{ path }} 返回实际类型，非字符串化）
  dynamic resolveExpression(dynamic raw) {
    if (raw is String) {
      final regex = RegExp(r'^\{\{\s*(.+?)\s*\}\}$');
      final match = regex.firstMatch(raw);
      if (match != null) {
        final path = match.group(1)!;
        // 如果引用的是当前没建立的作用域（loop/event），保留模板原文，
        // 留到真正渲染时（list 给每项建好 loop 上下文 / 事件触发后）
        // 再解析。否则会被提前烤成 null，比如 widget JSON 通过函数参数
        // 传给 helper 时，里面的 {{ loop.item.x }} 在 _resolveArgs 阶段
        // 没 loop 上下文 → 直接变 null → 列表项渲染全空。
        if ((path.startsWith('loop.') && _loopContextStack.isEmpty) ||
            (path.startsWith('event.') && _eventContextStack.isEmpty)) {
          return raw;
        }
        return getVariable(path);
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
    try {
      final type = action['type'] ?? 'call';

      switch (type) {
        case 'call':
          final callTarget = action['call'] as String?;
          final args = action['args'] as Map<String, dynamic>?;
          final assignVar = action['assign'] as String?;
          if (callTarget != null) {
            final result = await _executeCall(callTarget, args ?? {});
            if (assignVar != null && result != null) {
              setVariable(assignVar, result);
            }
          }
          break;
        case 'navigate':
          final screenId = action['screen'] as String?;
          if (screenId != null) {
            navigateTo(screenId);
          }
          break;
        case 'back':
          // 弹出导航历史回到上一屏；栈空则尝试 pop 外层 Route（退出 JSON-APP）
          if (canNavigateBack) {
            navigateBack();
          } else if (context.mounted) {
            // 退出 JSON-APP 前先把还挂着的 dialog 全 pop 掉，
            // 避免它们飘到主页面上
            dismissAllModals();
            Navigator.of(context).maybePop();
          }
          break;
      }
    } catch (e, st) {
      // 按钮 onPressed 等事件回调里抛错没人接，老代码会被 dart 框架直接吞掉
      // / 走默认 onError。这里兜底路由到 _CrashPage（带 AI 一键修复按钮）。
      onActionCrash?.call(e, st, appName);
    }
  }

  /// 跟 [executeAction] 一样跑 action，但先把 [eventData] 推到 event 栈，
  /// 让 action 体里 `{{ event.xxx }}` 模板能拿到值。
  /// 用于嵌入控件（flame_game / 未来可能的 webview message 等）回调。
  Future<void> executeActionWithEvent(
    Map<String, dynamic> action,
    BuildContext context,
    Map<String, dynamic> eventData,
  ) async {
    _eventContextStack.add(eventData);
    try {
      await executeAction(action, context);
    } finally {
      _eventContextStack.removeLast();
    }
  }

  /// 与 executeAction 相同，但返回函数调用的返回值
  /// 主要供需要决策结果的回调使用（如 dismissible.confirmAction）
  Future<dynamic> executeActionWithResult(
      dynamic action, BuildContext context) async {
    if (action is! Map<String, dynamic>) return null;
    try {
      final type = action['type'] ?? 'call';
      if (type == 'call') {
        final callTarget = action['call'] as String?;
        final args = action['args'] as Map<String, dynamic>?;
        final assignVar = action['assign'] as String?;
        if (callTarget != null) {
          final result = await _executeCall(callTarget, args ?? {});
          if (assignVar != null && result != null) {
            setVariable(assignVar, result);
          }
          return result;
        }
      } else if (type == 'navigate') {
        final screenId = action['screen'] as String?;
        if (screenId != null) navigateTo(screenId);
      }
      return null;
    } catch (e, st) {
      onActionCrash?.call(e, st, appName);
      return null;
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

    // 维护导航历史栈：
    // - 目标页已在历史中（用户在做"回退式跳转"，例如点 home 链接）
    //   → 弹到那一帧，避免历史无限增长
    // - 否则普通前进：把当前页推入历史
    final lastIdx = _navigationHistory.lastIndexOf(screenId);
    if (lastIdx >= 0) {
      _navigationHistory.removeRange(lastIdx, _navigationHistory.length);
    } else if (_currentScreenId.isNotEmpty && _currentScreenId != screenId) {
      _navigationHistory.add(_currentScreenId);
    }

    _currentScreenId = screenId;
    onNavigate?.call(screenId);
    notifyListeners();
  }

  /// 是否能回退到上一屏（历史栈非空）
  bool get canNavigateBack => _navigationHistory.isNotEmpty;

  /// 弹出历史栈，回到上一屏。栈空时无操作（调用方应自行决定是否退出 app）。
  void navigateBack() {
    if (_navigationHistory.isEmpty) return;
    _currentScreenId = _navigationHistory.removeLast();
    onNavigate?.call(_currentScreenId);
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
        return await _builtinIf(args);
      case '@while':
        return await _builtinWhile(args);
      case '@for_each':
        return await _builtinForEach(args);
      case '@loop_by_num':
        return await _builtinLoopByNum(args);
      case '@try_catch':
        return await _builtinTryCatch(args);
      case '@parallel':
        return await _builtinParallel(args);
      case '@delay':
        final ms =
            _toInt(resolvedArgs['ms'] ?? resolvedArgs['milliseconds'] ?? 0);
        await Future.delayed(Duration(milliseconds: ms));
        return null;
      case '@throw':
        // 主动抛错——用于测试 @try_catch / 业务侧主动失败
        throw Exception(
            resolvedArgs['message']?.toString() ?? 'thrown by @throw');

      // ── 系统 / 平台原生 ──
      case '@clipboard_copy':
        final text = resolvedArgs['text']?.toString() ?? '';
        await Clipboard.setData(ClipboardData(text: text));
        return null;
      case '@clipboard_paste':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return data?.text ?? '';
      case '@flame_game_reset':
        // 重置当前挂着的所有 flame_game。一般一个屏幕一个，所以列表
        // 通常长度为 1。给 JSON-APP 层（比如结算 dialog 的"再来一局"
        // 按钮）从外面重置游戏用。
        for (final r in _flameGameResetters) {
          r();
        }
        return null;
      case '@haptic':
        // style: light / medium / heavy / selection / vibrate（默认 light）
        final style = resolvedArgs['style']?.toString() ?? 'light';
        switch (style) {
          case 'medium':
            await HapticFeedback.mediumImpact();
            break;
          case 'heavy':
            await HapticFeedback.heavyImpact();
            break;
          case 'selection':
            await HapticFeedback.selectionClick();
            break;
          case 'vibrate':
            await HapticFeedback.vibrate();
            break;
          case 'light':
          default:
            await HapticFeedback.lightImpact();
            break;
        }
        return null;
      case '@launch_url':
        // 打开外链：https / tel: / mailto: / sms: / 自定义 scheme
        // mode: external (默认，跳系统浏览器) / inAppBrowserView (iOS Safari / Android Custom Tabs) / inAppWebView (嵌入)
        final url = resolvedArgs['url']?.toString() ?? '';
        if (url.isEmpty) return false;
        final uri = Uri.tryParse(url);
        if (uri == null) return false;
        final modeStr = resolvedArgs['mode']?.toString() ?? 'external';
        final mode = switch (modeStr) {
          'inAppBrowserView' => LaunchMode.inAppBrowserView,
          'inAppWebView' => LaunchMode.inAppWebView,
          _ => LaunchMode.externalApplication,
        };
        try {
          return await launchUrl(uri, mode: mode);
        } catch (_) {
          return false;
        }
      case '@share':
        // text: 必填——分享的文本（可以包含 URL）
        // subject: 可选——邮件主题等
        // files: 可选——本地文件路径列表（图片 / 文档）
        final text = resolvedArgs['text']?.toString() ?? '';
        final subject = resolvedArgs['subject']?.toString();
        final filesArg = resolvedArgs['files'];
        if (filesArg is List && filesArg.isNotEmpty) {
          final paths = filesArg.map((e) => e.toString()).toList();
          await Share.shareXFiles(
            paths.map((p) => XFile(p)).toList(),
            text: text.isEmpty ? null : text,
            subject: subject,
          );
        } else if (text.isNotEmpty) {
          await Share.share(text, subject: subject);
        }
        return null;
      case '@request_permission':
        // type: camera / microphone / photos / location / locationWhenInUse /
        //       contacts / calendar / notification / storage / bluetooth
        // 返回 status string: granted / denied / restricted / permanentlyDenied / limited
        final type = resolvedArgs['type']?.toString() ?? '';
        final perm = _parsePermission(type);
        if (perm == null) return 'denied';
        final status = await perm.request();
        return _permissionStatusToString(status);
      case '@permission_status':
        final type = resolvedArgs['type']?.toString() ?? '';
        final perm = _parsePermission(type);
        if (perm == null) return 'denied';
        final status = await perm.status;
        return _permissionStatusToString(status);
      case '@open_app_settings':
        // 用户拒绝过权限后跳系统设置
        await openAppSettings();
        return null;
      case '@set_locale':
        // value: locale 字符串（如 'zh' / 'en'）；写入 global.locale，触发 UI 重建
        final localeStr = resolvedArgs['value']?.toString() ??
            resolvedArgs['locale']?.toString() ??
            'zh';
        setVariable('global.locale', localeStr);
        return null;
      case '@get_locale':
        return (_variables['locale'] ??
                (_config['global'] as Map<String, dynamic>?)?['locale'] ??
                'zh')
            .toString();
      case '@set_theme':
        // mode: light / dark / system
        final mode = resolvedArgs['mode']?.toString() ?? 'system';
        appThemeMode.value = switch (mode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
        return null;
      case '@get_theme':
        // 返回当前 mode（system 时返回 'system'，由调用方再决定怎么显示当前实际亮度）
        return switch (appThemeMode.value) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        };
      case '@biometric_auth':
        // reason: 必填——告诉用户为什么要验证（系统弹窗里的文案）
        // 返回 bool：通过 / 失败
        final reason = resolvedArgs['reason']?.toString() ?? '请验证身份';
        try {
          final auth = LocalAuthentication();
          final canCheck = await auth.canCheckBiometrics ||
              await auth.isDeviceSupported();
          if (!canCheck) return false;
          return await auth.authenticate(
            localizedReason: reason,
            options: const AuthenticationOptions(
              biometricOnly: false, // 允许 fallback 到 PIN / 密码
              stickyAuth: true,
            ),
          );
        } catch (_) {
          return false;
        }

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
      case '@list_remove':
        final listPath = resolvedArgs['var'] as String?;
        final value = _evaluateExpression(resolvedArgs['value']);
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final newList = List<dynamic>.from(current)
              ..removeWhere((e) => e == value);
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

      case '@show_input_dialog':
        final title = resolvedArgs['title']?.toString() ?? '输入';
        final hint = resolvedArgs['hint']?.toString() ?? '';
        final defaultValue = resolvedArgs['defaultValue']?.toString() ?? '';
        final bindPath = resolvedArgs['bind'] as String?;
        final result = await _showTextInputDialog(title, hint, defaultValue);
        if (bindPath != null) {
          setVariable(bindPath, result);
        }
        return result;

      case '@show_choice_dialog':
        // 自定义按钮对话框
        // args: { title, message, buttons: [{label, value, style?}], dismissible? }
        // 返回值：被点击按钮的 value（dismiss 关闭返回 null）
        final choiceTitle = resolvedArgs['title']?.toString() ?? '';
        final choiceMessage = resolvedArgs['message']?.toString() ?? '';
        final rawButtons = resolvedArgs['buttons'];
        final dismissible = resolvedArgs['dismissible'] != false;
        return await _showChoiceDialog(
          choiceTitle,
          choiceMessage,
          rawButtons is List ? rawButtons : const [],
          dismissible: dismissible,
        );

      case '@show_snackbar':
        // 增强版 toast：带操作按钮的底部 SnackBar
        // args: { message, actionLabel?, action?, durationMs?, backgroundColor? }
        final snackMsg = resolvedArgs['message']?.toString() ?? '';
        final actionLabel = resolvedArgs['actionLabel']?.toString();
        final actionDef = resolvedArgs['action'];
        final durationMs = (resolvedArgs['durationMs'] as num?)?.toInt() ?? 3000;
        final bgColorStr = resolvedArgs['backgroundColor']?.toString();
        _showSnackBar(
          snackMsg,
          actionLabel: actionLabel,
          actionDef: actionDef,
          durationMs: durationMs,
          backgroundColor: _parseColorHex(bgColorStr),
        );
        return null;

      case '@show_date_picker':
        // 命令式日期选择器
        // args: { initial?, firstDate?, lastDate?, bind? }
        // 返回值：yyyy-MM-dd 字符串（取消返回 null）
        return await _showDatePickerImperative(resolvedArgs);

      case '@show_time_picker':
        // 命令式时间选择器
        // args: { initial?, bind? }
        // 返回值：HH:mm 字符串（取消返回 null）
        return await _showTimePickerImperative(resolvedArgs);

      case '@show_bottom_sheet':
        // 底部弹窗
        // args: { content: { ...widget... }, isDismissible?, enableDrag?, backgroundColor? }
        // 返回值：弹窗里 close action 透传的值（关闭返回 null）
        return await _showBottomSheet(resolvedArgs);

      // ── 本地存储 ──
      case '@storage_set':
        final key = resolvedArgs['key']?.toString();
        final value = resolvedArgs['value'];
        if (key != null) {
          final prefs = await SharedPreferences.getInstance();
          if (value is bool) {
            await prefs.setBool(key, value);
          } else if (value is int) {
            await prefs.setInt(key, value);
          } else if (value is double) {
            await prefs.setDouble(key, value);
          } else if (value is List) {
            await prefs.setStringList(
                key, value.map((e) => e.toString()).toList());
          } else {
            await prefs.setString(key, value?.toString() ?? '');
          }
        }
        return null;
      case '@storage_get':
        final key = resolvedArgs['key']?.toString();
        if (key != null) {
          final prefs = await SharedPreferences.getInstance();
          return prefs.get(key);
        }
        return null;
      case '@storage_remove':
        final key = resolvedArgs['key']?.toString();
        if (key != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(key);
        }
        return null;
      case '@storage_clear':
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
        return null;

      // ── 文件持久化 ──
      // 所有文件操作都基于应用文档目录（getApplicationDocumentsDirectory），
      // path 参数是相对路径，如 "diary/entries.json"
      case '@file_write_json':
        try {
          final relPath = resolvedArgs['path']?.toString();
          final data = resolvedArgs['data'];
          if (relPath == null || data == null) return false;
          final dir = await _getAppDocDir();
          final file = File('${dir.path}/$relPath');
          await file.parent.create(recursive: true);
          final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
          await file.writeAsString(jsonStr, flush: true);
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] @file_write_json error: $e');
          return false;
        }

      case '@file_read_json':
        try {
          final relPath = resolvedArgs['path']?.toString();
          if (relPath == null) return null;
          final dir = await _getAppDocDir();
          final file = File('${dir.path}/$relPath');
          if (!await file.exists()) return resolvedArgs['default'];
          final content = await file.readAsString();
          return json.decode(content);
        } catch (e) {
          debugPrint('[JSON DSL] @file_read_json error: $e');
          return resolvedArgs['default'];
        }

      case '@file_exists':
        try {
          final relPath = resolvedArgs['path']?.toString();
          if (relPath == null) return false;
          final dir = await _getAppDocDir();
          final file = File('${dir.path}/$relPath');
          return await file.exists();
        } catch (e) {
          return false;
        }

      case '@file_delete':
        try {
          final relPath = resolvedArgs['path']?.toString();
          if (relPath == null) return false;
          final dir = await _getAppDocDir();
          final file = File('${dir.path}/$relPath');
          if (await file.exists()) {
            await file.delete();
            return true;
          }
          return false;
        } catch (e) {
          debugPrint('[JSON DSL] @file_delete error: $e');
          return false;
        }

      case '@file_list':
        try {
          final relDir = resolvedArgs['path']?.toString() ?? '';
          final dir = await _getAppDocDir();
          final targetDir = Directory('${dir.path}/$relDir');
          if (!await targetDir.exists()) return <String>[];
          final entities = await targetDir.list().toList();
          return entities
              .whereType<File>()
              .map((f) => f.path.split('/').last)
              .toList();
        } catch (e) {
          debugPrint('[JSON DSL] @file_list error: $e');
          return <String>[];
        }

      case '@file_append_json':
        // 追加一条记录到 JSON 数组文件（原子性：读→追加→写）
        try {
          final relPath = resolvedArgs['path']?.toString();
          final item = resolvedArgs['item'];
          if (relPath == null || item == null) return false;
          final dir = await _getAppDocDir();
          final file = File('${dir.path}/$relPath');
          List<dynamic> list = [];
          if (await file.exists()) {
            final content = await file.readAsString();
            final decoded = json.decode(content);
            if (decoded is List) list = decoded;
          }
          list.add(item);
          await file.parent.create(recursive: true);
          final jsonStr = const JsonEncoder.withIndent('  ').convert(list);
          await file.writeAsString(jsonStr, flush: true);
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] @file_append_json error: $e');
          return false;
        }

      case '@file_remove_json_item':
        // 从 JSON 数组文件中按字段匹配删除一条记录
        try {
          final relPath = resolvedArgs['path']?.toString();
          final matchField = resolvedArgs['field']?.toString();
          final matchValue = resolvedArgs['value'];
          if (relPath == null || matchField == null) return false;
          final dir = await _getAppDocDir();
          final file = File('${dir.path}/$relPath');
          if (!await file.exists()) return false;
          final content = await file.readAsString();
          final decoded = json.decode(content);
          if (decoded is! List) return false;
          final newList = decoded.where((item) {
            if (item is Map) {
              return item[matchField]?.toString() != matchValue?.toString();
            }
            return true;
          }).toList();
          final jsonStr = const JsonEncoder.withIndent('  ').convert(newList);
          await file.writeAsString(jsonStr, flush: true);
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] @file_remove_json_item error: $e');
          return false;
        }

      case '@file_update_json_item':
        // 从 JSON 数组文件中按字段匹配更新一条记录
        try {
          final relPath = resolvedArgs['path']?.toString();
          final matchField = resolvedArgs['field']?.toString();
          final matchValue = resolvedArgs['value'];
          final updates = resolvedArgs['updates'];
          if (relPath == null || matchField == null || updates is! Map) return false;
          final dir = await _getAppDocDir();
          final file = File('${dir.path}/$relPath');
          if (!await file.exists()) return false;
          final content = await file.readAsString();
          final decoded = json.decode(content);
          if (decoded is! List) return false;
          bool found = false;
          for (int i = 0; i < decoded.length; i++) {
            if (decoded[i] is Map && decoded[i][matchField]?.toString() == matchValue?.toString()) {
              for (final entry in updates.entries) {
                decoded[i][entry.key] = entry.value;
              }
              found = true;
              break;
            }
          }
          if (!found) return false;
          final jsonStr = const JsonEncoder.withIndent('  ').convert(decoded);
          await file.writeAsString(jsonStr, flush: true);
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] @file_update_json_item error: $e');
          return false;
        }

      // ── Drift 数据库 ──
      case '@db_create_table':
        try {
          final table = resolvedArgs['table']?.toString();
          final columns = resolvedArgs['columns'];
          if (table == null || columns is! List) return false;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          final colList = columns.map((c) => Map<String, String>.from(
            (c as Map).map((k, v) => MapEntry(k.toString(), v.toString()))
          )).toList();
          await db.ensureTable(table, colList);
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] @db_create_table error: $e');
          return false;
        }

      case '@db_insert':
        try {
          final table = resolvedArgs['table']?.toString();
          final data = resolvedArgs['data'];
          if (table == null || data is! Map) return -1;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          return await db.insertRow(table, Map<String, dynamic>.from(data));
        } catch (e) {
          debugPrint('[JSON DSL] @db_insert error: $e');
          return -1;
        }

      case '@db_query':
        try {
          final table = resolvedArgs['table']?.toString();
          if (table == null) return <Map<String, dynamic>>[];
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          final where = resolvedArgs['where']?.toString();
          final whereArgs = resolvedArgs['whereArgs'] is List
              ? (resolvedArgs['whereArgs'] as List).cast<dynamic>()
              : null;
          final orderBy = resolvedArgs['orderBy']?.toString();
          final limit = resolvedArgs['limit'] != null ? _toInt(resolvedArgs['limit']!) : null;
          final offset = resolvedArgs['offset'] != null ? _toInt(resolvedArgs['offset']!) : null;
          return await db.queryRows(table,
            where: where,
            whereArgs: whereArgs,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
          );
        } catch (e) {
          debugPrint('[JSON DSL] @db_query error: $e');
          return <Map<String, dynamic>>[];
        }

      case '@db_update':
        try {
          final table = resolvedArgs['table']?.toString();
          final data = resolvedArgs['data'];
          final where = resolvedArgs['where']?.toString();
          if (table == null || data is! Map || where == null) return 0;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          final whereArgs = resolvedArgs['whereArgs'] is List
              ? (resolvedArgs['whereArgs'] as List).cast<dynamic>()
              : null;
          return await db.updateRows(table, Map<String, dynamic>.from(data),
            where: where,
            whereArgs: whereArgs,
          );
        } catch (e) {
          debugPrint('[JSON DSL] @db_update error: $e');
          return 0;
        }

      case '@db_delete':
        try {
          final table = resolvedArgs['table']?.toString();
          final where = resolvedArgs['where']?.toString();
          if (table == null || where == null) return 0;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          final whereArgs = resolvedArgs['whereArgs'] is List
              ? (resolvedArgs['whereArgs'] as List).cast<dynamic>()
              : null;
          return await db.deleteRows(table, where: where, whereArgs: whereArgs);
        } catch (e) {
          debugPrint('[JSON DSL] @db_delete error: $e');
          return 0;
        }

      case '@db_count':
        try {
          final table = resolvedArgs['table']?.toString();
          if (table == null) return 0;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          final where = resolvedArgs['where']?.toString();
          final whereArgs = resolvedArgs['whereArgs'] is List
              ? (resolvedArgs['whereArgs'] as List).cast<dynamic>()
              : null;
          return await db.countRows(table, where: where, whereArgs: whereArgs);
        } catch (e) {
          debugPrint('[JSON DSL] @db_count error: $e');
          return 0;
        }

      case '@db_kv_set':
        try {
          final key = resolvedArgs['key']?.toString();
          final value = resolvedArgs['value'];
          if (key == null) return false;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          await db.kvSet(key, value);
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] @db_kv_set error: $e');
          return false;
        }

      case '@db_kv_get':
        try {
          final key = resolvedArgs['key']?.toString();
          if (key == null) return null;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          return await db.kvGet(key);
        } catch (e) {
          debugPrint('[JSON DSL] @db_kv_get error: $e');
          return null;
        }

      case '@db_kv_delete':
        try {
          final key = resolvedArgs['key']?.toString();
          if (key == null) return false;
          final db = DriftDatabaseManager.instance.getDatabase(_appId);
          await db.kvDelete(key);
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] @db_kv_delete error: $e');
          return false;
        }

      // ── 随机数 ──
      case '@random':
        final min = _toInt(resolvedArgs['min'] ?? 0);
        final max = _toInt(resolvedArgs['max'] ?? 100);
        if (min >= max) return min;
        return min + Random().nextInt(max - min + 1);

      case '@random_float':
        final min = _toDouble(resolvedArgs['min'] ?? 0.0);
        final max = _toDouble(resolvedArgs['max'] ?? 1.0);
        return min + Random().nextDouble() * (max - min);

      case '@random_bool':
        return Random().nextBool();

      case '@random_chars':
        final length = _toInt(resolvedArgs['length'] ?? 8);
        final charset = resolvedArgs['charset']?.toString() ?? 'alphanumeric';
        final buffer = StringBuffer();
        String chars;
        switch (charset) {
          case 'numeric':
            chars = '0123456789';
            break;
          case 'alpha':
            chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
            break;
          case 'upper':
            chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
            break;
          case 'lower':
            chars = 'abcdefghijklmnopqrstuvwxyz';
            break;
          case 'hex':
            chars = '0123456789abcdef';
            break;
          case 'alphanumeric':
          default:
            chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
            break;
        }
        for (var i = 0; i < length; i++) {
          buffer.write(chars[Random().nextInt(chars.length)]);
        }
        return buffer.toString();

      case '@uuid':
        final random = Random();
        final bytes = List<int>.generate(16, (_) => random.nextInt(256));
        bytes[6] = (bytes[6] & 0x0F) | 0x40;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;
        final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
        return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';

      case '@random_pick':
        final list = _evaluateExpression(resolvedArgs['list']);
        if (list is List && list.isNotEmpty) {
          return list[Random().nextInt(list.length)];
        }
        return null;

      // ── 时间日期 ──
      case '@timestamp':
        return DateTime.now().millisecondsSinceEpoch;

      case '@date_format':
        final ts = resolvedArgs['timestamp'];
        final format = resolvedArgs['format']?.toString() ?? 'YYYY-MM-DD HH:mm:ss';
        DateTime dt;
        if (ts is int) {
          dt = DateTime.fromMillisecondsSinceEpoch(ts);
        } else if (ts is double) {
          dt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
        } else {
          dt = DateTime.now();
        }
        var result = format;
        result = result.replaceAll('YYYY', dt.year.toString());
        result = result.replaceAll('MM', dt.month.toString().padLeft(2, '0'));
        result = result.replaceAll('DD', dt.day.toString().padLeft(2, '0'));
        result = result.replaceAll('HH', dt.hour.toString().padLeft(2, '0'));
        result = result.replaceAll('mm', dt.minute.toString().padLeft(2, '0'));
        result = result.replaceAll('ss', dt.second.toString().padLeft(2, '0'));
        return result;

      // ── 字符串扩展 ──
      case '@str_repeat':
        final str = resolvedArgs['value']?.toString() ?? '';
        final count = _toInt(resolvedArgs['count'] ?? 0);
        return str * count;

      case '@str_reverse':
        return (resolvedArgs['value']?.toString() ?? '').split('').reversed.join();

      case '@str_pad':
        final str = resolvedArgs['value']?.toString() ?? '';
        final targetLength = _toInt(resolvedArgs['length'] ?? 0);
        final padStr = resolvedArgs['pad']?.toString() ?? ' ';
        final direction = resolvedArgs['direction']?.toString() ?? 'right';
        if (str.length >= targetLength) return str;
        final padCount = targetLength - str.length;
        final padding = (padStr * ((padCount / padStr.length).ceil())).substring(0, padCount);
        return direction == 'left' ? '$padding$str' : '$str$padding';

      case '@str_join':
        final list = _evaluateExpression(resolvedArgs['list']);
        final separator = resolvedArgs['separator']?.toString() ?? '';
        if (list is List) {
          return list.map((e) => e?.toString() ?? '').join(separator);
        }
        return list?.toString() ?? '';

      case '@str_capitalize':
        final str = resolvedArgs['value']?.toString() ?? '';
        if (str.isEmpty) return str;
        return str[0].toUpperCase() + str.substring(1);

      case '@str_count':
        final str = resolvedArgs['value']?.toString() ?? '';
        final search = resolvedArgs['search']?.toString() ?? '';
        if (search.isEmpty) return 0;
        return search.allMatches(str).length;

      case '@str_index_of':
        final str = resolvedArgs['value']?.toString() ?? '';
        final search = resolvedArgs['search']?.toString() ?? '';
        return str.indexOf(search);

      case '@str_last_index_of':
        final str = resolvedArgs['value']?.toString() ?? '';
        final search = resolvedArgs['search']?.toString() ?? '';
        return str.lastIndexOf(search);

      case '@str_between':
        final str = resolvedArgs['value']?.toString() ?? '';
        final start = resolvedArgs['start']?.toString() ?? '';
        final end = resolvedArgs['end']?.toString() ?? '';
        final startIndex = str.indexOf(start);
        if (startIndex < 0) return '';
        final afterStart = str.substring(startIndex + start.length);
        final endIndex = afterStart.indexOf(end);
        if (endIndex < 0) return afterStart;
        return afterStart.substring(0, endIndex);

      case '@str_mask':
        final str = resolvedArgs['value']?.toString() ?? '';
        final start = _toInt(resolvedArgs['start'] ?? 0);
        final end = _toInt(resolvedArgs['end'] ?? str.length);
        final maskChar = resolvedArgs['mask']?.toString() ?? '*';
        if (str.isEmpty || start >= str.length) return str;
        final s = start.clamp(0, str.length);
        final e = end.clamp(s, str.length);
        return str.substring(0, s) + maskChar * (e - s) + str.substring(e);

      // ── 数组扩展 ──
      case '@list_shuffle':
        final listPath = resolvedArgs['var'] as String?;
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final newList = List<dynamic>.from(current)..shuffle(Random());
            setVariable(listPath, newList);
            return newList;
          }
        }
        return null;

      case '@list_sample':
        final listPath = resolvedArgs['var'] as String?;
        final count = _toInt(resolvedArgs['count'] ?? 1);
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List && current.isNotEmpty) {
            final shuffled = List<dynamic>.from(current)..shuffle(Random());
            return shuffled.take(count.clamp(0, shuffled.length)).toList();
          }
        }
        return [];

      case '@list_unique':
        final listPath = resolvedArgs['var'] as String?;
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final seen = <dynamic>{};
            final result = <dynamic>[];
            for (final item in current) {
              if (!seen.contains(item)) {
                seen.add(item);
                result.add(item);
              }
            }
            setVariable(listPath, result);
            return result;
          }
        }
        return null;

      case '@list_flatten':
        final listPath = resolvedArgs['var'] as String?;
        final depth = _toInt(resolvedArgs['depth'] ?? 1);
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final result = _flattenList(current, depth);
            setVariable(listPath, result);
            return result;
          }
        }
        return null;

      case '@list_sort':
        final sortListPath = resolvedArgs['var'] as String?;
        final sortKey = resolvedArgs['key'] as String?;
        final sortDesc = resolvedArgs['desc'] == true || resolvedArgs['desc'] == 'true';
        if (sortListPath != null) {
          final current = getVariable(sortListPath);
          if (current is List) {
            final result = List<dynamic>.from(current);
            if (sortKey != null && sortKey.isNotEmpty) {
              result.sort((a, b) {
                final va = a is Map ? a[sortKey] : null;
                final vb = b is Map ? b[sortKey] : null;
                int cmp;
                if (va is Comparable && vb is Comparable) {
                  cmp = va.compareTo(vb);
                } else {
                  cmp = va.toString().compareTo(vb.toString());
                }
                return sortDesc ? -cmp : cmp;
              });
            } else {
              result.sort((a, b) {
                int cmp;
                if (a is Comparable && b is Comparable) {
                  cmp = a.compareTo(b);
                } else {
                  cmp = a.toString().compareTo(b.toString());
                }
                return sortDesc ? -cmp : cmp;
              });
            }
            setVariable(sortListPath, result);
            return result;
          }
        }
        return null;

      case '@list_reverse':
        final listPath = resolvedArgs['var'] as String?;
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final result = current.reversed.toList();
            setVariable(listPath, result);
            return result;
          }
        }
        return null;

      case '@list_slice':
        final listPath = resolvedArgs['var'] as String?;
        final start = _toInt(resolvedArgs['start'] ?? 0);
        final end = resolvedArgs['end'];
        if (listPath != null) {
          final current = getVariable(listPath);
          if (current is List) {
            final e = end != null ? _toInt(end) : current.length;
            final s = start.clamp(0, current.length);
            final clampedEnd = e.clamp(s, current.length);
            final result = current.sublist(s, clampedEnd);
            setVariable(listPath, result);
            return result;
          }
        }
        return null;

      // ── 图片拍摄 / 选择 ──
      case '@take_photo':
        return await _pickOrTakeImage(resolvedArgs, ImageSource.camera);
      case '@pick_image':
        return await _pickOrTakeImage(resolvedArgs, ImageSource.gallery);

      case '@file_to_base64':
        final filePath = resolvedArgs['path'] as String?;
        if (filePath == null || filePath.isEmpty) return null;
        try {
          final file = File(filePath);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            final b64 = base64Encode(bytes);
            final b64Bind = resolvedArgs['bind'] as String?;
            if (b64Bind != null) {
              setVariable(b64Bind, b64);
            }
            return b64;
          }
        } catch (e) {
          debugPrint('[JSON DSL] file_to_base64 失败: $e');
        }
        return null;

      // ── 用户信息 ──
      case '@get_user_info':
        final userInfo = AuthService.currentUser != null
            ? Map<String, dynamic>.from(AuthService.currentUser!)
            : null;
        final bindPath = resolvedArgs['bind'] as String?;
        if (bindPath != null && userInfo != null) {
          setVariable(bindPath, userInfo);
        }
        return userInfo;

      case '@get_auth_token':
        final token = AuthService.token;
        final tokenBind = resolvedArgs['bind'] as String?;
        if (tokenBind != null && token != null) {
          setVariable(tokenBind, token);
        }
        return token;

      case '@is_logged_in':
        final loggedIn = AuthService.isLoggedIn;
        final loginBind = resolvedArgs['bind'] as String?;
        if (loginBind != null) {
          setVariable(loginBind, loggedIn);
        }
        return loggedIn;

      case '@logout':
        await AuthService.signOut();
        return null;

      case '@refresh_user':
        try {
          return await AuthService.fetchUser();
        } catch (e) {
          debugPrint('[JSON DSL] refresh_user 失败: $e');
          return null;
        }

      case '@update_profile':
        final username = resolvedArgs['username'] as String?;
        final avatarUrl = resolvedArgs['avatar_url'] as String?;
        try {
          return await AuthService.updateProfile(
            username: username,
            avatarUrl: avatarUrl,
          );
        } catch (e) {
          debugPrint('[JSON DSL] update_profile 失败: $e');
          return {'error': e.toString()};
        }

      case '@upload_avatar':
        final base64Data = resolvedArgs['base64'] as String?;
        if (base64Data == null || base64Data.isEmpty) return null;
        try {
          final url = await AuthService.uploadAvatar(base64Data);
          final bindPath = resolvedArgs['bind'] as String?;
          if (bindPath != null) {
            setVariable(bindPath, url);
          }
          return url;
        } catch (e) {
          debugPrint('[JSON DSL] upload_avatar 失败: $e');
          return null;
        }

      // ── IM（私信 / 好友）──
      // 这一组 action 把 IMService（OpenIM SDK 封装）暴露给 JSON-DSL；
      // lib_im 把这些原子 action 包成 nicely-named function 给上层 JSON-APP 用。
      // 平台限制：iOS / Android 才支持，其它平台 SDK 抛 MissingPluginException —
      // 这里统一 try / catch 兜底返回 null/false，让 JSON-APP 不会因平台不支持而崩。
      case '@im_current_user_id':
        {
          final id = IMService.instance.currentUserId;
          final bindPath = resolvedArgs['bind'] as String?;
          if (bindPath != null) setVariable(bindPath, id);
          return id;
        }

      case '@im_get_user_info':
        {
          // 按 userId 取对方公开资料（昵称 / 头像）。
          // 实现走 IMService.searchUsers（→ 后端 /api/im/users/search → Supabase
          // user_metadata.avatar_url），不用 OpenIM SDK 的 userManager.getUsersInfo——
          // OpenIM 那边的 faceURL 只在用户首次注册时写一次，Supabase 头像之后改了
          // 不会同步过去，所以拿到的永远是空。Supabase 是 avatar 的真实来源。
          // 返回 {user_id, nickname, face_url, email}，找不到返 null。
          final userId = (resolvedArgs['user_id'] as String?) ?? '';
          final bindPath = resolvedArgs['bind'] as String?;
          if (userId.isEmpty) {
            if (bindPath != null) setVariable(bindPath, null);
            return null;
          }
          try {
            // searchUsers 拿 q 做模糊匹配（email / username / uid 三选一）。
            // 把 userId 当 q 传，命中且 im_user_id 完全相等的就是目标。
            final hits = await IMService.instance.searchUsers(userId);
            final match = hits.firstWhere(
              (u) => (u['im_user_id']?.toString() ?? '') == userId,
              orElse: () => const {},
            );
            if (match.isEmpty) {
              if (bindPath != null) setVariable(bindPath, null);
              return null;
            }
            final result = {
              'user_id': match['im_user_id']?.toString() ?? '',
              'nickname': match['nickname']?.toString() ?? '',
              'face_url': match['face_url']?.toString() ?? '',
              'email': match['email']?.toString() ?? '',
            };
            if (bindPath != null) setVariable(bindPath, result);
            return result;
          } catch (e) {
            debugPrint('[JSON DSL] im_get_user_info 失败: $e');
            if (bindPath != null) setVariable(bindPath, null);
            return null;
          }
        }

      case '@im_search_users':
        {
          final q = (resolvedArgs['q'] as String?) ?? '';
          try {
            final users = await IMService.instance.searchUsers(q);

            // 给每条结果加 is_friend / is_self 标记，方便 JSON-APP 做条件渲染。
            // 友列走 OpenIM SDK 本地缓存（O(1) 内存读，无网络），currentUserId
            // 是登录后就有的字段，整体零额外延迟。
            final friends = await IMService.instance.getFriendList();
            final friendIds = friends
                .map((f) => f.userID)
                .whereType<String>()
                .toSet();
            final myId = IMService.instance.currentUserId;

            final enriched = users.map((u) {
              final uid = u['im_user_id']?.toString() ?? '';
              return <String, dynamic>{
                ...u,
                'is_friend': uid.isNotEmpty && friendIds.contains(uid),
                'is_self': uid.isNotEmpty && myId != null && uid == myId,
              };
            }).toList();

            final bindPath = resolvedArgs['bind'] as String?;
            if (bindPath != null) setVariable(bindPath, enriched);
            return enriched;
          } catch (e) {
            debugPrint('[JSON DSL] im_search_users 失败: $e');
            return const [];
          }
        }

      case '@im_send_friend_request':
        {
          final userId = (resolvedArgs['user_id'] as String?) ?? '';
          final reqMsg = (resolvedArgs['message'] as String?) ?? '';
          if (userId.isEmpty) return false;
          try {
            return await IMService.instance.sendFriendApplication(
              userID: userId,
              reqMsg: reqMsg,
            );
          } catch (e) {
            debugPrint('[JSON DSL] im_send_friend_request 失败: $e');
            return false;
          }
        }

      case '@im_friend_applications':
        {
          try {
            final apps = await IMService.instance.getIncomingFriendApplications();
            final list = apps.map(_friendApplicationToMap).toList();
            await _backfillFaceUrls(
              list,
              idField: 'from_user_id',
              faceField: 'from_face_url',
              nicknameField: 'from_nickname',
            );
            final bindPath = resolvedArgs['bind'] as String?;
            if (bindPath != null) setVariable(bindPath, list);
            return list;
          } catch (e) {
            debugPrint('[JSON DSL] im_friend_applications 失败: $e');
            return const [];
          }
        }

      case '@im_accept_friend':
        {
          final userId = (resolvedArgs['user_id'] as String?) ?? '';
          if (userId.isEmpty) return false;
          try {
            return await IMService.instance.acceptFriendApplication(fromUserID: userId);
          } catch (e) {
            debugPrint('[JSON DSL] im_accept_friend 失败: $e');
            return false;
          }
        }

      case '@im_reject_friend':
        {
          final userId = (resolvedArgs['user_id'] as String?) ?? '';
          if (userId.isEmpty) return false;
          try {
            return await IMService.instance.rejectFriendApplication(fromUserID: userId);
          } catch (e) {
            debugPrint('[JSON DSL] im_reject_friend 失败: $e');
            return false;
          }
        }

      case '@im_friend_list':
        {
          try {
            final friends = await IMService.instance.getFriendList();
            final list = friends.map(_friendInfoToMap).toList();
            await _backfillFaceUrls(
              list,
              idField: 'user_id',
              faceField: 'face_url',
              nicknameField: 'nickname',
            );
            final bindPath = resolvedArgs['bind'] as String?;
            if (bindPath != null) setVariable(bindPath, list);
            return list;
          } catch (e) {
            debugPrint('[JSON DSL] im_friend_list 失败: $e');
            return const [];
          }
        }

      case '@im_conversations':
        {
          try {
            final convos = await IMService.instance.getConversationList();
            final list = convos.map(_conversationToMap).toList();
            // 用 show_name 当昵称兜底字段——OpenIM 的 ConversationInfo.showName 已经是
            // 对方在 OpenIM 的昵称，但同样可能过时；Supabase 拿到新昵称时覆盖
            await _backfillFaceUrls(
              list,
              idField: 'user_id',
              faceField: 'face_url',
              nicknameField: 'show_name',
            );
            final bindPath = resolvedArgs['bind'] as String?;
            if (bindPath != null) setVariable(bindPath, list);
            return list;
          } catch (e) {
            debugPrint('[JSON DSL] im_conversations 失败: $e');
            return const [];
          }
        }

      case '@im_history':
        {
          final userId = (resolvedArgs['user_id'] as String?) ?? '';
          final count = (resolvedArgs['count'] is num)
              ? (resolvedArgs['count'] as num).toInt()
              : 30;
          if (userId.isEmpty) return const [];
          try {
            final convId = _singleChatConversationId(userId);
            if (convId == null) return const [];
            final messages = await IMService.instance.getHistoryMessages(
              conversationID: convId,
              count: count,
            );
            // OpenIM SDK 的 getAdvancedHistoryMessageList 返回**升序**（旧→新），
            // JSON-DSL 的 list 控件从上往下渲染 index 0 → N，所以**直接保留升序**
            // 即可让 UI 上呈现"老消息在顶、新消息在底"的微信式聊天体验。
            // 之前这里多了一步 .reversed 反而把"新消息"顶到列表最上方。
            final list = messages.map(_messageToMap).toList();
            final bindPath = resolvedArgs['bind'] as String?;
            if (bindPath != null) setVariable(bindPath, list);
            return list;
          } catch (e) {
            debugPrint('[JSON DSL] im_history 失败: $e');
            return const [];
          }
        }

      case '@im_send_text':
        {
          final userId = (resolvedArgs['user_id'] as String?) ?? '';
          final text = (resolvedArgs['text'] as String?) ?? '';
          if (userId.isEmpty || text.isEmpty) return null;
          try {
            final convId = _singleChatConversationId(userId);
            if (convId == null) return null;
            final msg = await IMService.instance.sendTextMessage(
              conversationID: convId,
              text: text,
              userID: userId,
            );
            return msg != null ? _messageToMap(msg) : null;
          } catch (e) {
            debugPrint('[JSON DSL] im_send_text 失败: $e');
            return null;
          }
        }

      case '@im_mark_read':
        {
          final userId = (resolvedArgs['user_id'] as String?) ?? '';
          if (userId.isEmpty) return false;
          try {
            final convId = _singleChatConversationId(userId);
            if (convId == null) return false;
            await IMService.instance.markConversationRead(conversationID: convId);
            return true;
          } catch (e) {
            debugPrint('[JSON DSL] im_mark_read 失败: $e');
            return false;
          }
        }

      case '@im_total_unread':
        {
          // 跨所有会话的未读总数，用于 tab badge / 应用图标角标
          try {
            final convos = await IMService.instance.getConversationList();
            int total = 0;
            for (final c in convos) {
              total += c.unreadCount;
            }
            final bindPath = resolvedArgs['bind'] as String?;
            if (bindPath != null) setVariable(bindPath, total);
            return total;
          } catch (e) {
            debugPrint('[JSON DSL] im_total_unread 失败: $e');
            return 0;
          }
        }

      case '@im_subscribe_inbox':
        {
          // 每次调用都会重置 global._im 在当前 _variables 里的初值（loadConfig
          // 切换 app 后老的 _im 会被清掉，新 app 调一次就有了）
          setVariable('global._im', {
            'tick': 0,
            'last_message': null,
            'current_user_id': IMService.instance.currentUserId,
          });
          // 监听只挂一次：interpreter 整个生命周期共用同一个 sub
          _imInboxSub ??= IMService.instance.newMessageStream.listen((msg) {
            try {
              final current = getVariable('global._im');
              final tick = (current is Map ? (current['tick'] as int? ?? 0) : 0) + 1;
              setVariable('global._im', {
                'tick': tick,
                'last_message': _messageToMap(msg),
                'current_user_id': IMService.instance.currentUserId,
              });
            } catch (e) {
              debugPrint('[JSON DSL] im inbox listener 失败: $e');
            }
          });
          return true;
        }

      case '@get_app_config':
        final bindPath = resolvedArgs['bind'] as String?;
        if (bindPath != null) {
          setVariable(bindPath, rawConfig);
        }
        return rawConfig;

      case '@apply_app_config':
        final newConfig = resolvedArgs['config'] as Map<String, dynamic>?;
        if (newConfig == null) return false;
        try {
          // 修改内存中的配置
          loadConfig(newConfig);
          // 重新执行初始化
          await executeSteps();
          notifyListeners();
          return true;
        } catch (e) {
          debugPrint('[JSON DSL] apply_app_config 失败: $e');
          return false;
        }

      case '@save_app_config':
        final configToSave = resolvedArgs['config'] as Map<String, dynamic>? ?? rawConfig;
        if (configToSave == null) return false;
        try {
          final appStorageClass = AppStorage.instance;
          final fileName = await appStorageClass.save(configToSave);
          debugPrint('[JSON DSL] 保存 APP 成功: $fileName');
          return fileName;
        } catch (e) {
          debugPrint('[JSON DSL] save_app_config 失败: $e');
          return false;
        }

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
    final maxIterations = _toInt(_resolveTemplatesInRule(args['max_iterations']) ?? 10000);

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
    final count = _toInt(_resolveTemplatesInRule(args['count']) ?? 0);
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
    final errorVar = _resolveTemplatesInRule(args['error_var']) as String?;

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

  // ============ 文件持久化辅助 ============

  Directory? _appDocDirCache;
  Future<Directory> _getAppDocDir() async {
    _appDocDirCache ??= await getApplicationDocumentsDirectory();
    return _appDocDirCache!;
  }

  // ============ UI 反馈 ============

  void _showToast(String message) {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return;

    // 超过 20 个立即清空所有旧的
    if (_activeToasts.length >= _maxOverlappingToasts) {
      for (final entry in _activeToasts) {
        entry.remove();
      }
      _activeToasts.clear();
    }

    final overlay = Overlay.of(ctx);
    late OverlayEntry entry;

    // 所有 toast 都在同一位置（贴底 80），新进入的天然盖在旧的上面（z-order）。
    // 视觉风格参考原生 Android Toast / 微信：紧凑、半透明深色、最大宽度封顶。
    entry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 80,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    _activeToasts.add(entry);

    // 2 秒后自动移除
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) {
        entry.remove();
        _activeToasts.remove(entry);
      }
    });
  }

  Future<bool> _showAlertDialog(String title, String message) async {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return false;

    _activeModalCount++;
    try {
      final result = await showDialog<bool>(
        context: ctx,
        builder: (dialogCtx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: SelectableText(message),
          ),
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
    } finally {
      _activeModalCount--;
    }
  }

  /// 自定义按钮对话框 — 返回被点击按钮的 value（关闭返回 null）
  /// buttons 项格式：{ label: String, value: dynamic, style?: 'primary'/'danger'/'text' }
  Future<dynamic> _showChoiceDialog(
    String title,
    String message,
    List<dynamic> buttons, {
    bool dismissible = true,
  }) async {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return null;

    _activeModalCount++;
    try {
      return await showDialog<dynamic>(
        context: ctx,
        barrierDismissible: dismissible,
        builder: (dialogCtx) {
        final actions = <Widget>[];
        for (final btn in buttons) {
          if (btn is! Map) continue;
          final label = btn['label']?.toString() ?? '';
          final value = btn['value'];
          final style = btn['style']?.toString() ?? 'text';

          Widget button;
          switch (style) {
            case 'primary':
              button = FilledButton(
                onPressed: () => Navigator.of(dialogCtx).pop(value),
                child: Text(label),
              );
              break;
            case 'danger':
              button = FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogCtx).colorScheme.error,
                  foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(dialogCtx).pop(value),
                child: Text(label),
              );
              break;
            case 'text':
            default:
              button = TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(value),
                child: Text(label),
              );
          }
          actions.add(button);
        }
        return AlertDialog(
          title: title.isEmpty ? null : Text(title),
          content: message.isEmpty
              ? null
              : SingleChildScrollView(child: SelectableText(message)),
          actions: actions,
        );
      },
    );
    } finally {
      _activeModalCount--;
    }
  }

  Future<String?> _showTextInputDialog(String title, String hint, String defaultValue) async {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return null;

    _activeModalCount++;
    try {
      return await showDialog<String>(
        context: ctx,
        builder: (dialogCtx) => _TextInputDialog(
          title: title,
          hint: hint,
          defaultValue: defaultValue,
        ),
      );
    } finally {
      _activeModalCount--;
    }
  }

  /// 增强版 SnackBar — 支持操作按钮
  void _showSnackBar(
    String message, {
    String? actionLabel,
    dynamic actionDef,
    int durationMs = 3000,
    Color? backgroundColor,
  }) {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(milliseconds: durationMs),
        backgroundColor: backgroundColor,
        action: (actionLabel != null && actionDef != null)
            ? SnackBarAction(
                label: actionLabel,
                onPressed: () {
                  if (ctx.mounted) {
                    executeAction(actionDef, ctx);
                  }
                },
              )
            : null,
      ),
    );
  }

  /// 命令式日期选择器
  Future<String?> _showDatePickerImperative(
      Map<String, dynamic> args) async {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return null;
    DateTime parseOr(String? s, DateTime fallback) {
      if (s == null || s.isEmpty) return fallback;
      try {
        return DateTime.parse(s);
      } catch (_) {
        return fallback;
      }
    }

    final now = DateTime.now();
    final initial = parseOr(args['initial']?.toString(), now);
    final firstDate = parseOr(args['firstDate']?.toString(),
        DateTime(now.year - 50));
    final lastDate = parseOr(args['lastDate']?.toString(),
        DateTime(now.year + 50));
    final bindPath = args['bind'] as String?;

    final picked = await showDatePicker(
      context: ctx,
      initialDate: initial.isBefore(firstDate) ? firstDate : initial,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null) return null;
    final m = picked.month.toString().padLeft(2, '0');
    final d = picked.day.toString().padLeft(2, '0');
    final s = '${picked.year}-$m-$d';
    if (bindPath != null) {
      setVariable(bindPath, s);
    }
    return s;
  }

  /// 命令式时间选择器
  Future<String?> _showTimePickerImperative(
      Map<String, dynamic> args) async {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return null;
    TimeOfDay initial = TimeOfDay.now();
    final initStr = args['initial']?.toString();
    if (initStr != null && initStr.contains(':')) {
      final parts = initStr.split(':');
      final h = int.tryParse(parts[0]);
      final mi = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (h != null && mi != null && h >= 0 && h < 24 && mi >= 0 && mi < 60) {
        initial = TimeOfDay(hour: h, minute: mi);
      }
    }
    final bindPath = args['bind'] as String?;

    final picked = await showTimePicker(
      context: ctx,
      initialTime: initial,
    );
    if (picked == null) return null;
    final h = picked.hour.toString().padLeft(2, '0');
    final m = picked.minute.toString().padLeft(2, '0');
    final s = '$h:$m';
    if (bindPath != null) {
      setVariable(bindPath, s);
    }
    return s;
  }

  /// 命令式底部弹窗
  Future<dynamic> _showBottomSheet(Map<String, dynamic> args) async {
    final ctx = globalContext;
    if (ctx == null || !ctx.mounted) return null;
    final content = args['content'];
    if (content is! Map<String, dynamic>) return null;
    final isDismissible = args['isDismissible'] != false;
    final enableDrag = args['enableDrag'] != false;
    final bg = _parseColorHex(args['backgroundColor']?.toString());

    _activeModalCount++;
    try {
      return await showModalBottomSheet<dynamic>(
        context: ctx,
        isDismissible: isDismissible,
        enableDrag: enableDrag,
        backgroundColor: bg,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (sheetCtx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: buildWidget(sheetCtx, content),
          ),
        ),
      );
    } finally {
      _activeModalCount--;
    }
  }

  /// 解析 #RRGGBB / #AARRGGBB 颜色字符串
  Color? _parseColorHex(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }

  Future<String?> _pickOrTakeImage(
    Map<String, dynamic> args,
    ImageSource source,
  ) async {
    final bindPath = args['bind'] as String?;
    final maxWidth = (args['max_width'] as num?)?.toDouble() ?? 1920;
    final maxHeight = (args['max_height'] as num?)?.toDouble() ?? 1920;
    final quality = (args['quality'] as num?)?.toInt() ?? 85;

    final picker = ImagePicker();
    try {
      final XFile? picked = await picker.pickImage(
        source: source,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        imageQuality: quality,
      );
      if (picked != null) {
        if (bindPath != null) {
          setVariable(bindPath, picked.path);
        }
        return picked.path;
      }
    } catch (e) {
      debugPrint('[JSON DSL] 图片获取失败: $e');
      if (source == ImageSource.camera) {
        try {
          final XFile? picked = await picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            imageQuality: quality,
          );
          if (picked != null) {
            if (bindPath != null) {
              setVariable(bindPath, picked.path);
            }
            return picked.path;
          }
        } catch (e2) {
          debugPrint('[JSON DSL] 图片选择 fallback 也失败: $e2');
        }
      }
    }
    return null;
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

  dynamic _resolveValue(dynamic value) {
    if (value is String) {
      if (value.contains('{{') && value.contains('}}')) {
        return resolveExpression(value);
      }
      return value;
    } else if (value is List) {
      return value.map((e) => _resolveValue(e)).toList();
    } else if (value is Map<String, dynamic>) {
      final resolvedMap = <String, dynamic>{};
      value.forEach((k, v) {
        resolvedMap[k] = _resolveValue(v);
      });
      return resolvedMap;
    }
    return value;
  }

  Map<String, dynamic> _resolveArgs(Map<String, dynamic> args) {
    final resolved = <String, dynamic>{};
    for (final entry in args.entries) {
      resolved[entry.key] = _resolveValue(entry.value);
    }
    return resolved;
  }

  // ============ Widget 构建 ============

  Widget buildWidget(BuildContext context, Map<String, dynamic> json) {
    // 通用 visible 字段：
    //   - 布尔/模板/jsonlogic 都支持，求值为 false 时返回 SizedBox.shrink
    //   - 没写 visible 字段视为永远显示（默认行为）
    //   - 这里同时把外层 position 也吃掉，避免 false 还占 flex 空间
    if (json.containsKey('visible')) {
      if (!_evaluateBool(json['visible'])) {
        return const SizedBox.shrink();
      }
    }
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

  /// 把 JSON 字符串映射到 permission_handler 的 Permission 枚举
  /// 不在表里的返回 null（调用方按"denied"兜底）
  Permission? _parsePermission(String type) {
    switch (type) {
      case 'camera':
        return Permission.camera;
      case 'microphone':
        return Permission.microphone;
      case 'photos':
        return Permission.photos;
      case 'location':
        return Permission.location;
      case 'locationWhenInUse':
        return Permission.locationWhenInUse;
      case 'locationAlways':
        return Permission.locationAlways;
      case 'contacts':
        return Permission.contacts;
      case 'calendar':
        return Permission.calendarFullAccess;
      case 'notification':
        return Permission.notification;
      case 'storage':
        return Permission.storage;
      case 'bluetooth':
        return Permission.bluetooth;
      case 'speech':
        return Permission.speech;
    }
    return null;
  }

  String _permissionStatusToString(PermissionStatus status) {
    if (status.isGranted) return 'granted';
    if (status.isLimited) return 'limited';
    if (status.isPermanentlyDenied) return 'permanentlyDenied';
    if (status.isRestricted) return 'restricted';
    return 'denied';
  }

  List<dynamic> _flattenList(List<dynamic> list, int depth) {
    if (depth <= 0) return list;
    final result = <dynamic>[];
    for (final item in list) {
      if (item is List) {
        result.addAll(_flattenList(item, depth - 1));
      } else {
        result.add(item);
      }
    }
    return result;
  }

  // ============ App 生命周期 hook ============
  // global.lifecycle = {
  //   onResume: [...steps],
  //   onPause:  [...steps],
  //   onInactive / onDetached / onHidden: ...
  // }

  void Function()? _lifecycleListener;

  void _attachLifecycleListener() {
    _detachLifecycleListener();
    _lifecycleListener = () {
      final event = appLifecycleEvent.value;
      final hooks =
          (_config['global'] as Map<String, dynamic>?)?['lifecycle']
              as Map<String, dynamic>?;
      if (hooks == null) return;
      // event=resume → onResume；event=pause → onPause；…
      final key = 'on${event[0].toUpperCase()}${event.substring(1)}';
      final steps = hooks[key];
      if (steps is! List) return;
      // 异步触发，不阻塞 notifier
      // ignore: discarded_futures
      _runStepList(steps);
    };
    appLifecycleEvent.addListener(_lifecycleListener!);
  }

  void _detachLifecycleListener() {
    if (_lifecycleListener != null) {
      appLifecycleEvent.removeListener(_lifecycleListener!);
      _lifecycleListener = null;
    }
  }

  Future<void> _runStepList(List<dynamic> steps) async {
    for (final step in steps) {
      if (step is Map<String, dynamic>) {
        try {
          await _executeStep(step);
        } catch (e) {
          debugPrint('[JSON DSL] lifecycle step 失败: $e');
        }
      }
    }
  }

  @override
  void dispose() {
    _detachLifecycleListener();
    _imInboxSub?.cancel();
    _imInboxSub = null;
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    _textControllers.clear();
    super.dispose();
  }

  // ── IM helpers ──────────────────────────────────────────────────────
  /// 把 OpenIM 列表（friends / conversations / friend_applications）里的
  /// face_url 字段从 Supabase 回填一次。
  ///
  /// Why: OpenIM 的 user.faceURL 只在用户首次注册时写一次，之后用户在 Supabase
  /// 改头像不会同步过去——所以 OpenIM 列表里 face_url 多半是空。Supabase 才是
  /// avatar 的真实源。这里 N 个用户并发查后端 search 接口（已带 60s 缓存），
  /// 一次刷新一般就 1-2 个新用户产生网络成本，可接受。
  Future<void> _backfillFaceUrls(
    List<Map<String, dynamic>> items, {
    required String idField,
    required String faceField,
    required String nicknameField,
  }) async {
    if (items.isEmpty) return;
    final ids = items
        .map((m) => m[idField]?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;
    final supaMap = await IMService.instance.lookupUsersFromSupabase(ids);
    if (supaMap.isEmpty) return;
    for (final item in items) {
      final id = item[idField]?.toString() ?? '';
      final supa = supaMap[id];
      if (supa == null) continue;
      final supaFace = supa['face_url']?.toString() ?? '';
      if (supaFace.isNotEmpty) item[faceField] = supaFace;
      // 昵称同样可能更新过；非空时盖一下，让显示用最新值
      final supaName = supa['nickname']?.toString() ?? '';
      if (supaName.isNotEmpty) item[nicknameField] = supaName;
    }
  }

  // OpenIM SDK 单聊 conversationID 约定：si_<a>_<b>，a/b 按字典序排序。
  // 拿不到自己的 IM userID 时返回 null（一般是没登录或 SDK 没初始化）。
  String? _singleChatConversationId(String otherUserId) {
    final myId = IMService.instance.currentUserId;
    if (myId == null || myId.isEmpty || otherUserId.isEmpty) return null;
    final ids = [myId, otherUserId]..sort();
    return 'si_${ids[0]}_${ids[1]}';
  }

  Map<String, dynamic> _friendInfoToMap(FriendInfo f) {
    return {
      'user_id': f.userID ?? '',
      'nickname': f.nickname ?? '',
      'face_url': f.faceURL ?? '',
      'remark': f.remark ?? '',
    };
  }

  Map<String, dynamic> _friendApplicationToMap(FriendApplicationInfo a) {
    return {
      'from_user_id': a.fromUserID ?? '',
      'from_nickname': a.fromNickname ?? '',
      'from_face_url': a.fromFaceURL ?? '',
      'req_msg': a.reqMsg ?? '',
      'handle_result': a.handleResult ?? 0, // 0=待处理 1=已同意 -1=已拒绝
      'create_time': a.createTime ?? 0,
    };
  }

  Map<String, dynamic> _messageToMap(Message m) {
    String text;
    switch (m.contentType) {
      case MessageType.text:
        text = m.textElem?.content ?? '';
        break;
      case MessageType.picture:
        text = '[图片]';
        break;
      case MessageType.video:
        text = '[视频]';
        break;
      case MessageType.voice:
        text = '[语音]';
        break;
      case MessageType.file:
        text = '[文件]';
        break;
      default:
        text = '[消息]';
    }
    final myId = IMService.instance.currentUserId ?? '';
    final sendId = m.sendID ?? '';
    final isMe = sendId == myId && sendId.isNotEmpty;
    final sendTime = m.sendTime ?? 0;
    final senderNick = m.senderNickname ?? '';
    // 他人显示名兜底：nick 为空时回退到 sendId（不要让 UI 出现空白发送者）
    final otherDisplay = senderNick.isNotEmpty ? senderNick : sendId;
    return {
      'client_msg_id': m.clientMsgID ?? '',
      'send_id': sendId,
      'recv_id': m.recvID ?? '',
      'send_time': sendTime,
      'content_type': m.contentType ?? 101,
      'text': text,
      'sender_nickname': senderNick,
      'sender_face_url': m.senderFaceUrl ?? '',
      'is_me': isMe,
      // 给 JSON-APP 用的"另一面"flag：is_me 取反，配合 widget visible 字段做
      // 自他分支渲染时不用写 jsonlogic `{"!": [...]}`
      'is_other': !isMe,
      // 预格式化字段：JSON-DSL 不支持条件 / 时间格式表达式，所以在这里算好
      'display_time': _formatChatTime(sendTime),
      'display_sender': isMe ? '我' : otherDisplay,
      // 微信风格气泡配色：自己绿色（#95EC69），他人白色
      'bubble_color': isMe ? '#95EC69' : '#FFFFFF',
      'bubble_text_color': '#000000',
    };
  }

  Map<String, dynamic> _conversationToMap(ConversationInfo c) {
    String latest;
    final lm = c.latestMsg;
    if (lm == null) {
      latest = '';
    } else {
      latest = _messageToMap(lm)['text'] as String? ?? '';
    }
    final unread = c.unreadCount;
    final latestTime = c.latestMsgSendTime ?? 0;
    return {
      'conversation_id': c.conversationID,
      'user_id': c.userID ?? '',
      'show_name': c.showName ?? '',
      'face_url': c.faceURL ?? '',
      'latest_text': latest,
      'latest_time': latestTime,
      'unread_count': unread,
      // 预格式化：unread 为 0 时空字符串（绑 text.value 直接隐藏徽标视觉）
      'display_unread': unread > 0 ? unread.toString() : '',
      'display_time': _formatChatTime(latestTime),
    };
  }

  /// 把 epoch 毫秒时间戳格式化为 IM 列表常见的"今天 HH:mm / 昨天 / MM-dd"。
  /// 0 / 负数 → 空串（用于"暂无消息"等场景）。
  String _formatChatTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dtDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(dtDay).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    // 时钟漂移 / 服务器时间快于本地时（diff < 0）也按"今天 HH:mm"渲染，
    // 避免出现 "−1 天前" 之类怪字符串。
    if (diff <= 0) return '${two(dt.hour)}:${two(dt.minute)}';
    if (diff == 1) return '昨天';
    if (diff < 7) return '$diff天前';
    return '${two(dt.month)}-${two(dt.day)}';
  }
}

class _TextInputDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String defaultValue;

  const _TextInputDialog({
    required this.title,
    required this.hint,
    required this.defaultValue,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.defaultValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.hint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
