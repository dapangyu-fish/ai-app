// MaterialButton 控件
// 支持: label, color, textColor, minWidth, height, action
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonMaterialButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawLabel = json['label'];
    final label = rawLabel == null
        ? null
        : interpreter.resolveTemplate(rawLabel.toString());
    final action = json['action'] as Map<String, dynamic>?;
    final resolvedAction = action != null
        ? resolveActionAtBuildTime(action, interpreter) as Map<String, dynamic>?
        : null;

    return MaterialButton(
      onPressed: resolvedAction == null
          ? () {}
          : () => interpreter.executeAction(resolvedAction, context),
      color: _parseColor(json['color']?.toString()),
      textColor: _parseColor(json['textColor']?.toString()),
      minWidth: (json['minWidth'] as num?)?.toDouble(),
      height: (json['height'] as num?)?.toDouble(),
      child: label == null || label.isEmpty ? null : Text(label),
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
