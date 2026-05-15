// DatePicker 控件 — 点击触发 showDatePicker，选中后写回 bind 变量（ISO 8601 字符串）
// 支持: bind (yyyy-MM-dd 格式), placeholder, label, prefixIcon, action,
//       firstDate (yyyy-MM-dd), lastDate (yyyy-MM-dd), disabled, format
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import 'action_helper.dart';
import '../interpreter.dart';
import '../../i18n/framework_strings.dart';

class JsonDatePickerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final placeholder = interpreter.resolveTemplate(
        json['placeholder']?.toString() ?? T.of(context).widgetDatePickerPlaceholder);
    final label = json['label']?.toString();
    final prefixIcon = json['prefixIcon']?.toString() ?? 'calendar';
    final action =
        resolveActionAtBuildTime(json['action'], interpreter)
            as Map<String, dynamic>?;
    final disabled = json['disabled'] == true;

    final firstDate = _parseDate(json['firstDate']?.toString()) ??
        DateTime(DateTime.now().year - 50);
    final lastDate = _parseDate(json['lastDate']?.toString()) ??
        DateTime(DateTime.now().year + 50);

    String displayText = placeholder;
    DateTime initial = DateTime.now();
    if (bindPath != null) {
      final v = interpreter.getVariable(bindPath);
      if (v is String && v.isNotEmpty) {
        final parsed = _parseDate(v);
        if (parsed != null) {
          initial = parsed;
          displayText = _formatDate(parsed);
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
                final picked = await showDatePicker(
                  context: context,
                  initialDate:
                      initial.isBefore(firstDate) ? firstDate : initial,
                  firstDate: firstDate,
                  lastDate: lastDate,
                );
                if (picked != null) {
                  if (bindPath != null) {
                    interpreter.setVariable(bindPath, _formatDate(picked));
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
            labelText: label != null ? interpreter.resolveTemplate(label) : null,
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

  DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      // yyyy-MM-dd 或 ISO 8601
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  String _formatDate(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}
