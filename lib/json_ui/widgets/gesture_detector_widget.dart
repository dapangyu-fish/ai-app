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

class JsonTransformGestureWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final child = childJson is Map<String, dynamic>
        ? interpreter.buildWidget(context, childJson)
        : const SizedBox.shrink();

    return _JsonTransformGestureHost(
      behavior: _parseHitTestBehavior(json['behavior']?.toString()),
      onStart:
          resolveActionAtBuildTime(json['onTransformStart'], interpreter)
              as Map<String, dynamic>?,
      onUpdate:
          resolveActionAtBuildTime(json['onTransformUpdate'], interpreter)
              as Map<String, dynamic>?,
      onEnd:
          resolveActionAtBuildTime(json['onTransformEnd'], interpreter)
              as Map<String, dynamic>?,
      onTap:
          resolveActionAtBuildTime(json['onTap'], interpreter)
              as Map<String, dynamic>?,
      onDoubleTap:
          resolveActionAtBuildTime(json['onDoubleTap'], interpreter)
              as Map<String, dynamic>?,
      interpreter: interpreter,
      child: child,
    );
  }
}

class _JsonTransformGestureHost extends StatefulWidget {
  final HitTestBehavior behavior;
  final Map<String, dynamic>? onStart;
  final Map<String, dynamic>? onUpdate;
  final Map<String, dynamic>? onEnd;
  final Map<String, dynamic>? onTap;
  final Map<String, dynamic>? onDoubleTap;
  final JsonInterpreter interpreter;
  final Widget child;

  const _JsonTransformGestureHost({
    required this.behavior,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onTap,
    required this.onDoubleTap,
    required this.interpreter,
    required this.child,
  });

  @override
  State<_JsonTransformGestureHost> createState() =>
      _JsonTransformGestureHostState();
}

class _JsonTransformGestureHostState extends State<_JsonTransformGestureHost> {
  double _lastScale = 1;
  double _lastRotation = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTap: widget.onTap == null
          ? null
          : () => widget.interpreter.executeAction(widget.onTap!, context),
      onDoubleTap: widget.onDoubleTap == null
          ? null
          : () =>
                widget.interpreter.executeAction(widget.onDoubleTap!, context),
      onScaleStart: widget.onStart == null && widget.onUpdate == null
          ? null
          : (details) {
              _lastScale = 1;
              _lastRotation = 0;
              final action = widget.onStart;
              if (action == null) return;
              _runTransformAction(action, _startEvent(details));
            },
      onScaleUpdate: widget.onUpdate == null
          ? null
          : (details) {
              final scaleDelta = _lastScale == 0
                  ? details.scale
                  : details.scale / _lastScale;
              final rotationDelta = details.rotation - _lastRotation;
              _lastScale = details.scale;
              _lastRotation = details.rotation;
              _runTransformAction(
                widget.onUpdate!,
                _updateEvent(details, scaleDelta, rotationDelta),
              );
            },
      onScaleEnd: widget.onEnd == null
          ? null
          : (details) {
              _lastScale = 1;
              _lastRotation = 0;
              _runTransformAction(widget.onEnd!, _endEvent(details));
            },
      child: widget.child,
    );
  }

  void _runTransformAction(
    Map<String, dynamic> action,
    Map<String, dynamic> event,
  ) {
    widget.interpreter
        .executeActionWithEvent(action, context, event)
        .catchError((e, st) {
          debugPrint('[transform_gesture] action error: $e');
        });
  }

  Map<String, dynamic> _startEvent(ScaleStartDetails details) {
    return {
      'localX': details.localFocalPoint.dx,
      'localY': details.localFocalPoint.dy,
      'globalX': details.focalPoint.dx,
      'globalY': details.focalPoint.dy,
      'focalX': details.localFocalPoint.dx,
      'focalY': details.localFocalPoint.dy,
      'globalFocalX': details.focalPoint.dx,
      'globalFocalY': details.focalPoint.dy,
      'deltaX': 0,
      'deltaY': 0,
      'translationDeltaX': 0,
      'translationDeltaY': 0,
      'scale': 1,
      'scaleDelta': 1,
      'rotation': 0,
      'rotationDegrees': 0,
      'rotationDelta': 0,
      'rotationDeltaDegrees': 0,
      'pointerCount': details.pointerCount,
    };
  }

  Map<String, dynamic> _updateEvent(
    ScaleUpdateDetails details,
    double scaleDelta,
    double rotationDelta,
  ) {
    return {
      'localX': details.localFocalPoint.dx,
      'localY': details.localFocalPoint.dy,
      'globalX': details.focalPoint.dx,
      'globalY': details.focalPoint.dy,
      'focalX': details.localFocalPoint.dx,
      'focalY': details.localFocalPoint.dy,
      'globalFocalX': details.focalPoint.dx,
      'globalFocalY': details.focalPoint.dy,
      'deltaX': details.focalPointDelta.dx,
      'deltaY': details.focalPointDelta.dy,
      'translationDeltaX': details.focalPointDelta.dx,
      'translationDeltaY': details.focalPointDelta.dy,
      'scale': details.scale,
      'scaleDelta': scaleDelta.isFinite ? scaleDelta : 1,
      'rotation': details.rotation,
      'rotationDegrees': details.rotation * 180 / 3.141592653589793,
      'rotationDelta': rotationDelta,
      'rotationDeltaDegrees': rotationDelta * 180 / 3.141592653589793,
      'pointerCount': details.pointerCount,
    };
  }

  Map<String, dynamic> _endEvent(ScaleEndDetails details) {
    return {
      'velocityX': details.velocity.pixelsPerSecond.dx,
      'velocityY': details.velocity.pixelsPerSecond.dy,
      'pointerCount': details.pointerCount,
    };
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

HitTestBehavior _parseHitTestBehavior(String? value) {
  return switch (value) {
    'deferToChild' => HitTestBehavior.deferToChild,
    'translucent' => HitTestBehavior.translucent,
    _ => HitTestBehavior.opaque,
  };
}
