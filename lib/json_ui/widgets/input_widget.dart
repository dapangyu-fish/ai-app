// Input 控件
// 支持 placeholder、bind（双向绑定到全局变量）、position 定位
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonInputWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final placeholder = json['placeholder'] ?? '';
    final bindPath = json['bind'] as String?;

    // 获取当前绑定变量的值作为初始值
    final currentValue = bindPath != null
        ? interpreter.getVariable(bindPath)?.toString() ?? ''
        : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: interpreter.getTextController(bindPath ?? '', currentValue),
        decoration: InputDecoration(
          hintText: placeholder.toString(),
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onChanged: (value) {
          if (bindPath != null) {
            // 双向绑定：实时更新全局变量
            interpreter.setVariable(bindPath, value);
          }
        },
      ),
    );
  }
}
