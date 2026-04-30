// Draggable 控件 — 可拖拽
// 支持: child, feedback (拖拽时跟手的视觉, 默认半透明 child),
//       data (拖到 DragTarget 时携带的数据), onDragStarted, onDragCompleted,
//       onDragCanceled, axis (horizontal/vertical, 默认两轴自由)
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonDraggableWidget extends JsonBaseWidget {
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

    final feedbackJson = json['feedback'] as Map<String, dynamic>?;
    final Widget feedback = feedbackJson != null
        ? Material(
            color: Colors.transparent,
            child: interpreter.buildWidget(context, feedbackJson),
          )
        : Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.7, child: child),
          );

    // Draggable<T extends Object> 不接受 dynamic / null，给个空字符串兜底
    final Object data = interpreter.resolveExpression(json['data']) ?? '';

    final onStart = resolveActionAtBuildTime(json['onDragStarted'], interpreter)
        as Map<String, dynamic>?;
    final onComplete =
        resolveActionAtBuildTime(json['onDragCompleted'], interpreter)
            as Map<String, dynamic>?;
    final onCancel =
        resolveActionAtBuildTime(json['onDragCanceled'], interpreter)
            as Map<String, dynamic>?;

    final axisStr = json['axis']?.toString();
    Axis? axis;
    if (axisStr == 'horizontal') {
      axis = Axis.horizontal;
    } else if (axisStr == 'vertical') {
      axis = Axis.vertical;
    }

    return Draggable<Object>(
      data: data,
      axis: axis,
      feedback: feedback,
      childWhenDragging: Opacity(opacity: 0.3, child: child),
      onDragStarted: onStart != null
          ? () => interpreter.executeAction(onStart, context)
          : null,
      onDragCompleted: onComplete != null
          ? () => interpreter.executeAction(onComplete, context)
          : null,
      onDraggableCanceled: onCancel != null
          ? (_, __) => interpreter.executeAction(onCancel, context)
          : null,
      child: child,
    );
  }
}
