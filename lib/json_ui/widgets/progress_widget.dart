// Progress 控件 — 线性进度条
// 与 loading 控件 kind=linear 等价，但更语义化、默认更细一点
// 支持: value (0~1, 不传 = 不确定), color, backgroundColor, height, width
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonProgressWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    double? value;
    final rawValue = interpreter.resolveExpression(json['value']);
    if (rawValue is num) {
      value = rawValue.toDouble().clamp(0.0, 1.0);
    } else if (rawValue is String && rawValue.isNotEmpty) {
      final parsed = double.tryParse(rawValue);
      if (parsed != null) value = parsed.clamp(0.0, 1.0);
    }

    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final rawBg = json['backgroundColor']?.toString();
    final bg = _parseColor(
        rawBg != null ? interpreter.resolveTemplate(rawBg) : null);
    final height = (json['height'] as num?)?.toDouble() ?? 6;
    final width = (json['width'] as num?)?.toDouble();
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 0;

    Widget progress = LinearProgressIndicator(
      value: value,
      color: color,
      backgroundColor: bg,
      minHeight: height,
    );
    if (borderRadius > 0) {
      progress = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: progress,
      );
    }
    return SizedBox(width: width, child: progress);
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
