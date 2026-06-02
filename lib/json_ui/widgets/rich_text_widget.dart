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
import 'action_helper.dart';
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
          spans.add(
            TextSpan(
              text: interpreter.resolveTemplate(s),
              style: _buildStyle(context, defaultStyle, interpreter),
            ),
          );
        } else if (s is Map) {
          final span = _buildSpan(
            context,
            s.cast<String, dynamic>(),
            defaultStyle,
            interpreter,
          );
          if (span != null) {
            spans.add(span);
            continue;
          }
          final txt = interpreter.resolveTemplate(s['text']?.toString() ?? '');
          final styleMap = (s['style'] as Map?)?.cast<String, dynamic>() ?? {};
          // 子 span 的 style 与默认样式合并（子项覆盖默认）
          final merged = <String, dynamic>{}
            ..addAll(defaultStyle)
            ..addAll(styleMap);
          spans.add(
            TextSpan(
              text: txt,
              style: _buildStyle(context, merged, interpreter),
            ),
          );
        }
      }
    }

    Widget text = Text.rich(TextSpan(children: spans), textAlign: textAlign);
    if (json['selectable'] == true) {
      text = SelectionArea(child: text);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: text,
    );
  }

  InlineSpan? _buildSpan(
    BuildContext context,
    Map<String, dynamic> span,
    Map<String, dynamic> defaultStyle,
    JsonInterpreter interpreter,
  ) {
    final type = span['type']?.toString();
    if (type == 'image') {
      final src = interpreter.resolveTemplate(
        (span['src'] ?? span['url'] ?? '').toString(),
      );
      final width = _resolveDouble(interpreter, span['width']) ?? 24;
      final height = _resolveDouble(interpreter, span['height']) ?? 24;
      final marginH = (span['marginH'] as num?)?.toDouble() ?? 0;
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: marginH),
          child: Image.network(
            src,
            width: width,
            height: height,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => SizedBox(
              width: width,
              height: height,
              child: const Icon(Icons.broken_image, size: 16),
            ),
          ),
        ),
      );
    }
    if (type == 'widget') {
      final childJson = span['child'];
      Widget child = childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink();
      if (span['selectable'] == false) {
        child = SelectionContainer.disabled(child: child);
      }
      return WidgetSpan(
        alignment: _parsePlaceholderAlignment(span['alignment']?.toString()),
        child: child,
      );
    }
    if (!span.containsKey('onTap')) return null;
    final txt = interpreter.resolveTemplate(span['text']?.toString() ?? '');
    final styleMap = (span['style'] as Map?)?.cast<String, dynamic>() ?? {};
    final merged = <String, dynamic>{}
      ..addAll(defaultStyle)
      ..addAll(styleMap);
    final action = resolveActionAtBuildTime(span['onTap'], interpreter);
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        onTap: action is Map<String, dynamic>
            ? () => interpreter.executeAction(action, context)
            : null,
        child: Text(txt, style: _buildStyle(context, merged, interpreter)),
      ),
    );
  }

  TextStyle _buildStyle(
    BuildContext context,
    Map<String, dynamic> style,
    JsonInterpreter interpreter,
  ) {
    final fontSize = _resolveDouble(interpreter, style['fontSize']);
    final rawColor = style['color']?.toString();
    final color = _parseColor(
      rawColor != null ? interpreter.resolveTemplate(rawColor) : null,
    );
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

  PlaceholderAlignment _parsePlaceholderAlignment(String? s) {
    switch (s) {
      case 'top':
        return PlaceholderAlignment.top;
      case 'bottom':
        return PlaceholderAlignment.bottom;
      case 'baseline':
        return PlaceholderAlignment.baseline;
      case 'middle':
      default:
        return PlaceholderAlignment.middle;
    }
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }

  double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final resolved = interpreter.resolveExpression(value);
    if (resolved is num) return resolved.toDouble();
    return double.tryParse(resolved?.toString() ?? '');
  }
}
