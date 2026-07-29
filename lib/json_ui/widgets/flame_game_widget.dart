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
import '../asset_manager.dart';
import '../compute/compute_session.dart';
import '../interpreter.dart';
import 'base_widget.dart';

class JsonFlameGameWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    // 把 spec 里的 "{{ global.x }}" 等外层模板烤一遍（init 时一次性）
    // —— 注意：游戏内部用的 "{{ vars.x }}" 等仍然由游戏 logic 引擎自己解析
    final bakedSpec = _bakeOuterTemplates(json, interpreter);

    return _FlameGameMount(
      spec: bakedSpec,
      sourceSpecIdentity: json,
      interpreter: interpreter,
      appScopeIdentity: interpreter.appScopeIdentity,
      appScopeDepth: interpreter.appScopeDepth,
      computeSession: interpreter.computeSession,
      assetManager: JsonAppAssetManager.fromConfig(
        interpreter.rawConfig ?? const <String, dynamic>{},
      ),
      height: (json['height'] as num?)?.toDouble(),
    );
  }

  @visibleForTesting
  Map<String, dynamic> bakeOuterTemplatesForTest(
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return _bakeOuterTemplates(json, interpreter);
  }

  /// 只烤外层（global.*）模板，保留游戏内部命名空间
  /// （vars.* / event.* / entities.* / world.* / loop.*）。
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

  dynamic _resolveOuterOnly(String s, JsonInterpreter interpreter) {
    final regex = RegExp(r'\{\{\s*([^}]+?)\s*\}\}');
    final fullMatch = RegExp(r'^\s*\{\{\s*([^}]+?)\s*\}\}\s*$').firstMatch(s);
    if (fullMatch != null) {
      final expr = fullMatch.group(1)!.trim();
      if (_isGameInternalExpression(expr)) return s;
      return interpreter.getVariable(expr);
    }
    return s.replaceAllMapped(regex, (m) {
      final expr = m.group(1)!.trim();
      // 内部命名空间 —— 留给游戏 logic 自己解析
      if (_isGameInternalExpression(expr)) {
        return m.group(0)!; // 原样返回
      }
      // 外层 —— 用主 interpreter 求值
      final v = interpreter.getVariable(expr);
      return v?.toString() ?? '';
    });
  }

  bool _isGameInternalExpression(String expr) {
    return expr == 'vars' ||
        expr.startsWith('vars.') ||
        expr == 'event' ||
        expr.startsWith('event.') ||
        expr == 'entities' ||
        expr.startsWith('entities.') ||
        expr == 'world' ||
        expr.startsWith('world.') ||
        expr == 'loop' ||
        expr.startsWith('loop.') ||
        expr == 'score' ||
        expr == 'best' ||
        expr == 'game_over';
  }
}

class _FlameGameMount extends StatefulWidget {
  final Map<String, dynamic> spec;
  final Object sourceSpecIdentity;
  final JsonInterpreter interpreter;
  final Object appScopeIdentity;
  final int appScopeDepth;
  final ComputeSession? computeSession;
  final JsonAppAssetManager assetManager;
  final double? height;

  const _FlameGameMount({
    required this.spec,
    required this.sourceSpecIdentity,
    required this.interpreter,
    required this.appScopeIdentity,
    required this.appScopeDepth,
    required this.computeSession,
    required this.assetManager,
    this.height,
  });

  @override
  State<_FlameGameMount> createState() => _FlameGameMountState();
}

class _FlameGameMountState extends State<_FlameGameMount> {
  late JsonFlameGame _game;
  late _FlameGameMount _boundWidget;
  late JsonInterpreter _registeredInterpreter;
  var _bindingGeneration = 1;

  // 一次手势内累积位移，松手时一次性发 swipe
  double _panDx = 0;
  double _panDy = 0;

  // 按住起始时刻 — 给 input.press_end 算 held_ms
  DateTime? _pressDownTime;

  late final void Function() _resetter;
  late final void Function(String, Map<String, dynamic>) _inputHandler;

  @override
  void initState() {
    super.initState();
    _boundWidget = widget;
    _registeredInterpreter = widget.interpreter;
    _game = _createGame(widget, _bindingGeneration);
    // 单 interpreter 的嵌套 App 会让父/子游戏同时留在 Navigator 栈中。
    // 只有当前 app scope 的 game 才响应外层广播；普通 dialog / popup
    // 不会改变 scope，结算弹窗里的“再来一局”仍需能重置当前游戏。
    _resetter = () {
      if (_isBoundScopeActive()) _game.resetGame();
    };
    _inputHandler = (name, data) {
      if (_isBoundScopeActive()) _game.handleNamedInput(name, data);
    };
    _registerHandlers();
  }

  @override
  void didUpdateWidget(covariant _FlameGameMount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_matchesBoundIdentity(widget)) return;

    // @launch_app 会先 load 子 App、执行 steps，之后才 push 新 route。
    // 这段窗口里父 route 仍是 current；depth 闸阻止它误绑定子 App。
    if (widget.appScopeDepth != _boundWidget.appScopeDepth) return;

    final nextGeneration = _bindingGeneration + 1;
    final nextGame = _createGame(widget, nextGeneration);
    _unregisterHandlers();
    final previousGame = _game;
    _boundWidget = widget;
    _bindingGeneration = nextGeneration;
    _game = nextGame;
    _registeredInterpreter = widget.interpreter;
    _registerHandlers();
    previousGame.disposeGame();
  }

  @override
  void dispose() {
    _bindingGeneration++;
    _unregisterHandlers();
    _game.disposeGame();
    super.dispose();
  }

  JsonFlameGame _createGame(_FlameGameMount owner, int generation) {
    return JsonFlameGame(
      spec: owner.spec,
      assetManager: owner.assetManager,
      computeSession: owner.computeSession,
      onEvent: (event, data) => _dispatchEvent(owner, generation, event, data),
    );
  }

  bool _matchesBoundIdentity(_FlameGameMount candidate) {
    return identical(
          candidate.appScopeIdentity,
          _boundWidget.appScopeIdentity,
        ) &&
        identical(
          candidate.sourceSpecIdentity,
          _boundWidget.sourceSpecIdentity,
        ) &&
        identical(candidate.computeSession, _boundWidget.computeSession);
  }

  bool _isBoundScopeActive() {
    return mounted &&
        _registeredInterpreter.appScopeDepth == _boundWidget.appScopeDepth &&
        identical(
          _registeredInterpreter.appScopeIdentity,
          _boundWidget.appScopeIdentity,
        );
  }

  void _registerHandlers() {
    _registeredInterpreter.registerFlameGameResetter(_resetter);
    _registeredInterpreter.registerFlameGameInputHandler(_inputHandler);
  }

  void _unregisterHandlers() {
    _registeredInterpreter.unregisterFlameGameResetter(_resetter);
    _registeredInterpreter.unregisterFlameGameInputHandler(_inputHandler);
  }

  /// 游戏事件 → JSON-APP 的 on_xxx 回调
  void _dispatchEvent(
    _FlameGameMount owner,
    int generation,
    String event,
    Map<String, dynamic> data,
  ) {
    if (generation != _bindingGeneration || !_isBoundScopeActive()) return;
    final action = owner.spec['on_$event'];
    if (action is! Map<String, dynamic>) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _bindingGeneration || !_isBoundScopeActive()) return;
      owner.interpreter
          .executeActionWithEvent(action, context, data)
          .catchError((e, st) {
            debugPrint('[flame_game] on_$event 抛错: $e');
          });
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
    final h = _boundWidget.height;
    if (h != null) {
      return SizedBox(height: h, child: core);
    }
    return core;
  }
}
