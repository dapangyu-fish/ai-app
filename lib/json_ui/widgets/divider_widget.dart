// Divider 控件
// 支持 height, thickness, color, indent
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonDividerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final height = (json['height'] as num?)?.toDouble() ?? 16;
    final thickness = (json['thickness'] as num?)?.toDouble() ?? 1;
    final indent = (json['indent'] as num?)?.toDouble() ?? 0;
    final colorStr = json['color'] as String?;

    Color? color;
    if (colorStr != null && colorStr.startsWith('#')) {
      final hex = colorStr.replaceFirst('#', '');
      color = Color(int.parse('FF$hex', radix: 16));
    }

    return Divider(
      height: height,
      thickness: thickness,
      indent: indent,
      endIndent: indent,
      color: color,
    );
  }
}
