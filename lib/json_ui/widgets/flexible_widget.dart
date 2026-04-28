// Flexible 控件
// 与 Expanded 类似但更灵活：fit=loose (子项可以小于剩余空间)，fit=tight (=Expanded)
// 支持: flex (默认 1), fit (loose/tight, 默认 loose), child
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonFlexibleWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final flex = (json['flex'] as num?)?.toInt() ?? 1;
    final fit = json['fit']?.toString() == 'tight'
        ? FlexFit.tight
        : FlexFit.loose;
    final childJson = json['child'];

    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    return Flexible(flex: flex, fit: fit, child: child);
  }
}
