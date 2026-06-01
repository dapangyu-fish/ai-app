// GestureDetector 控件 — 通用手势检测（无水波纹）
// 比 inkwell 更灵活但少了 Material 视觉反馈
// 支持: child, onTap, onTapDown, onTapUp, onTapCancel, onDoubleTap,
//       onLongPress, onPanStart, onPanUpdate, onPanEnd, onPanCancel,
//       onSwipeLeft, onSwipeRight, onSwipeUp, onSwipeDown
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

    final onTap =
        resolveActionAtBuildTime(json['onTap'], interpreter)
            as Map<String, dynamic>?;
    final onTapDown = json['onTapDown'] as Map<String, dynamic>?;
    final onTapUp = json['onTapUp'] as Map<String, dynamic>?;
    final onTapCancel = json['onTapCancel'] as Map<String, dynamic>?;
    final onPanStart = json['onPanStart'] as Map<String, dynamic>?;
    final onPanUpdate = json['onPanUpdate'] as Map<String, dynamic>?;
    final onPanEnd = json['onPanEnd'] as Map<String, dynamic>?;
    final onPanCancel = json['onPanCancel'] as Map<String, dynamic>?;
    final onDouble =
        resolveActionAtBuildTime(json['onDoubleTap'], interpreter)
            as Map<String, dynamic>?;
    final onLong =
        resolveActionAtBuildTime(json['onLongPress'], interpreter)
            as Map<String, dynamic>?;
    final onSwipeLeft =
        resolveActionAtBuildTime(json['onSwipeLeft'], interpreter)
            as Map<String, dynamic>?;
    final onSwipeRight =
        resolveActionAtBuildTime(json['onSwipeRight'], interpreter)
            as Map<String, dynamic>?;
    final onSwipeUp =
        resolveActionAtBuildTime(json['onSwipeUp'], interpreter)
            as Map<String, dynamic>?;
    final onSwipeDown =
        resolveActionAtBuildTime(json['onSwipeDown'], interpreter)
            as Map<String, dynamic>?;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap != null
          ? () => interpreter.executeAction(onTap, context)
          : null,
      onTapDown: onTapDown != null
          ? (details) => _runPointerAction(
              interpreter,
              context,
              onTapDown,
              details.localPosition,
              details.globalPosition,
            )
          : null,
      onTapUp: onTapUp != null
          ? (details) => _runPointerAction(
              interpreter,
              context,
              onTapUp,
              details.localPosition,
              details.globalPosition,
            )
          : null,
      onTapCancel: onTapCancel != null
          ? () => interpreter.executeAction(onTapCancel, context)
          : null,
      onDoubleTap: onDouble != null
          ? () => interpreter.executeAction(onDouble, context)
          : null,
      onLongPress: onLong != null
          ? () => interpreter.executeAction(onLong, context)
          : null,
      onPanStart: onPanStart != null
          ? (details) => _runPointerAction(
              interpreter,
              context,
              onPanStart,
              details.localPosition,
              details.globalPosition,
            )
          : null,
      onPanUpdate: onPanUpdate != null
          ? (details) => _runPointerAction(
              interpreter,
              context,
              onPanUpdate,
              details.localPosition,
              details.globalPosition,
              delta: details.delta,
            )
          : null,
      onPanEnd: onPanEnd != null
          ? (details) => interpreter.executeActionWithEvent(onPanEnd, context, {
              'velocityX': details.velocity.pixelsPerSecond.dx,
              'velocityY': details.velocity.pixelsPerSecond.dy,
            })
          : null,
      onPanCancel: onPanCancel != null
          ? () => interpreter.executeAction(onPanCancel, context)
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

void _runPointerAction(
  JsonInterpreter interpreter,
  BuildContext context,
  Map<String, dynamic> action,
  Offset local,
  Offset global, {
  Offset? delta,
}) {
  interpreter
      .executeActionWithEvent(action, context, {
        'localX': local.dx,
        'localY': local.dy,
        'globalX': global.dx,
        'globalY': global.dy,
        'deltaX': delta?.dx ?? 0,
        'deltaY': delta?.dy ?? 0,
      })
      .catchError((e, st) {
        debugPrint('[gesture_detector] pointer action error: $e');
      });
}
