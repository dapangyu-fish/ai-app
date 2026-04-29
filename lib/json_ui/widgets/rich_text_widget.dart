// RichText 控件 — 多样式文本拼接
// 用法: spans 数组，每项可以是字符串或 { text, style }
//
// 示例：
// {
//   "type": "rich_text",
//   "spans": [
//     { "text": "总计 " },
//     { "text": "{{ global.count }}", "style": { "fontWeight": "bold", "color": "#E74C3C" } },
//     { "text": " 条结果" }
//   ]
// }
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonRichTextWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawSpans = json['spans'];
    final defaultStyle = json['style'] as Map<String, dynamic>? ?? {};
    final textAlign = _parseTextAlign(json['textAlign']?.toString());

    final spans = <InlineSpan>[];
    if (rawSpans is List) {
      for (final s in rawSpans) {
        if (s is String) {
          spans.add(TextSpan(
            text: interpreter.resolveTemplate(s),
            style: _buildStyle(context, defaultStyle, interpreter),
          ));
        } else if (s is Map) {
          final txt = interpreter
              .resolveTemplate(s['text']?.toString() ?? '');
          final styleMap =
              (s['style'] as Map?)?.cast<String, dynamic>() ?? {};
          // 子 span 的 style 与默认样式合并（子项覆盖默认）
          final merged = <String, dynamic>{}..addAll(defaultStyle)..addAll(styleMap);
          spans.add(TextSpan(
            text: txt,
            style: _buildStyle(context, merged, interpreter),
          ));
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(
        TextSpan(children: spans),
        textAlign: textAlign,
      ),
    );
  }

  TextStyle _buildStyle(
    BuildContext context,
    Map<String, dynamic> style,
    JsonInterpreter interpreter,
  ) {
    final fontSize = (style['fontSize'] as num?)?.toDouble();
    final rawColor = style['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    FontWeight? fontWeight;
    final fw = style['fontWeight']?.toString();
    if (fw != null) fontWeight = _parseFontWeight(fw);
    FontStyle? fontStyle;
    if (style['fontStyle'] == 'italic') fontStyle = FontStyle.italic;
    TextDecoration? decoration;
    switch (style['decoration']?.toString()) {
      case 'underline':
        decoration = TextDecoration.underline;
        break;
      case 'lineThrough':
        decoration = TextDecoration.lineThrough;
        break;
      case 'overline':
        decoration = TextDecoration.overline;
        break;
    }
    return TextStyle(
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      decoration: decoration,
    );
  }

  FontWeight _parseFontWeight(String fw) {
    switch (fw) {
      case 'bold':
        return FontWeight.bold;
      case 'w100':
        return FontWeight.w100;
      case 'w300':
        return FontWeight.w300;
      case 'w500':
        return FontWeight.w500;
      case 'w700':
        return FontWeight.w700;
      case 'w900':
        return FontWeight.w900;
      default:
        return FontWeight.normal;
    }
  }

  TextAlign _parseTextAlign(String? s) {
    switch (s) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      default:
        return TextAlign.start;
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
