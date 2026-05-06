// `flame_game` 控件 —— 把一个 FlameGame 实例嵌进 JSON-DSL 渲染的 widget 树。
//
// JSON 形态：
//   {
//     "type": "flame_game",
//     "scene": "tap_white_tile",
//     "params": { "columns": 4, "initialSpeed": 180, ... },
//     "onScoreChanged": { "call": "@set", "args": {"var": "global.score", "value": "{{ event.score }}"} },
//     "onGameOver":     { "call": "@global.handleGameOver", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"} },
//     "height": 600
//   }
//
// 设计要点：
// - StatefulWidget 持有 game 实例 + 跟 interpreter 解耦，避免父级 setState 杀掉游戏
// - on{EventName} 在配置里大写驼峰（onScoreChanged），dispatch 时按事件名查表
// - 通过 [JsonInterpreter.executeActionWithEvent] 把 payload 注入 `{{ event.* }}`
// - 接 [TappableScene] 的 scene 自动用 GestureDetector 转发 tap 坐标
// - 未知 scene 名 → 占位红框 + 已知 scene 列表，方便排查

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../../games/game_registry.dart';
import '../interpreter.dart';
import 'base_widget.dart';

class JsonFlameGameWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final scene = json['scene']?.toString() ?? '';
    if (scene.isEmpty) {
      return _placeholder('flame_game 缺少 scene 字段');
    }

    // params 里允许使用 "{{ ... }}" 模板，build 时一次性烤死
    final rawParams = (json['params'] as Map?) ?? const {};
    final resolvedParams = <String, dynamic>{};
    rawParams.forEach((k, v) {
      resolvedParams[k.toString()] = v is String
          ? interpreter.resolveExpression(v)
          : v;
    });

    return _FlameGameMount(
      scene: scene,
      params: resolvedParams,
      eventActions: _extractEventActions(json),
      interpreter: interpreter,
      height: (json['height'] as num?)?.toDouble(),
    );
  }

  /// 从 JSON 里抠出所有 `onXxx` 形式的回调，转成 `xxx` (lowerCamel) → action。
  /// 例：onScoreChanged → 'scoreChanged' → 该 action
  Map<String, Map<String, dynamic>> _extractEventActions(
      Map<String, dynamic> json) {
    final out = <String, Map<String, dynamic>>{};
    json.forEach((k, v) {
      if (k.length > 2 && k.startsWith('on') && v is Map<String, dynamic>) {
        final eventName = k.substring(2, 3).toLowerCase() + k.substring(3);
        out[eventName] = v;
      }
    });
    return out;
  }

  Widget _placeholder(String msg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x33FF3333),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFFF3333)),
      ),
      child: Text(
        '$msg\n已知 scene: ${GameRegistry.knownScenes.join(", ")}',
        style: const TextStyle(color: Color(0xFFFF3333), fontSize: 12),
      ),
    );
  }
}

class _FlameGameMount extends StatefulWidget {
  final String scene;
  final Map<String, dynamic> params;
  final Map<String, Map<String, dynamic>> eventActions;
  final JsonInterpreter interpreter;
  final double? height;

  const _FlameGameMount({
    required this.scene,
    required this.params,
    required this.eventActions,
    required this.interpreter,
    this.height,
  });

  @override
  State<_FlameGameMount> createState() => _FlameGameMountState();
}

class _FlameGameMountState extends State<_FlameGameMount> {
  FlameGame? _game;

  @override
  void initState() {
    super.initState();
    _game = GameRegistry.create(
      widget.scene,
      widget.params,
      _dispatchEvent,
    );
  }

  void _dispatchEvent(String event, Map<String, dynamic> data) {
    final action = widget.eventActions[event];
    if (action == null) return;
    if (!mounted) return;
    // 异步 fire-and-forget；event 栈在 await 期间保持
    widget.interpreter
        .executeActionWithEvent(action, context, data)
        .catchError((e, st) {
      debugPrint('[flame_game] $event action 抛错: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final game = _game;
    if (game == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x33FF3333),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFFF3333)),
        ),
        child: Text(
          '未知 scene: ${widget.scene}\n已知: ${GameRegistry.knownScenes.join(", ")}',
          style: const TextStyle(color: Color(0xFFFF3333), fontSize: 12),
        ),
      );
    }

    final core = GameWidget(game: game);
    final tappable = game is TappableScene
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) =>
                (game as TappableScene).handleTap(d.localPosition),
            child: core,
          )
        : core;

    final height = widget.height;
    if (height != null) {
      return SizedBox(height: height, child: tappable);
    }
    // 没显式给 height → 用 Expanded-style 占满父级；如果父级没约束会出问题，
    // 但跟 list / video 这些等宽度/高度控件已有的语义一致（由 JSON 作者负责）
    return tappable;
  }
}
