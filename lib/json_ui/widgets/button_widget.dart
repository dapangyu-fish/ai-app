// Button 控件 — 增强版
// 支持：variant (filled/outlined/text)、icon、style (backgroundColor, textColor,
//       fontSize, borderRadius, padding)、label 模板、action 预解析
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';
import 'icon_registry.dart';

class JsonButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final label = interpreter.resolveTemplate(
      (json['label'] ?? '按钮').toString(),
    );
    final action = json['action'] as Map<String, dynamic>?;
    final style = json['style'] as Map<String, dynamic>? ?? {};
    final variant = json['variant']?.toString() ?? 'filled';
    final iconName = json['icon']?.toString();
    final disabled = json['disabled'] == true;

    // build 阶段预解析 action
    final resolvedAction = action != null
        ? _resolveActionAtBuildTime(action, interpreter)
        : null;

    // 解析样式
    final fontSize = (style['fontSize'] as num?)?.toDouble() ?? 14;
    final borderRadius = (style['borderRadius'] as num?)?.toDouble() ?? 12;
    final hPadding = (style['paddingH'] as num?)?.toDouble() ?? 20;
    final vPadding = (style['paddingV'] as num?)?.toDouble() ?? 12;
    final bgColorStr = style['backgroundColor'] as String?;
    final textColorStr = style['textColor'] as String?;

    Color? bgColor = _parseColor(bgColorStr);
    Color? textColor = _parseColor(textColorStr);

    final iconData = iconName != null ? IconRegistry.get(iconName) : null;

    final buttonStyle = ButtonStyle(
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: hPadding, vertical: vPadding),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: fontSize),
      ),
      backgroundColor: bgColor != null ? WidgetStatePropertyAll(bgColor) : null,
      foregroundColor: textColor != null ? WidgetStatePropertyAll(textColor) : null,
    );

    VoidCallback? onPressed = disabled
        ? null
        : (resolvedAction != null
            ? () => interpreter.executeAction(resolvedAction, context)
            : null);

    Widget button;
    switch (variant) {
      case 'outlined':
        button = iconData != null
            ? OutlinedButton.icon(
                onPressed: onPressed,
                icon: Icon(iconData, size: fontSize + 2),
                label: Text(label),
                style: buttonStyle,
              )
            : OutlinedButton(
                onPressed: onPressed,
                style: buttonStyle,
                child: Text(label),
              );
        break;
      case 'text':
        button = iconData != null
            ? TextButton.icon(
                onPressed: onPressed,
                icon: Icon(iconData, size: fontSize + 2),
                label: Text(label),
                style: buttonStyle,
              )
            : TextButton(
                onPressed: onPressed,
                style: buttonStyle,
                child: Text(label),
              );
        break;
      case 'filled':
      default:
        button = iconData != null
            ? FilledButton.icon(
                onPressed: onPressed,
                icon: Icon(iconData, size: fontSize + 2),
                label: Text(label),
                style: buttonStyle,
              )
            : FilledButton(
                onPressed: onPressed,
                style: buttonStyle,
                child: Text(label),
              );
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: button,
    );
  }

  Map<String, dynamic> _resolveActionAtBuildTime(
    Map<String, dynamic> action,
    JsonInterpreter interpreter,
  ) {
    final resolved = <String, dynamic>{};
    for (final entry in action.entries) {
      final value = entry.value;
      if (value is String && value.contains('{{') && value.contains('}}')) {
        resolved[entry.key] = interpreter.resolveTemplate(value);
      } else if (value is Map<String, dynamic>) {
        resolved[entry.key] = _resolveActionAtBuildTime(value, interpreter);
      } else {
        resolved[entry.key] = value;
      }
    }
    return resolved;
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
