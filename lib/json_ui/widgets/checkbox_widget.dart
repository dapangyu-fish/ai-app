// Checkbox 控件
// 支持: bind (绑定布尔变量), label, action, disabled, color
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonCheckboxWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final label = json['label']?.toString();
    final action = json['action'] as Map<String, dynamic>?;
    final disabled = json['disabled'] == true;
    final color = _parseColor(json['color']?.toString());

    bool value = false;
    if (bindPath != null) {
      final v = interpreter.getVariable(bindPath);
      value = v == true || v == 'true' || v == 1;
    }

    void onChanged(bool? newVal) {
      final v = newVal ?? false;
      if (bindPath != null) {
        interpreter.setVariable(bindPath, v);
      }
      if (action != null) {
        interpreter.executeAction(action, context);
      }
    }

    final checkbox = Checkbox(
      value: value,
      onChanged: disabled ? null : onChanged,
      activeColor: color,
    );

    if (label != null) {
      return InkWell(
        onTap: disabled ? null : () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              checkbox,
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  interpreter.resolveTemplate(label),
                  style: TextStyle(
                    fontSize: 15,
                    color: disabled ? Theme.of(context).disabledColor : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return checkbox;
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
