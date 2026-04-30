// InkWell 控件 — Material 风格点击波纹
// 用于让任意 child 可点击且有水波纹反馈
// 支持: child, onTap, onLongPress, onDoubleTap, borderRadius, splashColor
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonInkWellWidget extends JsonBaseWidget {
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

    final onTapDef = _resolveActionAtBuildTime(json['onTap'], interpreter);
    final onLongPressDef =
        _resolveActionAtBuildTime(json['onLongPress'], interpreter);
    final onDoubleTapDef =
        _resolveActionAtBuildTime(json['onDoubleTap'], interpreter);

    final borderRadius = (json['borderRadius'] as num?)?.toDouble();
    final rawSplash = json['splashColor']?.toString();
    final splash = _parseColor(
        rawSplash != null ? interpreter.resolveTemplate(rawSplash) : null);

    // InkWell 必须在 Material ancestor 内才能显示水波纹
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTapDef != null
            ? () => interpreter.executeAction(onTapDef, context)
            : null,
        onLongPress: onLongPressDef != null
            ? () => interpreter.executeAction(onLongPressDef, context)
            : null,
        onDoubleTap: onDoubleTapDef != null
            ? () => interpreter.executeAction(onDoubleTapDef, context)
            : null,
        borderRadius:
            borderRadius != null ? BorderRadius.circular(borderRadius) : null,
        splashColor: splash,
        child: child,
      ),
    );
  }

  dynamic _resolveActionAtBuildTime(
      dynamic action, JsonInterpreter interpreter) {
    if (action is! Map<String, dynamic>) return action;
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
