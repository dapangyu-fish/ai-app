// Tooltip 控件 — 长按或悬停显示提示文字
// 支持: message (必填), child, preferBelow, waitDuration, showDuration
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonTooltipWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawMessage = json['message']?.toString() ?? '';
    final message = interpreter.resolveTemplate(rawMessage);
    final preferBelow = json['preferBelow'] != false;
    final waitMs = (json['waitDuration'] as num?)?.toInt();
    final showMs = (json['showDuration'] as num?)?.toInt();

    final childJson = json['child'];
    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    return Tooltip(
      message: message,
      preferBelow: preferBelow,
      waitDuration: waitMs != null ? Duration(milliseconds: waitMs) : null,
      showDuration: showMs != null ? Duration(milliseconds: showMs) : null,
      child: child,
    );
  }
}
