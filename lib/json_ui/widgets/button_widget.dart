// Button 控件
// 支持 label 文本、action 事件（call / navigate）、position 定位
//
// 重要：action 中的模板表达式 {{ }} 必须在 build 阶段预解析，
// 因为 onPressed 触发时循环上下文 (_loopContextStack) 已被弹出。
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final label = json['label'] ?? '按钮';
    final action = json['action'] as Map<String, dynamic>?;

    // 在 build 阶段预解析 action，捕获当前的循环上下文
    // 这样 onPressed 异步触发时不再依赖已弹出的 _loopContextStack
    final resolvedAction = action != null
        ? _resolveActionAtBuildTime(action, interpreter)
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: ElevatedButton(
        onPressed: resolvedAction != null
            ? () => interpreter.executeAction(resolvedAction, context)
            : null,
        child: Text(label.toString()),
      ),
    );
  }

  /// 在 build 阶段深度解析 action 中所有 {{ }} 模板
  Map<String, dynamic> _resolveActionAtBuildTime(
    Map<String, dynamic> action,
    JsonInterpreter interpreter,
  ) {
    final resolved = <String, dynamic>{};
    for (final entry in action.entries) {
      final value = entry.value;
      if (value is String && value.contains('{{') && value.contains('}}')) {
        // 模板字符串：立即解析
        resolved[entry.key] = interpreter.resolveTemplate(value);
      } else if (value is Map<String, dynamic>) {
        // 嵌套 Map（如 args）：递归解析
        resolved[entry.key] = _resolveActionAtBuildTime(value, interpreter);
      } else {
        resolved[entry.key] = value;
      }
    }
    return resolved;
  }
}
