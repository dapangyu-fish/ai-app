// Text 控件
// 支持模板变量插值 {{ $.global.xxx }}、自定义样式、position 定位
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonTextWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    // 解析模板字符串，替换 {{ }} 中的变量引用
    final rawValue = json['value'] ?? '';
    final resolvedValue = interpreter.resolveTemplate(rawValue.toString());

    // 解析样式
    final style = json['style'] as Map<String, dynamic>?;
    final fontSize = (style?['fontSize'] as num?)?.toDouble();
    final fontWeight = style?['fontWeight'] == 'bold'
        ? FontWeight.bold
        : FontWeight.normal;
    final colorStr = style?['color'] as String?;
    Color? color;
    if (colorStr != null && colorStr.startsWith('#')) {
      final hex = colorStr.replaceFirst('#', '');
      color = Color(int.parse('FF$hex', radix: 16));
    }

    return Text(
      resolvedValue,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
      ),
    );
  }
}
