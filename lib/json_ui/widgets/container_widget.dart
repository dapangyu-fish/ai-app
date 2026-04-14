// Container 控件
// 支持 children、layout（row/column）、color、padding、position 定位
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonContainerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = json['children'] as List<dynamic>? ?? [];
    final layout = json['layout'] ?? 'row'; // container 默认 row
    final padding = (json['padding'] as num?)?.toDouble() ?? 0;
    final colorStr = json['color'] as String?;

    Color? bgColor;
    if (colorStr != null && colorStr.startsWith('#')) {
      final hex = colorStr.replaceFirst('#', '');
      bgColor = Color(int.parse('FF$hex', radix: 16));
    }

    // 构建子控件列表
    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((childJson) => interpreter.buildWidget(context, childJson))
        .toList();

    Widget layoutWidget;
    if (layout == 'row') {
      layoutWidget = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: childWidgets,
      );
    } else {
      layoutWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: childWidgets,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: padding > 0 ? EdgeInsets.all(padding) : null,
        color: bgColor,
        child: layoutWidget,
      ),
    );
  }
}
