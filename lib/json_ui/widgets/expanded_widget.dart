// Expanded 控件
// 用于 Row/Column 内部，让子控件占用剩余空间
// 支持: flex (默认 1), child
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonExpandedWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final flex = (json['flex'] as num?)?.toInt() ?? 1;
    final childJson = json['child'];

    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    return Expanded(flex: flex, child: child);
  }
}
