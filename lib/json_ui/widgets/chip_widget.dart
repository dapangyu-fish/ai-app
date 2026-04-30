// Chip 控件
// 三种 variant：
//   - chip (默认)：单纯标签
//   - choice：单选（bind=true 时高亮）
//   - filter：多选（bind 是 List，包含此值时选中）
// 支持: label, variant (chip/choice/filter), bind, value (filter/choice 用),
//       icon, action, color, deletable
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import '../interpreter.dart';

class JsonChipWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final label = interpreter.resolveTemplate(json['label']?.toString() ?? '');
    final variant = json['variant']?.toString() ?? 'chip';
    final bindPath = json['bind'] as String?;
    final value = interpreter.resolveExpression(json['value']);
    final iconName = json['icon']?.toString();
    final action = json['action'] as Map<String, dynamic>?;
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final deletable = json['deletable'] == true;

    final iconData = iconName != null ? IconRegistry.get(iconName) : null;
    final avatar = iconData != null ? Icon(iconData, size: 16) : null;

    void onDeleted() {
      if (action != null) {
        interpreter.executeAction(action, context);
      }
    }

    switch (variant) {
      case 'choice':
        bool selected = false;
        if (bindPath != null) {
          final v = interpreter.getVariable(bindPath);
          selected = value != null ? v == value : v == true;
        }
        return ChoiceChip(
          label: Text(label),
          avatar: avatar,
          selected: selected,
          selectedColor: color?.withValues(alpha: 0.3),
          onSelected: (s) {
            if (bindPath != null) {
              interpreter.setVariable(bindPath, value ?? s);
            }
            if (action != null) {
              interpreter.executeAction(action, context);
            }
          },
        );
      case 'filter':
        bool selected = false;
        if (bindPath != null) {
          final v = interpreter.getVariable(bindPath);
          if (v is List && value != null) {
            selected = v.contains(value);
          }
        }
        return FilterChip(
          label: Text(label),
          avatar: avatar,
          selected: selected,
          selectedColor: color?.withValues(alpha: 0.3),
          onSelected: (s) {
            if (bindPath != null && value != null) {
              final cur = interpreter.getVariable(bindPath);
              final list = cur is List ? List<dynamic>.from(cur) : <dynamic>[];
              if (s) {
                if (!list.contains(value)) list.add(value);
              } else {
                list.removeWhere((e) => e == value);
              }
              interpreter.setVariable(bindPath, list);
            }
            if (action != null) {
              interpreter.executeAction(action, context);
            }
          },
        );
      case 'chip':
      default:
        return Chip(
          label: Text(label),
          avatar: avatar,
          backgroundColor: color,
          onDeleted: deletable ? onDeleted : null,
          deleteIcon: deletable ? const Icon(Icons.close, size: 16) : null,
        );
    }
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
