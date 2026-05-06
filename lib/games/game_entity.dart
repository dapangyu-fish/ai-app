// 游戏 entity —— 视觉 + 状态的最小单位。
//
// 5 种 kind：
// - cell:        单个网格格子（snake 的食物）
// - cell_path:   网格上的连续格子序列（snake 身体）
// - scroll_list: 垂直滚动的"行"序列（tap_white_tile 的下落砖块）
// - pixel:       自由像素位置 + 可选 velocity（保留接口，第一版没用到）
// - static:      固定像素位置的可视元素（保留接口）
//
// 每个 entity 自带 render() 把自己画到 canvas，update(dt) 处理自动行为
// （比如 scroll_list 的连续滚动）。entity 会把状态 toMap() 出来给
// `{{ entities.x.field }}` 模板读。

import 'dart:math';

import 'package:flutter/material.dart';

import 'game_world.dart';

abstract class GameEntity {
  final String id;
  final Map<String, dynamic> renderConfig;

  GameEntity({required this.id, required this.renderConfig});

  /// 自动行为（per-frame）
  void update(double dt, GameWorld world) {}

  /// 渲染
  void render(Canvas canvas, GameWorld world);

  /// 给 `{{ entities.x.field }}` 模板访问的快照
  Map<String, dynamic> toMap();
}

// ---------- cell ----------

class CellEntity extends GameEntity {
  int x;
  int y;

  CellEntity({
    required super.id,
    required super.renderConfig,
    required this.x,
    required this.y,
  });

  @override
  void render(Canvas canvas, GameWorld world) {
    drawShape(
      canvas,
      world.cellTopLeft(x, y),
      world.cellSize(),
      renderConfig,
    );
  }

  @override
  Map<String, dynamic> toMap() => {
        'x': x,
        'y': y,
        'cell': [x, y],
      };
}

// ---------- cell_path ----------

class CellPathEntity extends GameEntity {
  /// cells[0] 是 head，cells.last 是 tail
  final List<List<int>> cells;

  CellPathEntity({
    required super.id,
    required super.renderConfig,
    required this.cells,
  });

  List<int> get head => cells.first;
  List<int> get tail => cells.last;

  bool containsCell(int x, int y, {bool skipHead = false}) {
    for (int i = skipHead ? 1 : 0; i < cells.length; i++) {
      if (cells[i][0] == x && cells[i][1] == y) return true;
    }
    return false;
  }

  /// 把 head 按 direction 推一格（带 wrap），尾部 pop 掉。返回新 head。
  List<int> advance(String direction, GameWorld world) {
    final h = head;
    int dx = 0, dy = 0;
    switch (direction) {
      case 'up':
        dy = -1;
        break;
      case 'down':
        dy = 1;
        break;
      case 'left':
        dx = -1;
        break;
      case 'right':
        dx = 1;
        break;
    }
    final cols = world.cols == 0 ? 1 : world.cols;
    final rows = world.rows == 0 ? 1 : world.rows;
    final newHead = [
      ((h[0] + dx) % cols + cols) % cols,
      ((h[1] + dy) % rows + rows) % rows,
    ];
    cells.insert(0, newHead);
    cells.removeLast();
    return newHead;
  }

  /// 长一节（在尾部复制最后一格 —— 下次 advance 时不再 pop 它）
  void grow() {
    if (cells.isEmpty) return;
    final last = cells.last;
    cells.add([last[0], last[1]]);
  }

  @override
  void render(Canvas canvas, GameWorld world) {
    final baseColor =
        parseColor(renderConfig['color']) ?? const Color(0xFFFFFFFF);
    final padding = (renderConfig['padding'] as num?)?.toDouble() ?? 0;
    final radius = (renderConfig['radius'] as num?)?.toDouble() ?? 0;
    final shape = renderConfig['shape']?.toString() ?? 'rect';
    // 头亮尾暗的渐变开关
    final gradient = renderConfig['gradient'] == true;

    for (int i = 0; i < cells.length; i++) {
      final c = cells[i];
      final tl = world.cellTopLeft(c[0], c[1]);
      final size = world.cellSize();
      Color color = baseColor;
      if (gradient && cells.length > 1) {
        // 模仿 snake_game.dart 的渐变：头浅尾深
        final t = i / cells.length.clamp(1, 20);
        final r = baseColor.r;
        final g = baseColor.g;
        final b = baseColor.b;
        final factor = (1.0 - t * 0.8).clamp(0.2, 1.0);
        color = Color.fromARGB(
          255,
          (r * 255 * factor).round().clamp(0, 255),
          (g * 255 * factor).round().clamp(0, 255),
          (b * 255 * factor).round().clamp(0, 255),
        );
      }
      final cfg = Map<String, dynamic>.from(renderConfig);
      cfg['_paintColor'] = color;
      drawShape(
        canvas,
        tl,
        size,
        cfg,
        overrideColor: color,
        overridePadding: padding,
        overrideRadius: radius,
        overrideShape: shape,
      );
    }
  }

  @override
  Map<String, dynamic> toMap() => {
        'cells': cells,
        'head': head,
        'tail': tail,
        'length': cells.length,
      };
}

// ---------- scroll_list ----------

class ScrollListEntity extends GameEntity {
  /// 'down' 或 'up'
  final String scrollDirection;

  /// 当前速度（px/s）。可由 @scroll_list.set_speed 改。
  double speed;

  /// 行高（px）。固定值。
  double rowHeight;

  /// 行模板：每行有 cells（数量）、active_index_expr（如何计算"活跃"列）、render_active / render_inactive
  final Map<String, dynamic> rowSpec;

  /// 当前所有行
  final List<ScrollRow> rows;

  /// safe zone：最底下几行不生成 active（避免一开局就死）
  final int safeZoneBottom;

  /// 已穿过死亡线的"未点击"行触发后回调，由引擎判断（这里只暴露状态）
  /// 引擎用 @scroll_list.first_crossed_y 检测

  final Random _random = Random();

  ScrollListEntity({
    required super.id,
    required super.renderConfig,
    required this.scrollDirection,
    required this.speed,
    required this.rowHeight,
    required this.rowSpec,
    required this.rows,
    this.safeZoneBottom = 2,
  });

  @override
  void update(double dt, GameWorld world) {
    final dy = speed * dt * (scrollDirection == 'up' ? -1 : 1);
    for (final r in rows) {
      r.y += dy;
    }

    // 移除离开屏幕外的
    rows.removeWhere((r) {
      if (scrollDirection == 'down') {
        return r.y > world.height + rowHeight * 2;
      } else {
        return r.y < -rowHeight * 2;
      }
    });

    // 顶部不够时补充新行
    while (_needsSpawn(world)) {
      _spawnAtTop(world);
    }
  }

  bool _needsSpawn(GameWorld world) {
    if (scrollDirection == 'down') {
      if (rows.isEmpty) return true;
      return rows.first.y > -rowHeight * 4;
    } else {
      if (rows.isEmpty) return true;
      return rows.last.y < world.height + rowHeight * 4;
    }
  }

  void _spawnAtTop(GameWorld world) {
    final cells = (rowSpec['cells'] as num?)?.toInt() ?? 4;
    final newY = rows.isEmpty
        ? (scrollDirection == 'down' ? -rowHeight : world.height)
        : (scrollDirection == 'down'
            ? rows.first.y - rowHeight
            : rows.last.y + rowHeight);
    final activeIndex = _random.nextInt(cells);
    final row = ScrollRow(
      y: newY,
      activeIndex: activeIndex,
      cells: cells,
      tapped: false,
      missedChecked: false,
    );
    if (scrollDirection == 'down') {
      rows.insert(0, row);
    } else {
      rows.add(row);
    }
  }

  /// 提供给 @scroll_list.row_at_y 用：根据像素 y 找到所在行索引（-1 为没找到）
  int rowIndexAtY(double y) {
    for (int i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (y >= r.y && y < r.y + rowHeight) return i;
    }
    return -1;
  }

  @override
  void render(Canvas canvas, GameWorld world) {
    final cellsPerRow = (rowSpec['cells'] as num?)?.toInt() ?? 4;
    final cellW = world.width / cellsPerRow;
    final renderActive =
        (rowSpec['render_active'] as Map?)?.cast<String, dynamic>() ?? const {};
    final renderInactive = (rowSpec['render_inactive'] as Map?)
            ?.cast<String, dynamic>() ??
        const {};

    for (final r in rows) {
      // 跳过完全在屏幕外的行
      if (r.y + rowHeight < 0 || r.y > world.height) continue;
      for (int col = 0; col < cellsPerRow; col++) {
        final isActive = col == r.activeIndex;
        // tapped 之后变更暗色
        final cfg = isActive
            ? (r.tapped
                ? {
                    ...renderActive,
                    'color': renderActive['tapped_color'] ?? '#4A4A4A',
                  }
                : renderActive)
            : renderInactive;
        drawShape(
          canvas,
          Offset(col * cellW, r.y),
          Size(cellW, rowHeight),
          cfg,
        );
      }
    }
  }

  @override
  Map<String, dynamic> toMap() => {
        'speed': speed,
        'rowHeight': rowHeight,
        'rowCount': rows.length,
      };
}

class ScrollRow {
  double y;
  int activeIndex; // -1 表示无 active（safe zone）
  final int cells;
  bool tapped;
  bool missedChecked;

  ScrollRow({
    required this.y,
    required this.activeIndex,
    required this.cells,
    this.tapped = false,
    this.missedChecked = false,
  });
}

// ---------- 渲染 helper ----------

void drawShape(
  Canvas canvas,
  Offset topLeft,
  Size size,
  Map<String, dynamic> cfg, {
  Color? overrideColor,
  double? overridePadding,
  double? overrideRadius,
  String? overrideShape,
  String? text,
}) {
  final shape = overrideShape ?? cfg['shape']?.toString() ?? 'rect';
  final color =
      overrideColor ?? parseColor(cfg['color']) ?? const Color(0xFFFFFFFF);
  final padding = overridePadding ?? (cfg['padding'] as num?)?.toDouble() ?? 0;

  final rect = Rect.fromLTWH(
    topLeft.dx + padding,
    topLeft.dy + padding,
    size.width - padding * 2,
    size.height - padding * 2,
  );

  switch (shape) {
    case 'rect':
      final radius = overrideRadius ?? (cfg['radius'] as num?)?.toDouble() ?? 0;
      if (radius > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(radius)),
          Paint()..color = color,
        );
      } else {
        canvas.drawRect(rect, Paint()..color = color);
      }
      break;
    case 'circle':
      canvas.drawCircle(
        rect.center,
        rect.shortestSide / 2,
        Paint()..color = color,
      );
      break;
    case 'text':
      final value = text ?? cfg['value']?.toString() ?? '';
      final fontSize = (cfg['fontSize'] as num?)?.toDouble() ?? 16;
      final tp = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, rect.topLeft);
      break;
  }
}
