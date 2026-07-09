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
import 'package:flutter/services.dart';

import '../../games/flame_game_engine.dart';
import '../asset_manager.dart';
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
      interpreter: interpreter,
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
  final JsonInterpreter interpreter;
  final JsonAppAssetManager assetManager;
  final double? height;

  const _FlameGameMount({
    required this.spec,
    required this.interpreter,
    required this.assetManager,
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

  // 键盘映射（可选）：物理按键 → 命名输入基名。按下发 "<base>_down"，
  // 松开发 "<base>_up"，与屏幕手柄 gesture_detector 走同一套输入名。
  // 只有 spec 里声明了 keymap 才启用（其它游戏零影响）。
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'flame_game_keyboard');
  late final Map<LogicalKeyboardKey, String> _keyBindings;

  late final void Function() _resetter;
  late final void Function(String, Map<String, dynamic>) _inputHandler;

  @override
  void initState() {
    super.initState();
    _game = JsonFlameGame(
      spec: widget.spec,
      assetManager: widget.assetManager,
      onEvent: _dispatchEvent,
    );
    _keyBindings = _buildKeyBindings(widget.spec['keymap']);
    // 注册到 interpreter，让 @flame_game_reset 这个 action 能找到我们
    _resetter = () => _game.resetGame();
    _inputHandler = (name, data) => _game.handleNamedInput(name, data);
    widget.interpreter.registerFlameGameResetter(_resetter);
    widget.interpreter.registerFlameGameInputHandler(_inputHandler);
  }

  @override
  void dispose() {
    widget.interpreter.unregisterFlameGameResetter(_resetter);
    widget.interpreter.unregisterFlameGameInputHandler(_inputHandler);
    _keyboardFocus.dispose();
    _game.disposeGame();
    super.dispose();
  }

  /// spec.keymap: { "<按键名>": "<输入基名>" }。按键名支持 up/down/left/right、
  /// enter/space/shift/ctrl/tab/escape 等，以及单个字母/数字（如 "z" "x" "1"）。
  static Map<LogicalKeyboardKey, String> _buildKeyBindings(dynamic keymap) {
    final out = <LogicalKeyboardKey, String>{};
    if (keymap is Map) {
      keymap.forEach((k, v) {
        final key = _lookupKey(k.toString());
        if (key != null) out[key] = v.toString();
      });
    }
    return out;
  }

  static const Map<String, LogicalKeyboardKey> _specialKeys = {
    'up': LogicalKeyboardKey.arrowUp,
    'down': LogicalKeyboardKey.arrowDown,
    'left': LogicalKeyboardKey.arrowLeft,
    'right': LogicalKeyboardKey.arrowRight,
    'enter': LogicalKeyboardKey.enter,
    'return': LogicalKeyboardKey.enter,
    'space': LogicalKeyboardKey.space,
    'shift': LogicalKeyboardKey.shiftLeft,
    'shiftright': LogicalKeyboardKey.shiftRight,
    'ctrl': LogicalKeyboardKey.controlLeft,
    'alt': LogicalKeyboardKey.altLeft,
    'tab': LogicalKeyboardKey.tab,
    'escape': LogicalKeyboardKey.escape,
    'backspace': LogicalKeyboardKey.backspace,
  };

  static LogicalKeyboardKey? _lookupKey(String name) {
    final n = name.trim().toLowerCase();
    final special = _specialKeys[n];
    if (special != null) return special;
    if (n.length == 1) {
      final c = n.codeUnitAt(0);
      // a-z (0x61..0x7A) / 0-9 (0x30..0x39) → LogicalKeyboardKey.keyId 与 ASCII 同值
      if ((c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)) {
        return LogicalKeyboardKey(c);
      }
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final base = _keyBindings[event.logicalKey];
    if (base == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _game.handleNamedInput('${base}_down', const {});
    } else if (event is KeyUpEvent) {
      _game.handleNamedInput('${base}_up', const {});
    }
    // KeyRepeatEvent 及已处理的 down/up 都吞掉，避免方向键/空格滚动页面
    return KeyEventResult.handled;
  }

  /// 游戏事件 → JSON-APP 的 on_xxx 回调
  void _dispatchEvent(String event, Map<String, dynamic> data) {
    if (!mounted) return;
    final action = widget.spec['on_$event'];
    if (action is! Map<String, dynamic>) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.interpreter
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
        if (_keyBindings.isNotEmpty) _keyboardFocus.requestFocus();
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
    // 声明了 keymap 才挂键盘监听（桌面/web 用），并抢焦点接收按键。
    final Widget interactive = _keyBindings.isEmpty
        ? core
        : Focus(
            focusNode: _keyboardFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: core,
          );
    final h = widget.height;
    if (h != null) {
      return SizedBox(height: h, child: interactive);
    }
    return interactive;
  }
}
