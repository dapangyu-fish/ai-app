// Container 控件 — 增强版
// 支持：children, layout (row/column), color, padding, margin,
//       borderRadius, border { color, width }, elevation, width, height
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
    final layout = json['layout'] ?? 'row';
    final padding = (json['padding'] as num?)?.toDouble() ?? 0;
    final margin = (json['margin'] as num?)?.toDouble() ?? 0;
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 0;
    final elevation = (json['elevation'] as num?)?.toDouble() ?? 0;
    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();

    // 背景色
    Color? bgColor = _parseColor(json['color'] as String?);

    // 边框
    Border? border;
    final borderDef = json['border'] as Map<String, dynamic>?;
    if (borderDef != null) {
      final borderColor =
          _parseColor(borderDef['color'] as String?) ?? Colors.grey;
      final borderWidth = (borderDef['width'] as num?)?.toDouble() ?? 1;
      border = Border.all(color: borderColor, width: borderWidth);
    }

    // 构建子控件
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

    Widget container = Container(
      width: width,
      height: height,
      padding: padding > 0 ? EdgeInsets.all(padding) : null,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius:
            borderRadius > 0 ? BorderRadius.circular(borderRadius) : null,
        border: border,
      ),
      child: layoutWidget,
    );

    // 阴影 (elevation)
    if (elevation > 0) {
      container = Material(
        elevation: elevation,
        borderRadius:
            borderRadius > 0 ? BorderRadius.circular(borderRadius) : null,
        color: bgColor ?? Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: padding > 0 ? EdgeInsets.all(padding) : EdgeInsets.zero,
          child: layoutWidget,
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.all(margin),
      child: container,
    );
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
