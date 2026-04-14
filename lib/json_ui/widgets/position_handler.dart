// position 字段处理器
// 支持三种定位模式：
//   - relative（默认）：顺序排列，不做额外包装
//   - absolute：绝对定位，需要父容器为 Stack
//   - flex：弹性布局，使用 Expanded
import 'package:flutter/material.dart';

/// 根据 JSON 中的 position 字段包装子 Widget
Widget applyPosition(Widget child, Map<String, dynamic>? pos) {
  if (pos == null) return child;
  final type = pos['type'] ?? 'relative';

  if (type == 'absolute') {
    return Positioned(
      top: (pos['top'] as num?)?.toDouble(),
      left: (pos['left'] as num?)?.toDouble(),
      bottom: (pos['bottom'] as num?)?.toDouble(),
      right: (pos['right'] as num?)?.toDouble(),
      child: child,
    );
  } else if (type == 'flex') {
    return Expanded(
      flex: (pos['flex'] as num?)?.toInt() ?? 1,
      child: child,
    );
  }

  // relative 或未知类型：直接返回原控件
  return child;
}
