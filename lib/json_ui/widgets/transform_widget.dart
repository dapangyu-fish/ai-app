// Transform 控件
// 支持: translateX, translateY, scale, rotateX, rotateY, rotateZ, perspective, child
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
    final rotateX = _resolveDouble(interpreter, json['rotateX']);
    final rotateY = _resolveDouble(interpreter, json['rotateY']);
    final rotateZ = _resolveDouble(interpreter, json['rotateZ']);
    final perspective = _resolveDouble(interpreter, json['perspective']);
    final alignment = _parseAlignment(json['alignment']?.toString());

    if ((rotateX != null && rotateX != 0) ||
        (rotateY != null && rotateY != 0) ||
        (perspective != null && perspective != 0)) {
      final transform = Matrix4.identity();
      if (perspective != null && perspective != 0) {
        transform.setEntry(3, 2, perspective);
      }
      if (rotateX != null && rotateX != 0) {
        transform.rotateX(rotateX * math.pi / 180);
      }
      if (rotateY != null && rotateY != 0) {
        transform.rotateY(rotateY * math.pi / 180);
      }
      if (rotateZ != null && rotateZ != 0) {
        transform.rotateZ(rotateZ * math.pi / 180);
      }
      child = Transform(
        transform: transform,
        alignment: alignment,
        child: child,
      );
    } else if (rotateZ != null && rotateZ != 0) {
      child = Transform.rotate(
        angle: rotateZ * math.pi / 180,
        alignment: alignment,
        child: child,
      );
    }
    if (scale != null && scale != 1) {
      child = Transform.scale(scale: scale, alignment: alignment, child: child);
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

  Alignment _parseAlignment(String? value) {
    return switch (value) {
      'topLeft' => Alignment.topLeft,
      'topCenter' => Alignment.topCenter,
      'topRight' => Alignment.topRight,
      'centerLeft' => Alignment.centerLeft,
      'centerRight' => Alignment.centerRight,
      'bottomLeft' => Alignment.bottomLeft,
      'bottomCenter' => Alignment.bottomCenter,
      'bottomRight' => Alignment.bottomRight,
      _ => Alignment.center,
    };
  }
}
