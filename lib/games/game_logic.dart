// 游戏内部 logic 引擎 —— 跟主 JsonInterpreter 解耦的小型版本。
//
// 为什么不直接复用 JsonInterpreter？
// - JsonInterpreter 带 navigate / HTTP / 文件 IO / 130 个 @action，跑在游戏循环里太重
// - 游戏 logic 的"作用域"跟 JSON-APP 不一样：
//     vars.x      → 当前 game 实例的 vars Map
//     entities.x  → 当前 game 的 entities 快照
//     event.x     → 当前事件 payload（tap/swipe/tick 触发时注入）
//     world.x     → world 尺寸
//     score / best / game_over → 内置标量
// - 游戏 logic 需要的能力很有限：模板替换、jsonlogic 求值、@action dispatch
//
// 这套引擎实现：
// - resolveExpression(raw)：模板 / jsonlogic / 直通
// - runLogic(steps, eventData)：跑 action 数组
// - 内置 @set / @if 等通用流程控制（少量复制 JsonInterpreter 的实现）
// - 把 game-specific @action 委派给 GameActions（cell_path.* / scroll_list.* 等）

import 'dart:collection';

import 'package:jsonlogic/jsonlogic.dart';

import '../json_ui/execution/compiled_json_logic_evaluator.dart';
import '../json_ui/execution/expression_plan.dart';
import '../json_ui/execution/template_plan.dart';
import 'flame_game_engine.dart';
import 'game_actions.dart';

class GameLogicEngine {
  final JsonFlameGame game;

  /// event 作用域栈（嵌套场景：tick 里再触发其他 logic）
  final List<Map<String, dynamic>> _eventStack = [];

  /// loop 作用域栈（@for_each_entity 等迭代原子用，提供 {{ loop.id }} /
  /// {{ loop.entity }} / {{ loop.index }}）
  final List<Map<String, dynamic>> _loopStack = [];

  /// 构造时属于 game.spec 的对象身份。运行时 action / entity 临时生成的 Map
  /// 不在这里，继续走完全兼容的 legacy 路径。
  final HashSet<Object> _ownedSpecNodes = HashSet<Object>.identity();
  final HashMap<Object, JsonLogicExpressionPlan> _compiledExpressionPlans =
      HashMap<Object, JsonLogicExpressionPlan>.identity();
  final HashSet<Object> _inlineActionRoots = HashSet<Object>.identity();
  final HashSet<Object> _uncompilableExpressionRoots =
      HashSet<Object>.identity();
  final Map<String, TemplatePlan> _templatePlans = <String, TemplatePlan>{};
  final Expando<bool> _requiresEntityScopeCache = Expando<bool>(
    'game-logic-requires-entity-scope',
  );

  late final JsonLogicPlanCompiler _expressionCompiler;
  late final CompiledJsonLogicEvaluator _compiledEvaluator;

  int _compiledExpressionEvaluationCount = 0;
  int _legacyExpressionEvaluationCount = 0;
  int _entityScopeSnapshotCount = 0;

  GameLogicEngine(this.game) {
    _indexOwnedSpecNodes(game.spec);
    _expressionCompiler = JsonLogicPlanCompiler(
      knownOperators: _jsonLogicOps,
      templateFor: (source) => _templatePlans.putIfAbsent(
        source,
        () => TemplatePlan.compile(source),
      ),
    );
    _compiledEvaluator = CompiledJsonLogicEvaluator(
      // Game 模板的 exact binding 必须保留原始类型，不能改成字符串。
      templateResolver: (template) => _resolveString(template.source),
      fallbackPreprocessor: _resolveJsonLogicOperands,
      fallbackRuntime: _jsonlogic,
    );
    _precompileOwnedExpressions(game.spec);
  }

  /// 以下计数器只暴露只读视图，便于回归测试与性能采样确认实际命中路径。
  int get compiledExpressionPlanCount => _compiledExpressionPlans.length;
  int get compiledExpressionEvaluationCount =>
      _compiledExpressionEvaluationCount;
  int get legacyExpressionEvaluationCount => _legacyExpressionEvaluationCount;
  int get entityScopeSnapshotCount => _entityScopeSnapshotCount;

  void _indexOwnedSpecNodes(dynamic node) {
    if (node is Map) {
      if (!_ownedSpecNodes.add(node)) return;
      for (final value in node.values) {
        _indexOwnedSpecNodes(value);
      }
      return;
    }
    if (node is List) {
      if (!_ownedSpecNodes.add(node)) return;
      for (final value in node) {
        _indexOwnedSpecNodes(value);
      }
    }
  }

  void _precompileOwnedExpressions(dynamic root) {
    final visited = HashSet<Object>.identity();

    void visit(dynamic node) {
      if (node is Map) {
        if (!visited.add(node)) return;
        if (node is Map<String, dynamic> &&
            node.length == 1 &&
            _looksLikeJsonLogic(node.keys.first)) {
          _compiledPlanFor(node, node);
        }
        for (final value in node.values) {
          visit(value);
        }
        return;
      }
      if (node is List) {
        if (!visited.add(node)) return;
        for (final value in node) {
          visit(value);
        }
      }
    }

    visit(root);
  }

  /// 跑一组 step（actions / 子规则）
  void runLogic(List<dynamic> steps, [Map<String, dynamic>? eventData]) {
    if (eventData != null) _eventStack.add(eventData);
    try {
      for (final step in steps) {
        runStep(step);
      }
    } finally {
      if (eventData != null) _eventStack.removeLast();
    }
  }

  /// 跑一组 step，但带 loop 上下文（迭代原子用）
  void runLogicWithLoop(List<dynamic> steps, Map<String, dynamic> loopData) {
    _loopStack.add(loopData);
    try {
      for (final step in steps) {
        runStep(step);
      }
    } finally {
      _loopStack.removeLast();
    }
  }

  /// 跑单个 step
  void runStep(dynamic step) {
    if (step is! Map<String, dynamic>) return;
    if (step.containsKey('call')) {
      runAction(step);
    } else {
      // 没 call 的 Map 当作 jsonlogic 表达式求值（虽然没 side effect，
      // 留个口子让 logic 数组里也能写纯表达式）
      resolveExpression(step);
    }
  }

  /// 跑单个 action {call, args}
  dynamic runAction(Map<String, dynamic> action) {
    final call = action['call'] as String?;
    if (call == null) return null;

    // Lazy-eval actions：不预解析 args（否则 then/else / do / body 等子分支
    // 里的 inline action 会在 args 解析阶段被当成内联表达式提前 dispatch，
    // 跑了一次还拿不到正确的 loop / 状态上下文）。
    if (call == '@if') {
      return _doIf(action['args'] as Map<String, dynamic>? ?? {});
    }
    if (call == '@while') {
      return _doWhile(action['args'] as Map<String, dynamic>? ?? {});
    }
    if (call == '@loop_by_num') {
      return _doLoopByNum(action['args'] as Map<String, dynamic>? ?? {});
    }
    if (call == '@for_each_entity') {
      // do 数组要保持原样，由 dispatch 内部的迭代 case 在每次 push 完
      // loop 上下文后再 runStep。这里只解析非 do 的部分（where_prefix 等）。
      final rawArgs = (action['args'] as Map?)?.cast<String, dynamic>() ?? {};
      final partial = _resolveMapExcept(rawArgs, const {'do'});
      final result = GameActions.dispatch(game, call, partial, this);
      _assignResult(action, result);
      return result;
    }
    if (call == '@tiled.spawn_objects' || call == '@tiled.spawn_objects_near') {
      final rawArgs = (action['args'] as Map?)?.cast<String, dynamic>() ?? {};
      final partial = _resolveMapExcept(rawArgs, const {'templates'});
      final result = GameActions.dispatch(game, call, partial, this);
      _assignResult(action, result);
      return result;
    }

    final rawArgs = (action['args'] as Map?)?.cast<String, dynamic>() ?? {};
    final args = _resolveMap(rawArgs);

    if (call.startsWith('@compute.')) {
      final session = game.computeSession;
      if (session == null) {
        throw StateError('$call requires a top-level compute module');
      }
      final result = session.execute(call.substring('@compute.'.length), args);
      _assignResult(action, result);
      return result;
    }

    switch (call) {
      case '@set':
        return _doSet(args);
      case '@noop':
        return null;
    }

    final result = GameActions.dispatch(game, call, args, this);
    _assignResult(action, result);
    return result;
  }

  void _assignResult(Map<String, dynamic> action, dynamic result) {
    final assign = action['assign']?.toString();
    if (assign != null && assign.isNotEmpty) {
      setVariable(assign, result);
    }
  }

  // ---------- 内置 ----------

  void _doSet(Map<String, dynamic> args) {
    final varPath = args['var']?.toString();
    if (varPath == null) return;
    final value = args['value'];
    setVariable(varPath, value);
  }

  void _doIf(Map<String, dynamic> rawArgs) {
    // cond 不能提前烤模板（{{ vars.x }} 在分支决定之前就被求值了，OK；
    // 但 then/else 里的子 step 应该惰性求值）
    final condRaw = rawArgs['cond'];
    final thenRaw = rawArgs['then'];
    final elseRaw = rawArgs['else'];

    final condValue = resolveExpression(condRaw);
    final isTruthy = _truthy(condValue);
    if (isTruthy) {
      if (thenRaw is List) runLogic(thenRaw);
    } else {
      if (elseRaw is List) runLogic(elseRaw);
    }
  }

  /// @while: { cond, body, max_iterations? }
  /// 每轮重新求 cond（vars / entities 可能在 body 里被改），body 是 logic 数组
  /// max_iterations 兜底防死循环，默认 10000 跟主解释器对齐
  void _doWhile(Map<String, dynamic> rawArgs) {
    final condRaw = rawArgs['cond'];
    final bodyRaw = rawArgs['body'];
    final maxIter = (rawArgs['max_iterations'] as num?)?.toInt() ?? 10000;
    if (bodyRaw is! List) return;

    int count = 0;
    while (count < maxIter) {
      final condValue = resolveExpression(condRaw);
      if (!_truthy(condValue)) break;
      runLogic(bodyRaw);
      count++;
    }
  }

  /// @loop_by_num: { count, body }
  /// body 内通过 {{ loop.index }} / {{ loop.item }} 拿当前迭代序号（0..count-1）
  /// 跟主解释器同样行为
  void _doLoopByNum(Map<String, dynamic> rawArgs) {
    final countRaw = resolveExpression(rawArgs['count']);
    final count = (countRaw is num) ? countRaw.toInt() : 0;
    final bodyRaw = rawArgs['body'];
    if (bodyRaw is! List) return;

    for (int i = 0; i < count; i++) {
      runLogicWithLoop(bodyRaw, {'index': i, 'item': i});
    }
  }

  bool _truthy(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  // ---------- 表达式 / 模板 ----------

  /// 入口：可能是 String / Map(jsonlogic / inline action) / 原始值
  dynamic resolveExpression(dynamic raw) {
    if (raw is String) {
      return _resolveString(raw);
    }
    if (raw is Map) {
      final m = raw.cast<String, dynamic>();
      // 内联 action 调用：{"call": "@xxx", "args": {...}} —— 当作表达式求值
      // 用法：@set 的 value、@if 的 cond 里嵌一个 @scroll_list.tap 之类
      if (m.containsKey('call')) {
        return runAction(m);
      }
      // 单 key 且 key 是 jsonlogic op → 求值
      if (m.length == 1 && _looksLikeJsonLogic(m.keys.first)) {
        return _evalJsonLogic(m, raw);
      }
      // 否则当数据 Map，递归 resolve 每个 value
      return _resolveMap(m);
    }
    if (raw is List) {
      return raw.map(resolveExpression).toList();
    }
    return raw;
  }

  /// 烤"{{ x }}"
  /// - "{{ x }}" 单独 → 返回原始类型
  /// - "abc {{ x }} def" → 返回 String
  /// - 其他无 {{ → 直通
  dynamic _resolveString(String s) {
    // `[^{}]` 而非 `.+?`：避免「{{ 开头 }} 结尾」的混合模板被整体误匹配成单变量
    // → null。混合模板走下面的逐个插值。（同 interpreter.resolveExpression）
    final fullMatch = RegExp(r'^\s*\{\{\s*([^{}]+?)\s*\}\}\s*$').firstMatch(s);
    if (fullMatch != null) {
      return getVariable(fullMatch.group(1)!);
    }
    if (s.contains('{{')) {
      return s.replaceAllMapped(RegExp(r'\{\{\s*(.+?)\s*\}\}'), (m) {
        final v = getVariable(m.group(1)!);
        return _stringifyForTemplate(v);
      });
    }
    return s;
  }

  /// 把任意值字符串化用于模板插值。整数值的 double 不带 ".0"——
  /// jsonlogic 2.0.2 的 + / * 累加器是 0.0/1.0，任何 int+int 算数会升级
  /// double。模板路径 "vars.board.{{ _i }}" 在 _i=1.0 时变 "vars.board.1.0"
  /// 多一段 split 出错。详见主解释器 _stringifyForTemplate 同名函数注释。
  static String _stringifyForTemplate(dynamic value) {
    if (value == null) return '';
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  Map<String, dynamic> _resolveMap(Map<String, dynamic> m) {
    final out = <String, dynamic>{};
    m.forEach((k, v) {
      out[k] = resolveExpression(v);
    });
    return out;
  }

  Map<String, dynamic> _resolveMapExcept(
    Map<String, dynamic> m,
    Set<String> rawKeys,
  ) {
    final out = <String, dynamic>{};
    m.forEach((k, v) {
      out[k] = rawKeys.contains(k) ? v : resolveExpression(v);
    });
    return out;
  }

  /// jsonlogic 操作符识别（粗糙白名单，避免把数据 Map 当表达式）
  static const _jsonLogicOps = {
    'var',
    'if',
    'and',
    'or',
    '!',
    '!!',
    '==',
    '!=',
    '===',
    '!==',
    '<',
    '>',
    '<=',
    '>=',
    '+',
    '-',
    '*',
    '/',
    '%',
    'min',
    'max',
    'in',
    'cat',
    'substr',
    'log',
    'missing',
    'missing_some',
    'merge',
    'reduce',
    'map',
    'filter',
    'all',
    'some',
    'none',
    'method',
  };

  bool _looksLikeJsonLogic(String k) => _jsonLogicOps.contains(k);

  static final Jsonlogic _jsonlogic = Jsonlogic();

  dynamic _evalJsonLogic(Map<String, dynamic> rule, Object sourceIdentity) {
    try {
      final plan = _compiledPlanFor(rule, sourceIdentity);
      if (plan != null) {
        _compiledExpressionEvaluationCount++;
        // 保持旧执行顺序：先解析模板，再构造 entities 快照。这样模板内联
        // action 对状态的修改仍能被随后创建的数据作用域观察到。
        final prepared = _compiledEvaluator.prepare(plan);
        final includeEntities = _requiresEntityScope(plan);
        final data = _dataScope(includeEntities: includeEntities);
        return _compiledEvaluator.evaluatePrepared(plan, data, prepared);
      }

      _legacyExpressionEvaluationCount++;
      // 先把规则里的字符串模板和 inline action 预处理掉：
      // - {"var": "vars.x.{{ idx }}"} 这种动态路径需要烤模板
      // - {"and": [{"call": "@xxx"}, ...]} 这种条件组合需要先执行表达式 action
      final preprocessed = _resolveJsonLogicOperands(rule);
      return _jsonlogic.apply(preprocessed, _dataScope());
    } catch (e) {
      // 表达式炸了不能让游戏崩，返回 null 让上游决定
      return null;
    }
  }

  JsonLogicExpressionPlan? _compiledPlanFor(
    Map<String, dynamic> rule,
    Object sourceIdentity,
  ) {
    if (!_ownedSpecNodes.contains(sourceIdentity)) return null;
    if (_inlineActionRoots.contains(sourceIdentity)) return null;
    if (_uncompilableExpressionRoots.contains(sourceIdentity)) return null;

    final cached = _compiledExpressionPlans[sourceIdentity];
    if (cached != null) return cached;

    // inline action 的 legacy 预处理是 eager 的，连未选择的逻辑分支也会
    // dispatch。只要整棵 root 任意位置含 call，就必须完整保留 legacy，
    // 不能局部编译后因短路而漏掉副作用。
    if (_containsInlineAction(rule)) {
      _inlineActionRoots.add(sourceIdentity);
      return null;
    }

    try {
      final plan = _expressionCompiler.compile(rule, r'$.game.expression');
      _compiledExpressionPlans[sourceIdentity] = plan;
      return plan;
    } catch (_) {
      // Construction-time compilation must never make a formerly tolerated
      // game spec unloadable. Leave malformed or cyclic roots on legacy.
      _uncompilableExpressionRoots.add(sourceIdentity);
      return null;
    }
  }

  bool _containsInlineAction(dynamic node) {
    if (node is Map) {
      if (node.containsKey('call')) return true;
      for (final value in node.values) {
        if (_containsInlineAction(value)) return true;
      }
      return false;
    }
    if (node is List) {
      for (final value in node) {
        if (_containsInlineAction(value)) return true;
      }
    }
    return false;
  }

  /// 只有静态证明表达式不可能读取 whole data / entities 时才裁掉快照。
  /// 任何动态 var、missing、fallback 都保守地保留完整作用域。
  bool _requiresEntityScope(JsonLogicExpressionPlan plan) {
    final cached = _requiresEntityScopeCache[plan];
    if (cached != null) return cached;
    final result = _computeRequiresEntityScope(plan);
    _requiresEntityScopeCache[plan] = result;
    return result;
  }

  bool _computeRequiresEntityScope(JsonLogicExpressionPlan plan) {
    if (plan is JsonLogicVariablePlan) {
      final key = plan.key;
      if (key == null || key == '') return true;
      if (key is String && (key == 'entities' || key.startsWith('entities.'))) {
        return true;
      }
      final defaultValue = plan.defaultValue;
      return defaultValue != null && _requiresEntityScope(defaultValue);
    }
    if (plan is JsonLogicTemplatePlan) {
      for (final part in plan.template.parts) {
        if (part is TemplateBindingPart) {
          final variable = part.variable;
          if (variable != null &&
              (variable.source == 'entities' ||
                  variable.source.startsWith('entities.'))) {
            return true;
          }
        }
      }
      return false;
    }
    if (plan is JsonLogicLiteralListPlan) {
      return plan.items.any(_requiresEntityScope);
    }
    if (plan is JsonLogicLiteralMapPlan) {
      return plan.values.values.any(_requiresEntityScope);
    }
    if (plan is JsonLogicMultiAndPlan) {
      return plan.entries.any(_requiresEntityScope);
    }
    if (plan is JsonLogicFallbackPlan) return true;
    if (plan is JsonLogicOperatorPlan) {
      if (plan.operatorName == 'var' ||
          plan.operatorName == 'missing' ||
          plan.operatorName == 'missing_some') {
        return true;
      }
      return plan.parameters.any(_requiresEntityScope);
    }
    return false;
  }

  /// 递归预处理 jsonlogic 规则里的 `{{ x }}` 模板字符串。
  /// 跟主解释器 _resolveTemplatesInRule 同行为，让 `{"var": "vars.board.{{ _i }}"}`
  /// 这种动态路径能用。
  dynamic _resolveJsonLogicOperands(dynamic rule) {
    if (rule is String && rule.contains('{{') && rule.contains('}}')) {
      return _resolveString(rule);
    }
    if (rule is List) {
      return rule.map((e) => _resolveJsonLogicOperands(e)).toList();
    }
    if (rule is Map<String, dynamic>) {
      if (rule.containsKey('call')) {
        return runAction(rule);
      }
      return rule.map((k, v) => MapEntry(k, _resolveJsonLogicOperands(v)));
    }
    return rule;
  }

  /// 给 jsonlogic / `{{ ... }}` 用的全局数据
  Map<String, dynamic> _dataScope({bool includeEntities = true}) {
    final scope = <String, dynamic>{
      'vars': game.vars,
      'event': _eventStack.isNotEmpty ? _eventStack.last : <String, dynamic>{},
      'loop': _loopStack.isNotEmpty ? _loopStack.last : <String, dynamic>{},
      'world': {
        'cols': game.gameWorld.cols,
        'rows': game.gameWorld.rows,
        'width': game.gameWorld.width,
        'height': game.gameWorld.height,
        'cell_w': game.gameWorld.cellW,
        'cell_h': game.gameWorld.cellH,
      },
      'score': game.score,
      'best': game.bestScore,
      'game_over': game.isGameOver,
    };
    if (includeEntities) {
      _entityScopeSnapshotCount++;
      final entitiesMap = <String, dynamic>{};
      game.entities.forEach((id, e) => entitiesMap[id] = e.toMap());
      scope['entities'] = entitiesMap;
    }
    return scope;
  }

  /// 读变量（点路径）
  dynamic getVariable(String path) {
    final parts = path.split('.');
    if (parts.isEmpty) return null;
    final root = parts.first;
    final rest = parts.skip(1).toList();

    dynamic current;
    switch (root) {
      case 'vars':
        current = game.vars;
        break;
      case 'event':
        current = _eventStack.isNotEmpty ? _eventStack.last : null;
        break;
      case 'loop':
        current = _loopStack.isNotEmpty ? _loopStack.last : null;
        break;
      case 'entities':
        if (rest.isEmpty) {
          final m = <String, dynamic>{};
          game.entities.forEach((id, e) => m[id] = e.toMap());
          return m;
        }
        final entId = rest.first;
        final ent = game.entities[entId];
        if (ent == null) return null;
        if (rest.length == 1) return ent.toMap();
        return _walkPath(ent.toMap(), rest.skip(1).toList());
      case 'world':
        current = {
          'cols': game.gameWorld.cols,
          'rows': game.gameWorld.rows,
          'width': game.gameWorld.width,
          'height': game.gameWorld.height,
          'cell_w': game.gameWorld.cellW,
          'cell_h': game.gameWorld.cellH,
        };
        break;
      case 'score':
        return rest.isEmpty ? game.score : null;
      case 'best':
        return rest.isEmpty ? game.bestScore : null;
      case 'game_over':
        return rest.isEmpty ? game.isGameOver : null;
      default:
        // 不带前缀 → 当 vars 处理（兼容性）
        current = game.vars;
        return _walkPath(current, parts);
    }
    return _walkPath(current, rest);
  }

  dynamic _walkPath(dynamic node, List<String> parts) {
    dynamic cur = node;
    for (final p in parts) {
      if (cur is Map) {
        cur = cur[p];
      } else if (cur is List) {
        final i = int.tryParse(p);
        if (i == null || i < 0 || i >= cur.length) return null;
        cur = cur[i];
      } else {
        return null;
      }
    }
    return cur;
  }

  /// 写变量（点路径）
  void setVariable(String path, dynamic value) {
    final parts = path.split('.');
    if (parts.isEmpty) return;
    final root = parts.first;
    final rest = parts.skip(1).toList();
    final resolved = resolveExpression(value);

    switch (root) {
      case 'vars':
        if (rest.isEmpty) {
          if (resolved is Map<String, dynamic>) {
            game.vars
              ..clear()
              ..addAll(resolved);
          }
        } else {
          _writePath(game.vars, rest, resolved);
        }
        break;
      case 'score':
        if (rest.isEmpty && resolved is num) {
          game.setScore(resolved.toInt());
        }
        break;
      case 'game_over':
        if (rest.isEmpty && resolved is bool) {
          if (resolved) game.triggerGameOver();
        }
        break;
      // entities 的写入暂不支持（用 @cell_path.* 等 action）
    }
  }

  /// 写嵌套路径。支持 Map 和 List 中段穿过 + 末段写入。
  /// 跟主解释器 _setNestedValue 行为一致：List 越界 / 非数字段静默 no-op。
  void _writePath(
    Map<String, dynamic> root,
    List<String> parts,
    dynamic value,
  ) {
    dynamic cur = root;
    for (int i = 0; i < parts.length - 1; i++) {
      final p = parts[i];
      if (cur is Map<String, dynamic>) {
        final next = cur[p];
        if (next is Map<String, dynamic> || next is List) {
          cur = next;
        } else {
          final newMap = <String, dynamic>{};
          cur[p] = newMap;
          cur = newMap;
        }
      } else if (cur is List) {
        final idx = int.tryParse(p);
        if (idx == null || idx < 0 || idx >= cur.length) return;
        cur = cur[idx];
      } else {
        return;
      }
    }
    final lastKey = parts.last;
    if (cur is Map<String, dynamic>) {
      cur[lastKey] = value;
    } else if (cur is List) {
      final idx = int.tryParse(lastKey);
      if (idx != null && idx >= 0 && idx < cur.length) {
        cur[idx] = value;
      }
    }
  }
}
