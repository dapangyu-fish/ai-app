// 屏幕布局处理器
// 根据 screen.layout 字段选择合适的布局容器：
//   - column（默认）：垂直排列
//   - row：水平排列
//   - stack：堆叠布局（支持 absolute 定位）
import 'package:flutter/material.dart';

/// 根据 layout 类型构建对应的布局 Widget
Widget buildScreenLayout(Map<String, dynamic> screen, List<Widget> children) {
  final layout = screen['layout'] ?? 'column';
  final padding = (screen['padding'] as num?)?.toDouble() ?? 0;

  Widget layoutWidget;

  switch (layout) {
    case 'stack':
      layoutWidget = Stack(children: children);
      break;
    case 'row':
      layoutWidget = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      );
      break;
    case 'column':
    default:
      layoutWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
      break;
  }

  return Padding(
    padding: EdgeInsets.all(padding),
    child: layoutWidget,
  );
}
