// Slider 控件
// 支持: bind, min, max, divisions, label, action, color, disabled
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonSliderWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final min = (json['min'] as num?)?.toDouble() ?? 0;
    final max = (json['max'] as num?)?.toDouble() ?? 100;
    final divisions = (json['divisions'] as num?)?.toInt();
    final showLabel = json['showLabel'] != false;
    final action = json['action'] as Map<String, dynamic>?;
    final disabled = json['disabled'] == true;
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);

    double value = min;
    if (bindPath != null) {
      final v = interpreter.getVariable(bindPath);
      if (v is num) value = v.toDouble();
    }
    if (value < min) value = min;
    if (value > max) value = max;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: showLabel ? value.toStringAsFixed(divisions != null ? 0 : 1) : null,
        activeColor: color,
        onChanged: disabled
            ? null
            : (newVal) {
                if (bindPath != null) {
                  final v = divisions != null ? newVal.round() : newVal;
                  interpreter.setVariable(bindPath, v);
                }
                if (action != null) {
                  interpreter.executeAction(action, context);
                }
              },
      ),
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
