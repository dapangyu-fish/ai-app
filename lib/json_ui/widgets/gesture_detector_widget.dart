// GestureDetector 控件 — 通用手势检测（无水波纹）
// 比 inkwell 更灵活但少了 Material 视觉反馈
// 支持: child, onTap, onDoubleTap, onLongPress, onSwipeLeft, onSwipeRight,
//       onSwipeUp, onSwipeDown
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
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

    final onTap = resolveActionAtBuildTime(json['onTap'], interpreter)
        as Map<String, dynamic>?;
    final onDouble = resolveActionAtBuildTime(json['onDoubleTap'], interpreter)
        as Map<String, dynamic>?;
    final onLong = resolveActionAtBuildTime(json['onLongPress'], interpreter)
        as Map<String, dynamic>?;
    final onSwipeLeft = resolveActionAtBuildTime(json['onSwipeLeft'], interpreter)
        as Map<String, dynamic>?;
    final onSwipeRight = resolveActionAtBuildTime(json['onSwipeRight'], interpreter)
        as Map<String, dynamic>?;
    final onSwipeUp = resolveActionAtBuildTime(json['onSwipeUp'], interpreter)
        as Map<String, dynamic>?;
    final onSwipeDown = resolveActionAtBuildTime(json['onSwipeDown'], interpreter)
        as Map<String, dynamic>?;

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
}
