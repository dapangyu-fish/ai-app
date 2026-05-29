// 共享 helper —— 在 build 阶段预解析 action 中的 {{ }} 模板
// 必须在循环上下文里调用（list / grid 的 item_template 渲染时）。
// 因为 loop.item / loop.index 在用户点击触发 action 时已被 pop。
import '../interpreter.dart';

/// 递归把 action / handler Map 中所有的字符串模板解析为字面值
/// - String 含 `{{ }}` → resolveTemplate（返回字符串）
/// - Map → 递归
/// - 其他（List/num/bool）→ 原样返回
///
/// 注意：本函数返回 String 化后的模板结果（resolveTemplate 行为），
/// 这意味着数字类型的 loop.index 会被字符串化为 "0" / "1" 等。
/// 框架内部的 _toInt / _toDouble 等转换函数会兜底处理。
dynamic resolveActionAtBuildTime(dynamic action, JsonInterpreter interpreter) {
  return _resolveActionNodeAtBuildTime(action, interpreter);
}

dynamic _resolveActionNodeAtBuildTime(
  dynamic action,
  JsonInterpreter interpreter,
) {
  if (action is! Map<String, dynamic>) return action;
  final resolved = <String, dynamic>{};
  // Loop-creating actions must keep their child body raw. Otherwise a button
  // inside a list item can accidentally bake the inner loop's {{ loop.item }}
  // to the outer list item during widget build.
  final lazyArgKeys = _lazyArgKeysForCall(action['call']?.toString());
  for (final entry in action.entries) {
    final value = entry.value;
    if (entry.key == 'args' &&
        value is Map<String, dynamic> &&
        lazyArgKeys.isNotEmpty) {
      resolved[entry.key] = _resolveArgsAtBuildTime(
        value,
        interpreter,
        lazyArgKeys,
      );
    } else if (value is String &&
        value.contains('{{') &&
        value.contains('}}')) {
      resolved[entry.key] = interpreter.resolveTemplate(value);
    } else if (value is Map<String, dynamic>) {
      resolved[entry.key] = _resolveActionNodeAtBuildTime(value, interpreter);
    } else if (value is List) {
      resolved[entry.key] = value.map((e) {
        if (e is String && e.contains('{{') && e.contains('}}')) {
          return interpreter.resolveTemplate(e);
        }
        if (e is Map<String, dynamic>) {
          return _resolveActionNodeAtBuildTime(e, interpreter);
        }
        return e;
      }).toList();
    } else {
      resolved[entry.key] = value;
    }
  }
  return resolved;
}

Map<String, dynamic> _resolveArgsAtBuildTime(
  Map<String, dynamic> args,
  JsonInterpreter interpreter,
  Set<String> lazyKeys,
) {
  final resolved = <String, dynamic>{};
  for (final entry in args.entries) {
    if (lazyKeys.contains(entry.key)) {
      resolved[entry.key] = entry.value;
      continue;
    }
    final value = entry.value;
    if (value is String && value.contains('{{') && value.contains('}}')) {
      resolved[entry.key] = interpreter.resolveTemplate(value);
    } else if (value is Map<String, dynamic>) {
      resolved[entry.key] = _resolveActionNodeAtBuildTime(value, interpreter);
    } else if (value is List) {
      resolved[entry.key] = value.map((e) {
        if (e is String && e.contains('{{') && e.contains('}}')) {
          return interpreter.resolveTemplate(e);
        }
        if (e is Map<String, dynamic>) {
          return _resolveActionNodeAtBuildTime(e, interpreter);
        }
        return e;
      }).toList();
    } else {
      resolved[entry.key] = value;
    }
  }
  return resolved;
}

Set<String> _lazyArgKeysForCall(String? call) {
  switch (call) {
    case '@for_each':
    case '@loop_by_num':
      return const {'body'};
  }
  return const {};
}
