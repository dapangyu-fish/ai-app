// `flame_game` 控件 —— B 模式：JSON 描述游戏，没有 scene 概念。
//
// JSON 形态见 JSON-DSL.md。整个 spec 直接传给 JsonFlameGame。
//
// 跟外层 JSON-APP 的桥：
// - 游戏 emit 'scoreChanged' / 'gameOver' / 'reset' 时，根据 spec 里的
//   on_score_changed / on_game_over / on_reset 调外层 interpreter.executeActionWithEvent
// - 外层 JSON-APP 的 vars / global 不能直接被游戏读，但可以在 init 时通过
//   "{{ global.bestScore }}" 等模板烤进 spec.vars 里
// - 游戏内部状态（vars / score / entities）不外漏，外层只通过事件回调感知

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../../games/flame_game_engine.dart';
import '../interpreter.dart';
import 'base_widget.dart';

class JsonFlameGameWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    // 把 spec 里的 "{{ global.x }}" 等模板烤一遍（init 时一次性）
    // —— 注意：游戏内部用的 "{{ vars.x }}" 等仍然由游戏 logic 引擎自己解析
    final bakedSpec = _bakeOuterTemplates(json, interpreter);

    return _FlameGameMount(
      spec: bakedSpec,
      interpreter: interpreter,
      height: (json['height'] as num?)?.toDouble(),
    );
  }

  /// 只烤外层（global.* / loop.*）模板，保留游戏内部命名空间（vars.* / event.* / entities.* / world.*）
  Map<String, dynamic> _bakeOuterTemplates(
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    dynamic walk(dynamic node) {
      if (node is String) {
        return _resolveOuterOnly(node, interpreter);
      }
      if (node is List) {
        return node.map(walk).toList();
      }
      if (node is Map) {
        // ⚠️ 不能用 node.map((k,v) => MapEntry(k, walk(v))) ——
        // 推断出来是 Map<dynamic, dynamic>，最后的 as Map<String, dynamic> 会炸。
        // 显式 forEach 写到一个 typed map 里，保证类型链路。
        final out = <String, dynamic>{};
        node.forEach((k, v) {
          out[k.toString()] = walk(v);
        });
        return out;
      }
      return node;
    }
    return walk(json) as Map<String, dynamic>;
  }

  String _resolveOuterOnly(String s, JsonInterpreter interpreter) {
    final regex = RegExp(r'\{\{\s*([^}]+?)\s*\}\}');
    return s.replaceAllMapped(regex, (m) {
      final expr = m.group(1)!.trim();
      // 内部命名空间 —— 留给游戏 logic 自己解析
      if (expr.startsWith('vars.') ||
          expr.startsWith('event.') ||
          expr.startsWith('entities.') ||
          expr.startsWith('world.') ||
          expr == 'score' ||
          expr == 'best' ||
          expr == 'game_over') {
        return m.group(0)!; // 原样返回
      }
      // 外层 —— 用主 interpreter 求值
      final v = interpreter.getVariable(expr);
      return v?.toString() ?? '';
    });
  }
}

class _FlameGameMount extends StatefulWidget {
  final Map<String, dynamic> spec;
  final JsonInterpreter interpreter;
  final double? height;

  const _FlameGameMount({
    required this.spec,
    required this.interpreter,
    this.height,
  });

  @override
  State<_FlameGameMount> createState() => _FlameGameMountState();
}

class _FlameGameMountState extends State<_FlameGameMount> {
  late final JsonFlameGame _game;

  // 一次手势内累积位移，松手时一次性发 swipe
  double _panDx = 0;
  double _panDy = 0;

  // 按住起始时刻 — 给 input.press_end 算 held_ms
  DateTime? _pressDownTime;

  late final void Function() _resetter;

  @override
  void initState() {
    super.initState();
    _game = JsonFlameGame(
      spec: widget.spec,
      onEvent: _dispatchEvent,
    );
    // 注册到 interpreter，让 @flame_game_reset 这个 action 能找到我们
    _resetter = () => _game.resetGame();
    widget.interpreter.registerFlameGameResetter(_resetter);
  }

  @override
  void dispose() {
    widget.interpreter.unregisterFlameGameResetter(_resetter);
    super.dispose();
  }

  /// 游戏事件 → JSON-APP 的 on_xxx 回调
  void _dispatchEvent(String event, Map<String, dynamic> data) {
    if (!mounted) return;
    final action = widget.spec['on_$event'];
    if (action is! Map<String, dynamic>) return;
    widget.interpreter
        .executeActionWithEvent(action, context, data)
        .catchError((e, st) {
      debugPrint('[flame_game] on_$event 抛错: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    // GestureDetector 把 tap / pan 转给游戏，避免依赖 Flame 不稳定的输入 mixin
    final core = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        _pressDownTime = DateTime.now();
        _game.handleTap(d.localPosition.dx, d.localPosition.dy);
      },
      onTapUp: (d) {
        if (_pressDownTime != null && _game.hasPressEnd) {
          final ms = DateTime.now().difference(_pressDownTime!).inMilliseconds;
          _game.handlePressEnd(d.localPosition.dx, d.localPosition.dy, ms);
        }
        _pressDownTime = null;
      },
      onTapCancel: () {
        _pressDownTime = null;
      },
      onPanStart: (_) {
        _panDx = 0;
        _panDy = 0;
      },
      onPanUpdate: (d) {
        _panDx += d.delta.dx;
        _panDy += d.delta.dy;
        // 连续模式：每一帧 onPanUpdate 直接喂给游戏
        if (_game.hasPan) _game.handlePan(d.delta.dx, d.delta.dy);
      },
      onPanEnd: (_) {
        // 离散模式：一次手势结束发一次 swipe
        if (_game.hasSwipe) {
          final th = _game.swipeThreshold;
          if (_panDx.abs() > th || _panDy.abs() > th) {
            _game.handleSwipe(_panDx, _panDy);
          }
        }
        _panDx = 0;
        _panDy = 0;
      },
      onPanCancel: () {
        _panDx = 0;
        _panDy = 0;
      },
      child: GameWidget(game: _game),
    );
    final h = widget.height;
    if (h != null) {
      return SizedBox(height: h, child: core);
    }
    return core;
  }
}
