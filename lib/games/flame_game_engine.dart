// JsonFlameGame —— 把 JSON spec 烧成一个可跑的 FlameGame。
//
// 跑起来后职责：
// 1. 维护 world / entities / vars / score / game_over 状态
// 2. update(dt): 推 entity 自动行为 → 跑 frame.logic → 跑 tick(s).logic
// 3. render():   背景 → 网格线 → entities → 顶部分数 → game_over 蒙层
// 4. 输入：tap / pan 按 JSON 注册的 input.tap / input.swipe action 跑
// 5. emit 事件给外层 widget（onScoreChanged / onGameOver）让 JSON-APP 接

import 'dart:math';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'game_entity.dart';
import 'game_logic.dart';
import 'game_world.dart';

/// 事件回调签名（跟 A 模式一致，外层 widget 把事件桥到 JSON-DSL action）
typedef GameEventCallback = void Function(
    String eventName, Map<String, dynamic> data);

/// tick 循环
class _TickLoop {
  /// interval 可能是 "{{ vars.tick_interval }}"，每次重新求值
  final dynamic intervalSpec;
  final List<dynamic> logic;
  double accumulator = 0;

  _TickLoop({required this.intervalSpec, required this.logic});
}

/// JsonFlameGame 不直接 mixin Flame 的 TapDetector / PanDetector ——
/// 那俩在不同 Flame 版本 API 不稳定（1.37 重构）。改成由外层 widget
/// 包 GestureDetector，调下面的 [handleTap] / [handleSwipe]。
class JsonFlameGame extends FlameGame {
  /// 整份 game spec（type=flame_game 节点的全部内容）
  final Map<String, dynamic> spec;

  /// 外部回调（emit 给 JSON-APP）
  final GameEventCallback? onEvent;

  // ---- 运行时状态 ----
  /// 我们的世界定义（命名 gameWorld 避免跟 FlameGame.world 冲突 —— 后者
  /// 是 camera scene root 的 World 组件，不是我们要的坐标系抽象）
  late final GameWorld gameWorld;
  final Map<String, GameEntity> entities = {};
  final Map<String, dynamic> vars = {};

  int score = 0;
  int bestScore = 0;
  bool isGameOver = false;

  late final GameLogicEngine logic;

  // 输入 / 循环
  List<dynamic>? _tapAction;
  List<dynamic>? _swipeAction;
  List<dynamic>? _panAction;
  List<dynamic>? _frameLogic;

  // swipe 的离散触发阈值（像素）—— JSON 可在 input.swipe_threshold 里覆盖
  double _swipeThreshold = 16;
  final List<_TickLoop> _ticks = [];

  // 内置 overlay 配置
  bool _showScore = true;
  String _gameOverTitle = '游戏结束';
  String _gameOverHint = '点击重新开始';

  JsonFlameGame({required this.spec, this.onEvent}) {
    // ⚠️ 必须在构造函数里同步完成所有 spec 解析。
    //
    // 原因：Flame 的 onGameResize 可能在 onLoad（async）之前被调，
    // 那时 late field 没初始化 → LateInitializationError。
    // 反正 spec 解析全是同步的，挪到构造函数里更稳。
    gameWorld = GameWorld.fromJson(spec['world'] as Map<String, dynamic>?);
    logic = GameLogicEngine(this);
    _setupFromSpec();
  }

  bool _ready = false;

  // ---------- 生命周期 ----------
  // 所有 spec 解析在构造函数里做完了，onLoad 留空。Entities 在第一次
  // onGameResize 拿到有效 size 时才铺（scroll_list 等依赖画布尺寸）。

  @override
  Future<void> onLoad() async {}

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    gameWorld.resize(size.x, size.y);
    // 第一次拿到有效画布尺寸时才铺 entities（scroll_list 等依赖 size）
    if (!_ready && size.x > 0 && size.y > 0) {
      _ready = true;
      _resetGameState();
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_ready) return;
    if (isGameOver) return;

    // 1. entity 自动行为
    for (final e in entities.values) {
      e.update(dt, gameWorld);
    }

    // 2. frame logic
    if (_frameLogic != null) {
      logic.runLogic(_frameLogic!);
      if (isGameOver) return;
    }

    // 3. tick loops
    for (final t in _ticks) {
      t.accumulator += dt;
      // 每次取 interval（让 "{{ vars.tick_interval }}" 可动态变化）
      final iv = (logic.resolveExpression(t.intervalSpec) as num?)?.toDouble() ?? 0.16;
      while (t.accumulator >= iv && !isGameOver) {
        t.accumulator -= iv;
        logic.runLogic(t.logic);
      }
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (!_ready) return;

    // 背景
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = gameWorld.bg,
    );

    // 网格线（grid 模式 + 配了 grid_lines 才画）
    if (gameWorld.kind == 'grid' && gameWorld.gridLines != null) {
      _drawGridLines(canvas);
    }

    // entities
    for (final e in entities.values) {
      e.render(canvas, gameWorld);
    }

    // 内置 overlay
    if (_showScore) _drawScoreOverlay(canvas);
    if (isGameOver) _drawGameOverOverlay(canvas);
  }

  // ---------- 输入（由外层 widget 的 GestureDetector 调进来） ----------

  /// 外层 GestureDetector.onTapDown 转过来
  void handleTap(double x, double y) {
    if (!_ready) return;
    if (isGameOver) {
      resetGame();
      return;
    }
    if (_tapAction != null) {
      logic.runLogic(_tapAction!, {'x': x, 'y': y});
    }
  }

  /// 离散 swipe：一次手势结束时被外层调一次（accumulated dx/dy）
  void handleSwipe(double dx, double dy) {
    if (!_ready) return;
    if (isGameOver) {
      // 滑动也能重开
      resetGame();
      return;
    }
    if (_swipeAction != null) {
      final dir = _swipeDirection(dx, dy);
      if (dir == null) return;
      logic.runLogic(_swipeAction!, {
        'direction': dir,
        'dx': dx,
        'dy': dy,
      });
    }
  }

  /// 连续 pan：每一帧 onPanUpdate 都被调（per-frame delta）
  void handlePan(double dx, double dy) {
    if (!_ready) return;
    if (isGameOver) return;
    if (_panAction != null) {
      logic.runLogic(_panAction!, {
        'dx': dx,
        'dy': dy,
      });
    }
  }

  bool get hasSwipe => _swipeAction != null;
  bool get hasPan => _panAction != null;
  double get swipeThreshold => _swipeThreshold;

  String? _swipeDirection(double dx, double dy) {
    final adx = dx.abs();
    final ady = dy.abs();
    if (adx < 0.5 && ady < 0.5) return null;
    if (adx > ady) {
      return dx > 0 ? 'right' : 'left';
    } else {
      return dy > 0 ? 'down' : 'up';
    }
  }

  // ---------- 公开 API（GameActions 调） ----------

  void setScore(int v) {
    if (v == score) return;
    score = v;
    if (score > bestScore) bestScore = score;
    onEvent?.call('scoreChanged', {'score': score, 'best': bestScore});
  }

  void triggerGameOver() {
    if (isGameOver) return;
    isGameOver = true;
    if (score > bestScore) bestScore = score;
    onEvent?.call('gameOver', {'score': score, 'best': bestScore});
  }

  void resetGame() => _resetGameState();

  // ---------- 解析 spec ----------

  void _setupFromSpec() {
    // gameWorld 已在构造函数里 init 了，这里只解析剩下的部分

    // input
    final input = spec['input'] as Map<String, dynamic>?;
    _tapAction = _toLogicList(input?['tap']);
    _swipeAction = _toLogicList(input?['swipe']);
    _panAction = _toLogicList(input?['pan']);
    final th = (input?['swipe_threshold'] as num?)?.toDouble();
    if (th != null && th > 0) _swipeThreshold = th;

    // frame
    final frame = spec['frame'] as Map<String, dynamic>?;
    _frameLogic = _toLogicList(frame?['logic']);

    // ticks
    _ticks.clear();
    final ticksRaw = spec['tick'];
    if (ticksRaw is Map<String, dynamic>) {
      _ticks.add(_TickLoop(
        intervalSpec: ticksRaw['interval'],
        logic: _toLogicList(ticksRaw['logic']) ?? const [],
      ));
    } else if (ticksRaw is List) {
      for (final t in ticksRaw) {
        if (t is Map<String, dynamic>) {
          _ticks.add(_TickLoop(
            intervalSpec: t['interval'],
            logic: _toLogicList(t['logic']) ?? const [],
          ));
        }
      }
    }

    // overlay 配置
    final ov = spec['overlay'] as Map<String, dynamic>?;
    if (ov != null) {
      _showScore = ov['score'] != false;
      _gameOverTitle = ov['game_over_title']?.toString() ?? _gameOverTitle;
      _gameOverHint = ov['game_over_hint']?.toString() ?? _gameOverHint;
    }
  }

  List<dynamic>? _toLogicList(dynamic raw) {
    if (raw == null) return null;
    if (raw is List) return raw;
    if (raw is Map) return [raw]; // 单个 action 也接受
    return null;
  }

  void _resetGameState() {
    score = 0;
    isGameOver = false;
    vars.clear();

    // vars 初始值（spec.vars 里 "{{ ... }}" 用外层 game spec 的 best 等求值
    // —— 但此时还没玩家分数，先简单 resolve 成原始值即可）
    final rawVars = (spec['vars'] as Map?)?.cast<String, dynamic>() ?? {};
    rawVars.forEach((k, v) {
      vars[k] = logic.resolveExpression(v);
    });

    // entities
    entities.clear();
    final ents = (spec['entities'] as Map?)?.cast<String, dynamic>() ?? {};
    ents.forEach((id, raw) {
      final ent = _buildEntity(id, raw as Map<String, dynamic>);
      if (ent != null) entities[id] = ent;
    });

    // 重置 tick 累积器
    for (final t in _ticks) {
      t.accumulator = 0;
    }

    // init.logic：entities 建好后跑一次的初始化（典型用途：开局 spawn 几个 tile）
    final initSpec = spec['init'] as Map<String, dynamic>?;
    final initLogic = initSpec?['logic'];
    if (initLogic is List) {
      logic.runLogic(initLogic);
    }

    onEvent?.call('reset', {'score': 0, 'best': bestScore});
  }

  GameEntity? _buildEntity(String id, Map<String, dynamic> spec) {
    final kind = spec['kind']?.toString() ?? 'cell';
    final renderRaw = (spec['render'] as Map?)?.cast<String, dynamic>() ?? const {};
    final render = renderRaw.map((k, v) => MapEntry(k, v));

    switch (kind) {
      case 'cell':
        {
          final initRaw = spec['init'];
          int x = 0, y = 0;
          if (initRaw is List && initRaw.length == 2) {
            x = (initRaw[0] as num).toInt();
            y = (initRaw[1] as num).toInt();
          }
          return CellEntity(id: id, renderConfig: render, x: x, y: y);
        }
      case 'cell_path':
        {
          final initRaw = spec['init'];
          final cells = <List<int>>[];
          if (initRaw is List) {
            for (final c in initRaw) {
              if (c is List && c.length == 2) {
                cells.add([(c[0] as num).toInt(), (c[1] as num).toInt()]);
              }
            }
          }
          return CellPathEntity(id: id, renderConfig: render, cells: cells);
        }
      case 'value_grid':
        {
          final cols = (spec['cols'] as num?)?.toInt() ?? 4;
          final rows = (spec['rows'] as num?)?.toInt() ?? 4;
          final fill =
              (spec['fill'] as num?)?.toInt() ?? 0; // 默认空 (0)
          final cells = <List<int>>[];
          final initRaw = spec['init'];
          for (int r = 0; r < rows; r++) {
            final row = <int>[];
            for (int c = 0; c < cols; c++) {
              int v = fill;
              if (initRaw is List &&
                  r < initRaw.length &&
                  initRaw[r] is List &&
                  c < (initRaw[r] as List).length) {
                v = ((initRaw[r] as List)[c] as num?)?.toInt() ?? fill;
              }
              row.add(v);
            }
            cells.add(row);
          }
          return ValueGridEntity(
            id: id,
            renderConfig: render,
            cols: cols,
            rows: rows,
            cells: cells,
          );
        }
      case 'scroll_list':
        {
          final scrollDir = spec['direction']?.toString() ?? 'down';
          final speed = (spec['speed'] as num?)?.toDouble() ?? 180;
          final rowSpec =
              (spec['row_spec'] as Map?)?.cast<String, dynamic>() ?? const {};
          final cellsPerRow = (rowSpec['cells'] as num?)?.toInt() ?? 4;
          // 默认行高 = 画布宽度 / 列数（方块），用户也可显式 row_height 覆盖
          final rowHeight = (spec['row_height'] as num?)?.toDouble() ??
              (this.size.x > 0 ? this.size.x / cellsPerRow : 95);
          final safeBottom = (spec['safe_zone_bottom'] as num?)?.toInt() ?? 2;
          // 初始铺一些行
          final rows = <ScrollRow>[];
          final rand = Random();
          if (this.size.x > 0 && this.size.y > 0) {
            double y = -rowHeight * 5;
            while (y < this.size.y + rowHeight) {
              final inSafe = (this.size.y - rowHeight * safeBottom) <= y;
              rows.add(ScrollRow(
                y: y,
                activeIndex: inSafe ? -1 : rand.nextInt(cellsPerRow),
                cells: cellsPerRow,
                missedChecked: y >= this.size.y - rowHeight,
              ));
              y += rowHeight;
            }
          }
          return ScrollListEntity(
            id: id,
            renderConfig: render,
            scrollDirection: scrollDir,
            speed: speed,
            rowHeight: rowHeight,
            rowSpec: rowSpec,
            rows: rows,
            safeZoneBottom: safeBottom,
          );
        }
    }
    return null;
  }

  // ---------- 内置 overlay ----------

  void _drawGridLines(Canvas canvas) {
    final p = Paint()
      ..color = gameWorld.gridLines!
      ..strokeWidth = 0.5;
    for (int i = 1; i < gameWorld.cols; i++) {
      canvas.drawLine(
        Offset(i * gameWorld.cellW, 0),
        Offset(i * gameWorld.cellW, size.y),
        p,
      );
    }
    for (int j = 1; j < gameWorld.rows; j++) {
      canvas.drawLine(
        Offset(0, j * gameWorld.cellH),
        Offset(size.x, j * gameWorld.cellH),
        p,
      );
    }
  }

  void _drawScoreOverlay(Canvas canvas) {
    _drawText(
      canvas,
      '$score',
      36,
      const Color(0xCCFFFFFF),
      Offset(size.x / 2, 18),
      centered: true,
    );
    if (bestScore > 0) {
      _drawText(
        canvas,
        '最佳 $bestScore',
        14,
        const Color(0x66FFFFFF),
        Offset(size.x / 2, 52),
        centered: true,
      );
    }
  }

  void _drawGameOverOverlay(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = const Color(0x88000000),
    );
    final boxRect = Rect.fromLTWH(
      size.x / 2 - 130,
      size.y / 2 - 100,
      260,
      200,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(16)),
      Paint()..color = const Color(0xDD333333),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(16)),
      Paint()
        ..color = const Color(0x44FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    _drawText(canvas, _gameOverTitle, 40, const Color(0xFFFF5555),
        Offset(size.x / 2, size.y / 2 - 60),
        centered: true);
    _drawText(canvas, '得分 $score', 26, Colors.white70,
        Offset(size.x / 2, size.y / 2 - 10),
        centered: true);
    if (bestScore > 0) {
      _drawText(canvas, '最佳 $bestScore', 16, const Color(0x88FFFFFF),
          Offset(size.x / 2, size.y / 2 + 25),
          centered: true);
    }
    _drawText(canvas, _gameOverHint, 16, const Color(0x66FFFFFF),
        Offset(size.x / 2, size.y / 2 + 60),
        centered: true);
  }

  void _drawText(
    Canvas canvas,
    String text,
    double fontSize,
    Color color,
    Offset pos, {
    bool centered = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final offset =
        centered ? pos - Offset(tp.width / 2, tp.height / 2) : pos;
    tp.paint(canvas, offset);
  }
}
