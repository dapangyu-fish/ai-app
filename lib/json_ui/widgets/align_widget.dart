// Align 控件
// 支持: alignment (topLeft / topCenter / topRight / centerLeft / center /
//       centerRight / bottomLeft / bottomCenter / bottomRight),
//       alignmentX/alignmentY (或 x/y), widthFactor, heightFactor, child
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonAlignWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final alignmentX = _resolveDouble(
      interpreter,
      json['alignmentX'] ?? json['x'],
    );
    final alignmentY = _resolveDouble(
      interpreter,
      json['alignmentY'] ?? json['y'],
    );
    final alignment = alignmentX != null || alignmentY != null
        ? Alignment(alignmentX ?? 0, alignmentY ?? 0)
        : _parseAlignment(json['alignment']?.toString());
    final widthFactor = _resolveDouble(interpreter, json['widthFactor']);
    final heightFactor = _resolveDouble(interpreter, json['heightFactor']);

    final childJson = json['child'];
    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    return Align(
      alignment: alignment,
      widthFactor: widthFactor,
      heightFactor: heightFactor,
      child: child,
    );
  }

  Alignment _parseAlignment(String? s) {
    switch (s) {
      case 'topLeft':
        return Alignment.topLeft;
      case 'topCenter':
        return Alignment.topCenter;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomRight':
        return Alignment.bottomRight;
      case 'center':
      default:
        return Alignment.center;
    }
  }

  double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final resolved = interpreter.evaluateExpression(value);
    if (resolved is num) return resolved.toDouble();
    return double.tryParse(resolved?.toString() ?? '');
  }
}
