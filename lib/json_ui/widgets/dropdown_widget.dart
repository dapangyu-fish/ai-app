// Dropdown 控件
// 支持: bind (绑定变量), options ([{label, value}] 或 ["a","b"]),
//       placeholder, disabled, action, label, color, prefixIcon
//
// 实现要点：
// 用 InputDecorator + DropdownButtonHideUnderline + DropdownButton<T>
// 而不是 DropdownButtonFormField —— 后者只读 initialValue，
// bind 变量后续被外部改写时不会反映到 UI（这是 Flutter FormField 的固有行为）。
// DropdownButton 的 value 字段是响应式的，每次 build 都生效。
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import 'action_helper.dart';
import '../interpreter.dart';
import '../../i18n/framework_strings.dart';

class JsonDropdownWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final disabled = json['disabled'] == true;
    final placeholder = interpreter.resolveTemplate(
        json['placeholder']?.toString() ?? T.of(context).widgetDropdownPlaceholder);
    final label = json['label']?.toString();
    final action =
        resolveActionAtBuildTime(json['action'], interpreter)
            as Map<String, dynamic>?;
    final prefixIcon = json['prefixIcon']?.toString();
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);

    // options 可以是 [{label, value}] 或 ["a", "b"]（label==value）
    //
    // 注意：resolveExpression 对 List 不递归（直接 return raw），所以 list-of-maps
    // 里的 label 模板必须每个 item 单独再过 resolveTemplate。
    // 反模式 §7 收录的 dropdown/radio.options[].label 漏 resolveTemplate 就是这个。
    final rawOptions = interpreter.resolveExpression(json['options']);
    final options = <_Option>[];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        if (item is Map) {
          final rawLab =
              item['label']?.toString() ?? item['value']?.toString() ?? '';
          final lab = interpreter.resolveTemplate(rawLab);
          final val = item['value'];
          options.add(_Option(label: lab, value: val));
        } else {
          options.add(
              _Option(label: interpreter.resolveTemplate(item.toString()),
                  value: item));
        }
      }
    }

    final currentValue =
        bindPath != null ? interpreter.getVariable(bindPath) : null;
    // 找出与当前值匹配的 option（按 == 比较）
    _Option? selected;
    for (final opt in options) {
      if (opt.value == currentValue) {
        selected = opt;
        break;
      }
    }

    final iconData =
        prefixIcon != null ? IconRegistry.get(prefixIcon) : null;
    final resolvedLabel =
        label != null ? interpreter.resolveTemplate(label) : null;

    // 即便 options 为空也不能直接 crash —— DropdownButton 要求 items 非空
    // 否则用 InputDecorator 包一行说明文字
    if (options.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: InputDecorator(
          decoration: InputDecoration(
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            prefixIcon: iconData != null ? Icon(iconData, color: color) : null,
            labelText: resolvedLabel,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          child: Text(
            placeholder,
            style: TextStyle(
              fontSize: 15,
              color: Theme.of(context).hintColor,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InputDecorator(
        decoration: InputDecoration(
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12)),
          prefixIcon: iconData != null ? Icon(iconData, color: color) : null,
          labelText: resolvedLabel,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        // 关闭默认下划线，由 InputDecorator 的 border 提供边框
        child: DropdownButtonHideUnderline(
          child: DropdownButton<_Option>(
            value: selected,
            isExpanded: true,
            isDense: true,
            hint: Text(
              placeholder,
              style: TextStyle(
                fontSize: 15,
                color: Theme.of(context).hintColor,
              ),
            ),
            items: options
                .map((opt) => DropdownMenuItem<_Option>(
                      value: opt,
                      child: Text(
                        opt.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: disabled
                ? null
                : (newOpt) {
                    if (newOpt == null) return;
                    if (bindPath != null) {
                      interpreter.setVariable(bindPath, newOpt.value);
                    }
                    if (action != null) {
                      interpreter.executeAction(action, context);
                    }
                  },
          ),
        ),
      ),
    );
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}

class _Option {
  final String label;
  final dynamic value;
  const _Option({required this.label, required this.value});

  @override
  bool operator ==(Object other) =>
      other is _Option && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
