// Center 控件
// 支持: child, widthFactor, heightFactor
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonCenterWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final widthFactor = (json['widthFactor'] as num?)?.toDouble();
    final heightFactor = (json['heightFactor'] as num?)?.toDouble();

    final childJson = json['child'];
    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    return Center(
      widthFactor: widthFactor,
      heightFactor: heightFactor,
      child: child,
    );
  }
}
