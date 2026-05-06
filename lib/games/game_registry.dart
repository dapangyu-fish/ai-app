// 游戏场景注册表：scene 名 → 工厂函数。
//
// 用法（来自 flame_game_widget）:
//   final game = GameRegistry.create('tap_white_tile', params, onEvent);
//
// 加新游戏的流程：
// 1. 在 lib/games/scenes/ 加新文件，定义 FlameGame 子类
// 2. 在下面 _factories 表里加一行 mapping
// 3. JSON-APP 写 `{"type": "flame_game", "scene": "<新名字>"}` 即可使用
//
// 注意：JSON-APP 想用某个 scene，**客户端必须发版**包含对应代码。
// 老客户端会渲染成"未知 scene"占位（在 flame_game_widget.dart 里兜底）。

import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';

import 'scenes/tap_white_tile.dart';

/// 场景如果想接收外层 GestureDetector 转发的点击，实现这个接口。
/// flame_game widget 会做 `if (game is TappableScene) ... handleTap(...)` 兜底。
abstract class TappableScene {
  void handleTap(Offset position);
}

/// 场景工厂函数签名
typedef SceneFactory = FlameGame Function(
  Map<String, dynamic> params,
  void Function(String event, Map<String, dynamic> data) onEvent,
);

class GameRegistry {
  GameRegistry._();

  static final Map<String, SceneFactory> _factories = {
    'tap_white_tile': (params, onEvent) => TapWhiteTileScene(
          columnCount: (params['columns'] as num?)?.toInt() ?? 4,
          initialSpeed: (params['initialSpeed'] as num?)?.toDouble() ?? 180.0,
          speedAccel: (params['speedAccel'] as num?)?.toDouble() ?? 3.5,
          maxSpeed: (params['maxSpeed'] as num?)?.toDouble() ?? 600.0,
          initialBest: (params['initialBest'] as num?)?.toInt() ?? 0,
          onEvent: onEvent,
        ),
  };

  /// 工厂查表创建。scene 不存在返回 null —— 调用方负责画占位。
  static FlameGame? create(
    String scene,
    Map<String, dynamic> params,
    void Function(String event, Map<String, dynamic> data) onEvent,
  ) {
    final factory = _factories[scene];
    if (factory == null) return null;
    return factory(params, onEvent);
  }

  /// 已知的 scene 名（debug / 占位错误信息用）
  static List<String> get knownScenes => _factories.keys.toList();
}
