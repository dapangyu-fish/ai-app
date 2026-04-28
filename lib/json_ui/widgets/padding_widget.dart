// Padding 控件
// 支持: padding (所有边相同) 或 paddingH/paddingV/paddingTop/paddingBottom/
//       paddingLeft/paddingRight 分别设置；child
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonPaddingWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final all = (json['padding'] as num?)?.toDouble();
    final h = (json['paddingH'] as num?)?.toDouble();
    final v = (json['paddingV'] as num?)?.toDouble();
    final top = (json['paddingTop'] as num?)?.toDouble();
    final bottom = (json['paddingBottom'] as num?)?.toDouble();
    final left = (json['paddingLeft'] as num?)?.toDouble();
    final right = (json['paddingRight'] as num?)?.toDouble();

    final edge = EdgeInsets.only(
      left: left ?? h ?? all ?? 0,
      right: right ?? h ?? all ?? 0,
      top: top ?? v ?? all ?? 0,
      bottom: bottom ?? v ?? all ?? 0,
    );

    final childJson = json['child'];
    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    return Padding(padding: edge, child: child);
  }
}
