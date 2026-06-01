// Positioned 控件
// 支持: left/top/right/bottom 数值，leftFactor/topFactor 基于屏幕尺寸计算位置，child
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonPositionedWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final childJson = json['child'];
    final child = childJson is Map<String, dynamic>
        ? interpreter.buildWidget(context, childJson)
        : const SizedBox.shrink();

    final left = _positionValue(
      interpreter,
      json['left'],
      json['leftFactor'],
      size.width,
      json['leftOffset'],
    );
    final top = _positionValue(
      interpreter,
      json['top'],
      json['topFactor'],
      size.height,
      json['topOffset'],
    );

    final adjustTop = json['subtractSafeTop'] == true ? padding.top : 0.0;
    final adjustToolbar = json['subtractToolbar'] == true
        ? kToolbarHeight
        : 0.0;

    return Positioned(
      left: left,
      top: top == null ? null : top - adjustTop - adjustToolbar,
      right: _resolveDouble(interpreter, json['right']),
      bottom: _resolveDouble(interpreter, json['bottom']),
      child: child,
    );
  }

  double? _positionValue(
    JsonInterpreter interpreter,
    dynamic absolute,
    dynamic factor,
    double extent,
    dynamic offset,
  ) {
    final value = _resolveDouble(interpreter, absolute);
    if (value != null) return value;
    final ratio = _resolveDouble(interpreter, factor);
    if (ratio == null) return null;
    return extent * ratio + (_resolveDouble(interpreter, offset) ?? 0);
  }

  double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final resolved = interpreter.resolveExpression(value);
    if (resolved is num) return resolved.toDouble();
    return double.tryParse(resolved?.toString() ?? '');
  }
}
