// Loading 控件
// 支持: kind (circular/linear, 默认 circular), size, color, value (0-1 确定进度),
//       strokeWidth, label
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonLoadingWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final kind = json['kind']?.toString() ?? 'circular';
    final size = (json['size'] as num?)?.toDouble();
    final color = _parseColor(json['color']?.toString());
    final strokeWidth = (json['strokeWidth'] as num?)?.toDouble() ?? 4;
    final label = json['label']?.toString();

    // value: null = 不确定进度（无限旋转），0~1 = 确定进度
    // 支持：数字字面量、"{{ global.x }}" 模板（解析后必须是 num）
    double? value;
    final rawValue = interpreter.resolveExpression(json['value']);
    if (rawValue is num) {
      value = rawValue.toDouble().clamp(0.0, 1.0);
    } else if (rawValue is String && rawValue.isNotEmpty) {
      final parsed = double.tryParse(rawValue);
      if (parsed != null) value = parsed.clamp(0.0, 1.0);
    }

    Widget indicator;
    if (kind == 'linear') {
      indicator = SizedBox(
        width: size,
        child: LinearProgressIndicator(
          value: value,
          color: color,
          minHeight: strokeWidth,
        ),
      );
    } else {
      final dim = size ?? 36;
      indicator = SizedBox(
        width: dim,
        height: dim,
        child: CircularProgressIndicator(
          value: value,
          color: color,
          strokeWidth: strokeWidth,
        ),
      );
    }

    if (label != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          indicator,
          const SizedBox(height: 12),
          Text(
            interpreter.resolveTemplate(label),
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    return Center(child: indicator);
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
