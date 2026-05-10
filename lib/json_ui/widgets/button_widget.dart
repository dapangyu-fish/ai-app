// Button 控件 — 增强版
// 支持：variant (filled/outlined/text)、icon、style (backgroundColor, textColor,
//       fontSize, borderRadius, padding)、label 模板、action 预解析
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';
import 'icon_registry.dart';

class JsonButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    // label 显式给了就用，没给且没图标退到默认 "按钮"，
    // 没给但有图标 → 视为 icon-only 按钮（用 IconButton 渲染，没有文字）
    final rawLabel = json['label'];
    final hasLabel = rawLabel != null && rawLabel.toString().isNotEmpty;
    final label = hasLabel
        ? interpreter.resolveTemplate(rawLabel.toString())
        : '按钮';
    final action = json['action'] as Map<String, dynamic>?;
    final style = json['style'] as Map<String, dynamic>? ?? {};
    final variant = json['variant']?.toString() ?? 'filled';
    final iconName = json['icon']?.toString();
    final disabled = json['disabled'] == true;
    final iconOnly = !hasLabel && iconName != null;

    // build 阶段预解析 action（用共享 helper —— 会递归 List）
    final resolvedAction = action != null
        ? resolveActionAtBuildTime(action, interpreter)
            as Map<String, dynamic>?
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

    // icon-only 按钮：JSON 给了 icon 没给 label，渲染裸 IconButton 而不是
    // FilledButton.icon（后者会塞 "按钮" 占位文字）。tooltip 沿用 label
    // 字段（要是用户想给图标按钮带提示就显式 label）—— 但这里 hasLabel=false
    // 所以没 tooltip，符合直觉。
    if (iconOnly) {
      final iconColor = _parseColor(json['iconColor']?.toString()) ?? textColor;
      return IconButton(
        onPressed: onPressed,
        icon: Icon(iconData, color: iconColor, size: fontSize + 6),
        padding: EdgeInsets.symmetric(horizontal: hPadding * 0.4, vertical: vPadding * 0.4),
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      );
    }

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

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
