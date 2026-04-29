// Dropdown 控件
// 支持: bind (绑定变量), options ([{label, value}] 或 ["a","b"]),
//       placeholder, disabled, action, label, color, prefixIcon
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonDropdownWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final disabled = json['disabled'] == true;
    final placeholder = json['placeholder']?.toString() ?? '请选择';
    final label = json['label']?.toString();
    final action =
        resolveActionAtBuildTime(json['action'], interpreter)
            as Map<String, dynamic>?;
    final prefixIcon = json['prefixIcon']?.toString();
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);

    // options 可以是 [{label, value}] 或 ["a", "b"]（label==value）
    final rawOptions = interpreter.resolveExpression(json['options']);
    final options = <_Option>[];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        if (item is Map) {
          final lab = item['label']?.toString() ?? item['value']?.toString() ?? '';
          final val = item['value'];
          options.add(_Option(label: lab, value: val));
        } else {
          options.add(_Option(label: item.toString(), value: item));
        }
      }
    }

    final currentValue =
        bindPath != null ? interpreter.getVariable(bindPath) : null;
    // 找出与当前值匹配的 option（按 == 比较，覆盖 String/num/bool）
    _Option? selected;
    for (final opt in options) {
      if (opt.value == currentValue) {
        selected = opt;
        break;
      }
    }

    final iconData = prefixIcon != null ? IconRegistry.get(prefixIcon) : null;

    final dropdown = DropdownButtonFormField<_Option>(
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        prefixIcon: iconData != null ? Icon(iconData, color: color) : null,
        hintText: placeholder,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        labelText: label != null ? interpreter.resolveTemplate(label) : null,
      ),
      items: options
          .map((opt) => DropdownMenuItem<_Option>(
                value: opt,
                child: Text(opt.label),
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
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: dropdown,
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
