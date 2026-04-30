// TimePicker 控件 — 点击触发 showTimePicker，选中后写回 bind 变量（HH:mm 格式）
// 支持: bind, placeholder, label, prefixIcon, action, disabled
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonTimePickerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final placeholder = json['placeholder']?.toString() ?? '请选择时间';
    final label = json['label']?.toString();
    final prefixIcon = json['prefixIcon']?.toString() ?? 'clock';
    final action =
        resolveActionAtBuildTime(json['action'], interpreter)
            as Map<String, dynamic>?;
    final disabled = json['disabled'] == true;

    String displayText = placeholder;
    TimeOfDay initial = TimeOfDay.now();
    if (bindPath != null) {
      final v = interpreter.getVariable(bindPath);
      if (v is String && v.isNotEmpty) {
        final parsed = _parseTime(v);
        if (parsed != null) {
          initial = parsed;
          displayText = _formatTime(parsed);
        }
      }
    }

    final iconData = IconRegistry.get(prefixIcon);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: disabled
            ? null
            : () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: initial,
                );
                if (picked != null) {
                  if (bindPath != null) {
                    interpreter.setVariable(bindPath, _formatTime(picked));
                  }
                  if (action != null) {
                    if (context.mounted) {
                      interpreter.executeAction(action, context);
                    }
                  }
                }
              },
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            prefixIcon: iconData != null ? Icon(iconData) : null,
            labelText:
                label != null ? interpreter.resolveTemplate(label) : null,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          child: Text(
            displayText,
            style: TextStyle(
              fontSize: 15,
              color: displayText == placeholder
                  ? Theme.of(context).hintColor
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  TimeOfDay? _parseTime(String s) {
    final parts = s.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
