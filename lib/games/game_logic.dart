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

import 'package:jsonlogic/jsonlogic.dart';

import 'flame_game_engine.dart';
import 'game_actions.dart';

class GameLogicEngine {
  final JsonFlameGame game;

  /// event 作用域栈（嵌套场景：tick 里再触发其他 logic）
  final List<Map<String, dynamic>> _eventStack = [];

  GameLogicEngine(this.game);

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

  /// 跑单个 step
  void runStep(dynamic step) {
    if (step is! Map<String, dynamic>) return;
    if (step.containsKey('call')) {
      runAction(step);
    } else {
      // 纯 jsonlogic 求值（无 side effect）
      evaluate(step);
    }
  }

  /// 跑单个 action {call, args}
  dynamic runAction(Map<String, dynamic> action) {
    final call = action['call'] as String?;
    if (call == null) return null;

    // Lazy-eval actions：不预解析 args（否则 then/else 等子分支会被提前执行）
    if (call == '@if') {
      return _doIf(action['args'] as Map<String, dynamic>? ?? {});
    }

    final rawArgs = (action['args'] as Map?)?.cast<String, dynamic>() ?? {};
    final args = _resolveMap(rawArgs);

    switch (call) {
      case '@set':
        return _doSet(args);
      case '@noop':
        return null;
    }

    return GameActions.dispatch(game, call, args, this);
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
        return _evalJsonLogic(m);
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
    final fullMatch = RegExp(r'^\s*\{\{\s*(.+?)\s*\}\}\s*$').firstMatch(s);
    if (fullMatch != null) {
      return getVariable(fullMatch.group(1)!);
    }
    if (s.contains('{{')) {
      return s.replaceAllMapped(RegExp(r'\{\{\s*(.+?)\s*\}\}'), (m) {
        final v = getVariable(m.group(1)!);
        return v?.toString() ?? '';
      });
    }
    return s;
  }

  Map<String, dynamic> _resolveMap(Map<String, dynamic> m) {
    final out = <String, dynamic>{};
    m.forEach((k, v) {
      out[k] = resolveExpression(v);
    });
    return out;
  }

  /// jsonlogic 操作符识别（粗糙白名单，避免把数据 Map 当表达式）
  static const _jsonLogicOps = {
    'var', 'if', 'and', 'or', '!', '!!', '==', '!=', '===', '!==',
    '<', '>', '<=', '>=', '+', '-', '*', '/', '%', 'min', 'max',
    'in', 'cat', 'substr', 'log', 'missing', 'missing_some',
    'merge', 'reduce', 'map', 'filter', 'all', 'some', 'none', 'method',
  };

  bool _looksLikeJsonLogic(String k) => _jsonLogicOps.contains(k);

  static final Jsonlogic _jsonlogic = Jsonlogic();

  dynamic _evalJsonLogic(Map<String, dynamic> rule) {
    try {
      return _jsonlogic.apply(rule, _dataScope());
    } catch (e) {
      // 表达式炸了不能让游戏崩，返回 null 让上游决定
      return null;
    }
  }

  /// 给 jsonlogic / `{{ ... }}` 用的全局数据
  Map<String, dynamic> _dataScope() {
    final entitiesMap = <String, dynamic>{};
    game.entities.forEach((id, e) => entitiesMap[id] = e.toMap());
    return {
      'vars': game.vars,
      'entities': entitiesMap,
      'event': _eventStack.isNotEmpty ? _eventStack.last : <String, dynamic>{},
      'world': {
        'cols': game.world.cols,
        'rows': game.world.rows,
        'width': game.world.width,
        'height': game.world.height,
        'cell_w': game.world.cellW,
        'cell_h': game.world.cellH,
      },
      'score': game.score,
      'best': game.bestScore,
      'game_over': game.isGameOver,
    };
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
          'cols': game.world.cols,
          'rows': game.world.rows,
          'width': game.world.width,
          'height': game.world.height,
          'cell_w': game.world.cellW,
          'cell_h': game.world.cellH,
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

  void _writePath(Map<String, dynamic> root, List<String> parts, dynamic value) {
    Map<String, dynamic> cur = root;
    for (int i = 0; i < parts.length - 1; i++) {
      final p = parts[i];
      final next = cur[p];
      if (next is Map<String, dynamic>) {
        cur = next;
      } else {
        final newMap = <String, dynamic>{};
        cur[p] = newMap;
        cur = newMap;
      }
    }
    cur[parts.last] = value;
  }
}
