// Icon 控件
// 支持: name (Material 图标名), size, color
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import '../interpreter.dart';

class JsonIconWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawName = json['name']?.toString();
    final name =
        rawName != null ? interpreter.resolveTemplate(rawName) : null;
    final size = (json['size'] as num?)?.toDouble() ?? 24;
    final rawColor = json['color']?.toString();
    final colorStr =
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null;

    final iconData = name != null ? IconRegistry.get(name) : null;

    if (iconData == null) {
      return Icon(Icons.help_outline,
          size: size, color: Theme.of(context).colorScheme.error);
    }

    return Icon(iconData, size: size, color: _parseColor(colorStr));
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
