// Transform 控件
// 支持: translateX, translateY, scale, rotateZ, child
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonTransformWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    Widget child = childJson is Map<String, dynamic>
        ? interpreter.buildWidget(context, childJson)
        : const SizedBox.shrink();

    final translateX = _resolveDouble(interpreter, json['translateX']) ?? 0;
    final translateY = _resolveDouble(interpreter, json['translateY']) ?? 0;
    final scale = _resolveDouble(interpreter, json['scale']);
    final rotateZ = _resolveDouble(interpreter, json['rotateZ']);

    if (rotateZ != null && rotateZ != 0) {
      child = Transform.rotate(angle: rotateZ * math.pi / 180, child: child);
    }
    if (scale != null && scale != 1) {
      child = Transform.scale(scale: scale, child: child);
    }
    if (translateX != 0 || translateY != 0) {
      child = Transform.translate(
        offset: Offset(translateX, translateY),
        child: child,
      );
    }
    return child;
  }

  double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final resolved = interpreter.resolveExpression(value);
    if (resolved is num) return resolved.toDouble();
    return double.tryParse(resolved?.toString() ?? '');
  }
}
