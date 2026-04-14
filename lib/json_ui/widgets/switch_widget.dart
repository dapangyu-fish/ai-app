// Switch 控件
// 支持 bind (绑定布尔变量), label, action
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonSwitchWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final label = json['label']?.toString();
    final action = json['action'] as Map<String, dynamic>?;

    bool value = false;
    if (bindPath != null) {
      final v = interpreter.getVariable(bindPath);
      value = v == true || v == 'true' || v == 1;
    }

    final switchWidget = Switch(
      value: value,
      onChanged: (newVal) {
        if (bindPath != null) {
          interpreter.setVariable(bindPath, newVal);
        }
        if (action != null) {
          interpreter.executeAction(action, context);
        }
      },
    );

    if (label != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              interpreter.resolveTemplate(label),
              style: const TextStyle(fontSize: 15),
            ),
            switchWidget,
          ],
        ),
      );
    }

    return switchWidget;
  }
}
