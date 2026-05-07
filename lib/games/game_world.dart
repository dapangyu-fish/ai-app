// 游戏世界 — 坐标系 + 背景。
//
// 两种 kind：
// - "pixel": 自由像素坐标，cellW/cellH 退化为 1
// - "grid":  cols × rows 网格，自动按 canvas 尺寸算 cellW/cellH
//
// 所有 entity 用 cellTopLeft / cellSize / cellCenter 把网格坐标转像素，
// pixel kind 下网格函数依然能用，相当于"1px 一格"。

import 'package:flutter/material.dart';

class GameWorld {
  final String kind; // 'pixel' | 'grid'
  final int cols;
  final int rows;
  final Color bg;
  final Color? gridLines;

  // 由 resize() 算出来的实时画布尺寸 + 单元格尺寸
  double width = 0;
  double height = 0;
  double cellW = 1;
  double cellH = 1;

  GameWorld({
    required this.kind,
    this.cols = 1,
    this.rows = 1,
    this.bg = const Color(0xFF000000),
    this.gridLines,
  });

  factory GameWorld.fromJson(Map<String, dynamic>? json) {
    json ??= const {};
    return GameWorld(
      kind: json['kind']?.toString() ?? 'pixel',
      cols: (json['cols'] as num?)?.toInt() ?? 1,
      rows: (json['rows'] as num?)?.toInt() ?? 1,
      bg: parseColor(json['bg']) ?? const Color(0xFF000000),
      gridLines: parseColor(json['grid_lines']),
    );
  }

  void resize(double w, double h) {
    width = w;
    height = h;
    if (kind == 'grid') {
      cellW = w / cols;
      cellH = h / rows;
    } else {
      cellW = 1;
      cellH = 1;
    }
  }

  Offset cellTopLeft(int x, int y) => Offset(x * cellW, y * cellH);
  Offset cellCenter(int x, int y) => Offset((x + 0.5) * cellW, (y + 0.5) * cellH);
  Size cellSize() => Size(cellW, cellH);

  bool inGrid(int x, int y) =>
      kind == 'grid' && x >= 0 && x < cols && y >= 0 && y < rows;

  /// 像素 → 网格（用于 tap 命中检测）
  List<int> pixelToCell(double px, double py) {
    if (kind != 'grid') return [px.floor(), py.floor()];
    return [(px / cellW).floor().clamp(0, cols - 1), (py / cellH).floor().clamp(0, rows - 1)];
  }
}

/// 解析 "#RRGGBB" / "#AARRGGBB" 颜色字符串
Color? parseColor(dynamic v) {
  if (v is! String) return null;
  if (!v.startsWith('#')) return null;
  final hex = v.substring(1);
  try {
    if (hex.length == 6) {
      return Color(int.parse('FF$hex', radix: 16));
    }
    if (hex.length == 8) {
      return Color(int.parse(hex, radix: 16));
    }
  } catch (_) {}
  return null;
}
