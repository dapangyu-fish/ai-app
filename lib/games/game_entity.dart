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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'game_world.dart';

abstract class GameEntity {
  final String id;
  final Map<String, dynamic> renderConfig;
  final int priority;

  GameEntity({
    required this.id,
    required this.renderConfig,
    this.priority = 0,
  });

  /// 自动行为（per-frame）
  void update(double dt, GameWorld world) {}

  /// 渲染
  void render(Canvas canvas, GameWorld world);

  /// 给 `{{ entities.x.field }}` 模板访问的快照
  Map<String, dynamic> toMap();

  bool get expired => false;
}

abstract class ImageBackedEntity {
  String get asset;
  set image(ui.Image? value);
}

// ---------- cell ----------

class CellEntity extends GameEntity {
  int x;
  int y;

  CellEntity({
    required super.id,
    required super.renderConfig,
    super.priority,
    required this.x,
    required this.y,
  });

  @override
  void render(Canvas canvas, GameWorld world) {
    drawShape(canvas, world.cellTopLeft(x, y), world.cellSize(), renderConfig);
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
    super.priority,
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

// ---------- pixel ----------
//
// 自由像素 entity：position + size + velocity。每帧自动 position += velocity * dt。
// 通用语义，不绑定任何具体游戏。可以做：
// - 单一角色（玩家、鸟、子弹）—— init velocity=[0,0]，逻辑层动态改
// - 自动滚动的障碍物 —— init velocity=[-100,0]，自动飘出屏
// - 抛物运动 —— 逻辑层每帧 add_velocity([0, gravity])
//
// render 走 drawShape，支持 rect / circle / text（包括 emoji）。

class PixelEntity extends GameEntity {
  double x;
  double y;
  double w;
  double h;
  double vx;
  double vy;
  bool autoMove;
  final Map<String, dynamic> state;

  PixelEntity({
    required super.id,
    required super.renderConfig,
    super.priority,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.vx = 0,
    this.vy = 0,
    this.autoMove = true,
    Map<String, dynamic>? state,
  }) : state = state ?? {};

  @override
  void update(double dt, GameWorld world) {
    if (!autoMove) return;
    _updatePath(dt);
    x += vx * dt;
    y += vy * dt;
  }

  void _updatePath(double dt) {
    final path = state['path']?.toString();
    if (path == null || path.isEmpty || dt <= 0) return;
    final segments = _pathSegments(path);
    if (segments.isEmpty) return;

    state['pathOriginX'] ??= x;
    state['pathOriginY'] ??= y;
    state['pathIndex'] ??= 0;
    state['pathProgress'] ??= 0.0;

    final tile = (state['pathTile'] as num?)?.toDouble() ?? 64;
    final speed = (state['pathSpeed'] as num?)?.toDouble() ?? tile * 3;
    if (speed <= 0) return;

    var index = (state['pathIndex'] as num).toInt();
    var progress = (state['pathProgress'] as num).toDouble();
    final infinite = path.trim().startsWith('I');
    final seg = segments[index.clamp(0, segments.length - 1)];
    final distance = seg.length * tile;
    if (distance <= 0) return;

    progress += speed * dt;
    while (progress >= distance) {
      progress -= distance;
      x += seg.dx * tile;
      y += seg.dy * tile;
      index += 1;
      if (index >= segments.length) {
        if (!infinite) {
          state['pathIndex'] = segments.length - 1;
          state['pathProgress'] = distance;
          vx = 0;
          vy = 0;
          return;
        }
        index = 0;
        x = (state['pathOriginX'] as num).toDouble();
        y = (state['pathOriginY'] as num).toDouble();
      }
    }

    final current = segments[index];
    vx = current.dx.sign * speed;
    vy = current.dy.sign * speed;
    if (this is SpriteEntity && vx != 0) {
      (this as SpriteEntity).flipX = vx > 0;
    }
    state['pathIndex'] = index;
    state['pathProgress'] = progress;
  }

  @override
  void render(Canvas canvas, GameWorld world) {
    drawShape(canvas, Offset(x, y), Size(w, h), renderConfig);
  }

  @override
  Map<String, dynamic> toMap() => {
    'position': [x, y],
    'size': [w, h],
    'velocity': [vx, vy],
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'vx': vx,
    'vy': vy,
    'autoMove': autoMove,
    'state': state,
    ...state,
  };
}

class _PathSegment {
  const _PathSegment(this.dx, this.dy, this.length);

  final double dx;
  final double dy;
  final double length;
}

List<_PathSegment> _pathSegments(String path) {
  final body = RegExp(r'\{(.+)\}').firstMatch(path)?.group(1);
  if (body == null) return const [];
  final out = <_PathSegment>[];
  for (final token in body.split(',')) {
    final trimmed = token.trim();
    final match = RegExp(r'^(\d+(?:\.\d+)?)([LRTB])$').firstMatch(trimmed);
    if (match == null) continue;
    final length = double.tryParse(match.group(1)!) ?? 0;
    final dir = match.group(2);
    switch (dir) {
      case 'L':
        out.add(_PathSegment(-length, 0, length));
      case 'R':
        out.add(_PathSegment(length, 0, length));
      case 'T':
        out.add(_PathSegment(0, -length, length));
      case 'B':
        out.add(_PathSegment(0, length, length));
    }
  }
  return out;
}

// ---------- sprite / animated_sprite ----------

class SpriteEntity extends PixelEntity implements ImageBackedEntity {
  @override
  String asset;
  @override
  ui.Image? image;
  double srcX;
  double srcY;
  double? srcW;
  double? srcH;
  bool flipX;

  SpriteEntity({
    required super.id,
    required super.renderConfig,
    super.priority,
    required super.x,
    required super.y,
    required super.w,
    required super.h,
    super.vx,
    super.vy,
    super.autoMove,
    super.state,
    required this.asset,
    this.image,
    this.srcX = 0,
    this.srcY = 0,
    this.srcW,
    this.srcH,
    this.flipX = false,
  });

  @override
  void render(Canvas canvas, GameWorld world) {
    final img = image;
    if (img == null) {
      drawShape(canvas, Offset(x, y), Size(w, h), renderConfig);
      return;
    }

    final source = Rect.fromLTWH(
      srcX,
      srcY,
      srcW ?? img.width.toDouble(),
      srcH ?? img.height.toDouble(),
    );
    final offsetX = (state['spriteOffsetX'] as num?)?.toDouble() ?? 0;
    final offsetY = (state['spriteOffsetY'] as num?)?.toDouble() ?? 0;
    final renderW = (state['spriteW'] as num?)?.toDouble() ?? w;
    final renderH = (state['spriteH'] as num?)?.toDouble() ?? h;
    final opacity = ((state['opacity'] as num?)?.toDouble() ?? 1).clamp(0, 1);
    final target = Rect.fromLTWH(x + offsetX, y + offsetY, renderW, renderH);
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false
      ..color = Color.fromRGBO(255, 255, 255, opacity.toDouble());

    if (flipX) {
      canvas.save();
      canvas.translate(target.center.dx, target.center.dy);
      canvas.scale(-1, 1);
      canvas.translate(-target.center.dx, -target.center.dy);
      canvas.drawImageRect(img, source, target, paint);
      canvas.restore();
    } else {
      canvas.drawImageRect(img, source, target, paint);
    }
  }

  @override
  Map<String, dynamic> toMap() => {
    ...super.toMap(),
    'asset': asset,
    'src': [srcX, srcY, srcW, srcH],
    'flipX': flipX,
  };
}

class AnimatedSpriteEntity extends SpriteEntity {
  double frameW;
  double frameH;
  int frames;
  int framesPerRow;
  double stepTime;
  bool loop;
  int frameIndex;
  final Map<String, SpriteAnimationSpec> animations;
  String? currentAnimation;
  double _accumulator = 0;

  AnimatedSpriteEntity({
    required super.id,
    required super.renderConfig,
    super.priority,
    required super.x,
    required super.y,
    required super.w,
    required super.h,
    super.vx,
    super.vy,
    super.autoMove,
    super.state,
    required super.asset,
    required this.frameW,
    required this.frameH,
    required this.frames,
    this.framesPerRow = 0,
    this.stepTime = 0.12,
    this.loop = true,
    this.frameIndex = 0,
    this.animations = const {},
    this.currentAnimation,
    super.flipX,
  }) : super(srcW: frameW, srcH: frameH);

  SpriteAnimationSpec? setAnimation(String name) {
    final spec = animations[name];
    if (spec == null) return null;
    if (currentAnimation == name) return null;
    currentAnimation = name;
    asset = spec.asset;
    frameW = spec.frameW;
    frameH = spec.frameH;
    frames = spec.frames;
    framesPerRow = spec.framesPerRow;
    stepTime = spec.stepTime;
    loop = spec.loop;
    frameIndex = 0;
    _accumulator = 0;
    srcX = 0;
    srcY = 0;
    srcW = frameW;
    srcH = frameH;
    return spec;
  }

  bool get finished => !loop && frameIndex >= frames - 1;

  @override
  bool get expired => state['removeOnFinish'] == true && finished;

  @override
  void update(double dt, GameWorld world) {
    super.update(dt, world);
    if (frames <= 1 || stepTime <= 0) return;
    _accumulator += dt;
    while (_accumulator >= stepTime) {
      _accumulator -= stepTime;
      if (loop) {
        frameIndex = (frameIndex + 1) % frames;
      } else if (frameIndex < frames - 1) {
        frameIndex++;
      }
    }
    final rowSize = framesPerRow > 0 ? framesPerRow : frames;
    srcX = (frameIndex % rowSize) * frameW;
    srcY = (frameIndex ~/ rowSize) * frameH;
  }

  @override
  Map<String, dynamic> toMap() => {
    ...super.toMap(),
    'frame': frameIndex,
    'frames': frames,
    'animation': currentAnimation,
    'finished': finished,
  };
}

class SpriteAnimationSpec {
  final String asset;
  final double frameW;
  final double frameH;
  final int frames;
  final int framesPerRow;
  final double stepTime;
  final bool loop;

  const SpriteAnimationSpec({
    required this.asset,
    required this.frameW,
    required this.frameH,
    required this.frames,
    required this.framesPerRow,
    required this.stepTime,
    required this.loop,
  });
}

// ---------- parallax ----------

class ParallaxEntity extends GameEntity implements ImageBackedEntity {
  @override
  String asset;
  @override
  ui.Image? image;
  double speedX;
  double y;
  double? height;
  double _offsetX = 0;

  ParallaxEntity({
    required super.id,
    required super.renderConfig,
    super.priority,
    required this.asset,
    this.image,
    this.speedX = 0,
    this.y = 0,
    this.height,
  });

  @override
  void update(double dt, GameWorld world) {
    _offsetX = (_offsetX + speedX * dt);
  }

  @override
  void render(Canvas canvas, GameWorld world) {
    final img = image;
    if (img == null) return;

    final drawH = height ?? world.height;
    final drawW = img.width * drawH / img.height;
    if (drawW <= 0 || drawH <= 0) return;

    final normalized = _offsetX % drawW;
    final startX = normalized > 0 ? normalized - drawW : normalized;
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    final src = Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );

    var x = startX;
    while (x < world.width + drawW) {
      canvas.drawImageRect(img, src, Rect.fromLTWH(x, y, drawW, drawH), paint);
      x += drawW;
    }
  }

  @override
  Map<String, dynamic> toMap() => {
    'asset': asset,
    'speedX': speedX,
    'offsetX': _offsetX,
    'y': y,
    'height': height,
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
    super.priority,
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
    final renderInactive =
        (rowSpec['render_inactive'] as Map?)?.cast<String, dynamic>() ??
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

// ---------- value_grid（2048 类游戏用） ----------

/// 网格里每格存一个 int 值（0=空），按值出不同样式。
/// renderConfig 形态：
/// {
///   "by_value": {
///     "0": { shape, color, padding, radius },
///     "2": { shape, color, padding, radius, text: "2", text_color, font_size },
///     "4": {...}, ...
///   },
///   "default": {...}   // 没在 by_value 里的值用这个
/// }
/// 文本里 `{{ value }}` 占位会被当前 cell 的值替换。
class ValueGridEntity extends GameEntity {
  final int cols;
  final int rows;
  final List<List<int>> cells; // [r][c]

  ValueGridEntity({
    required super.id,
    required super.renderConfig,
    super.priority,
    required this.cols,
    required this.rows,
    required this.cells,
  });

  @override
  void render(Canvas canvas, GameWorld world) {
    if (cols == 0 || rows == 0) return;
    // 方块化：cellW = cellH = world.width / cols；网格垂直居中
    final cellSize = world.width / cols;
    final gridH = cellSize * rows;
    final yOffset = (world.height - gridH) / 2;

    final byValue =
        (renderConfig['by_value'] as Map?)?.cast<String, dynamic>() ?? const {};
    final defaultCfg = (renderConfig['default'] as Map?)
        ?.cast<String, dynamic>();

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final v = cells[r][c];
        Map<String, dynamic>? cfg =
            (byValue[v.toString()] as Map?)?.cast<String, dynamic>() ??
            defaultCfg;
        if (cfg == null) continue;
        // {{ value }} 占位替换
        if (cfg.containsKey('text')) {
          final raw = cfg['text']?.toString() ?? '';
          if (raw.contains('{{')) {
            cfg = Map<String, dynamic>.from(cfg);
            cfg['text'] = raw
                .replaceAll('{{ value }}', v.toString())
                .replaceAll('{{value}}', v.toString());
          }
        }
        drawShape(
          canvas,
          Offset(c * cellSize, r * cellSize + yOffset),
          Size(cellSize, cellSize),
          cfg,
        );
      }
    }
  }

  @override
  Map<String, dynamic> toMap() => {'cols': cols, 'rows': rows, 'cells': cells};
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
      // 纯文字模式（现有行为）
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
      return; // text 模式不再画 overlay
  }

  // shape != 'text' 时，如果 cfg 还有 text 字段，画文字 overlay 在 bg 上层
  // 用于 value_grid 的"色块 + 数字"组合
  final overlayText = cfg['text']?.toString();
  if (overlayText != null && overlayText.isNotEmpty) {
    final textColor = parseColor(cfg['text_color']) ?? const Color(0xFF000000);
    final fontSize = (cfg['font_size'] as num?)?.toDouble() ?? 16;
    final tp = TextPainter(
      text: TextSpan(
        text: overlayText,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2),
    );
  }
}
