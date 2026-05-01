// Badge 控件 — 角标
// 支持: child (被标记的控件), count (数字角标), label (任意文字),
//       color (角标背景), textColor, isLabelVisible (条件显示),
//       smallSize / largeSize, alignment (offset 调整)
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonBadgeWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final rawTextColor = json['textColor']?.toString();
    final textColor = _parseColor(rawTextColor != null
        ? interpreter.resolveTemplate(rawTextColor)
        : null);

    final rawCount = interpreter.resolveExpression(json['count']);
    final rawLabel = json['label']?.toString();
    final isVisible = json['isLabelVisible'] != false;

    Widget? labelWidget;
    if (rawCount is num) {
      // 数字角标：超过 99 显示 99+
      final n = rawCount.toInt();
      if (n > 0) {
        labelWidget = Text(n > 99 ? '99+' : '$n');
      }
    } else if (rawLabel != null && rawLabel.isNotEmpty) {
      final txt = interpreter.resolveTemplate(rawLabel);
      if (txt.isNotEmpty) labelWidget = Text(txt);
    }

    if (labelWidget == null || !isVisible) {
      return child;
    }

    return Badge(
      label: labelWidget,
      backgroundColor: color,
      textColor: textColor,
      child: child,
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
