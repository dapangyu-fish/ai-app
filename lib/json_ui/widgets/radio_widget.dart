// Radio 控件（单选组）
// 支持: bind (绑定当前选中值), options ([{label, value}] 或 ["a","b"]),
//       layout (column/row, 默认 column), disabled, color, action
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonRadioWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final layout = json['layout']?.toString() ?? 'column';
    final disabled = json['disabled'] == true;
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final action =
        resolveActionAtBuildTime(json['action'], interpreter)
            as Map<String, dynamic>?;

    // resolveExpression 对 List 不递归，options[].label 里的 {{ t(...) }} 模板
    // 必须每个 item 单独再过 resolveTemplate（反模式 §7）
    final rawOptions = interpreter.resolveExpression(json['options']);
    final options = <_RadioOption>[];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        if (item is Map) {
          final rawLab =
              item['label']?.toString() ?? item['value']?.toString() ?? '';
          final lab = interpreter.resolveTemplate(rawLab);
          options.add(_RadioOption(label: lab, value: item['value']));
        } else {
          options.add(_RadioOption(
              label: interpreter.resolveTemplate(item.toString()),
              value: item));
        }
      }
    }

    final currentValue =
        bindPath != null ? interpreter.getVariable(bindPath) : null;

    void onChanged(dynamic newVal) {
      if (bindPath != null) {
        interpreter.setVariable(bindPath, newVal);
      }
      if (action != null) {
        interpreter.executeAction(action, context);
      }
    }

    final tiles = options.map((opt) {
      final selected = opt.value == currentValue;
      return InkWell(
        onTap: disabled ? null : () => onChanged(opt.value),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Radio<dynamic>(
                value: opt.value,
                groupValue: currentValue,
                onChanged: disabled ? null : (v) => onChanged(v),
                activeColor: color,
              ),
              const SizedBox(width: 4),
              Text(
                opt.label,
                style: TextStyle(
                  fontSize: 15,
                  color: disabled
                      ? Theme.of(context).disabledColor
                      : (selected ? color : null),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();

    if (layout == 'row') {
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        children: tiles,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: tiles,
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

class _RadioOption {
  final String label;
  final dynamic value;
  const _RadioOption({required this.label, required this.value});
}
