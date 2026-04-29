// GestureDetector 控件 — 通用手势检测（无水波纹）
// 比 inkwell 更灵活但少了 Material 视觉反馈
// 支持: child, onTap, onDoubleTap, onLongPress, onSwipeLeft, onSwipeRight,
//       onSwipeUp, onSwipeDown
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonGestureDetectorWidget extends JsonBaseWidget {
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

    dynamic onTap = _resolve(json['onTap'], interpreter);
    dynamic onDouble = _resolve(json['onDoubleTap'], interpreter);
    dynamic onLong = _resolve(json['onLongPress'], interpreter);
    dynamic onSwipeLeft = _resolve(json['onSwipeLeft'], interpreter);
    dynamic onSwipeRight = _resolve(json['onSwipeRight'], interpreter);
    dynamic onSwipeUp = _resolve(json['onSwipeUp'], interpreter);
    dynamic onSwipeDown = _resolve(json['onSwipeDown'], interpreter);

    return GestureDetector(
      onTap: onTap != null
          ? () => interpreter.executeAction(onTap, context)
          : null,
      onDoubleTap: onDouble != null
          ? () => interpreter.executeAction(onDouble, context)
          : null,
      onLongPress: onLong != null
          ? () => interpreter.executeAction(onLong, context)
          : null,
      onHorizontalDragEnd: (onSwipeLeft != null || onSwipeRight != null)
          ? (details) {
              const threshold = 200.0;
              final v = details.primaryVelocity ?? 0;
              if (v < -threshold && onSwipeLeft != null) {
                interpreter.executeAction(onSwipeLeft, context);
              } else if (v > threshold && onSwipeRight != null) {
                interpreter.executeAction(onSwipeRight, context);
              }
            }
          : null,
      onVerticalDragEnd: (onSwipeUp != null || onSwipeDown != null)
          ? (details) {
              const threshold = 200.0;
              final v = details.primaryVelocity ?? 0;
              if (v < -threshold && onSwipeUp != null) {
                interpreter.executeAction(onSwipeUp, context);
              } else if (v > threshold && onSwipeDown != null) {
                interpreter.executeAction(onSwipeDown, context);
              }
            }
          : null,
      child: child,
    );
  }

  dynamic _resolve(dynamic action, JsonInterpreter interpreter) {
    if (action is! Map<String, dynamic>) return action;
    final resolved = <String, dynamic>{};
    for (final entry in action.entries) {
      final value = entry.value;
      if (value is String && value.contains('{{') && value.contains('}}')) {
        resolved[entry.key] = interpreter.resolveTemplate(value);
      } else if (value is Map<String, dynamic>) {
        resolved[entry.key] = _resolve(value, interpreter);
      } else {
        resolved[entry.key] = value;
      }
    }
    return resolved;
  }
}
