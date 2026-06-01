// Text 控件 — 增强版
// 支持：style (fontSize, fontWeight, color, fontStyle, decoration,
//       textAlign, maxLines, overflow, letterSpacing, lineHeight)
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
    final rawValue = json['value'] ?? '';
    final resolvedValue = interpreter.resolveTemplate(rawValue.toString());

    final style = json['style'] as Map<String, dynamic>? ?? {};

    // 字号
    final fontSize = (style['fontSize'] as num?)?.toDouble();

    // 字重
    FontWeight fontWeight = FontWeight.normal;
    final fw = style['fontWeight']?.toString();
    if (fw != null) {
      fontWeight = _parseFontWeight(fw);
    }

    // 颜色
    Color? color = _parseColor(style['color'] as String?);

    // 斜体
    FontStyle fontStyle = FontStyle.normal;
    if (style['fontStyle'] == 'italic') {
      fontStyle = FontStyle.italic;
    }

    // 下划线 / 删除线
    TextDecoration decoration = TextDecoration.none;
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

    // 对齐
    TextAlign textAlign = TextAlign.start;
    switch (style['textAlign']?.toString()) {
      case 'center':
        textAlign = TextAlign.center;
        break;
      case 'right':
        textAlign = TextAlign.right;
        break;
      case 'justify':
        textAlign = TextAlign.justify;
        break;
    }

    // 溢出
    TextOverflow? overflow;
    final maxLines = (style['maxLines'] as num?)?.toInt();
    switch (style['overflow']?.toString()) {
      case 'ellipsis':
        overflow = TextOverflow.ellipsis;
        break;
      case 'clip':
        overflow = TextOverflow.clip;
        break;
      case 'fade':
        overflow = TextOverflow.fade;
        break;
    }

    // 字间距 / 行高
    final letterSpacing = (style['letterSpacing'] as num?)?.toDouble();
    final lineHeight = (style['lineHeight'] as num?)?.toDouble();
    final foreground = _buildForegroundPaint(style);
    final strutStyle = _buildStrutStyle(style);

    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: (style['paddingV'] as num?)?.toDouble() ?? 2,
        horizontal: (style['paddingH'] as num?)?.toDouble() ?? 0,
      ),
      child: Text(
        resolvedValue,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        strutStyle: strutStyle,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: foreground == null ? color : null,
          foreground: foreground,
          fontStyle: fontStyle,
          decoration: decoration,
          letterSpacing: letterSpacing,
          height: lineHeight,
        ),
      ),
    );
  }

  FontWeight _parseFontWeight(String fw) {
    switch (fw) {
      case 'bold':
        return FontWeight.bold;
      case 'w100':
        return FontWeight.w100;
      case 'w200':
        return FontWeight.w200;
      case 'w300':
        return FontWeight.w300;
      case 'w400':
        return FontWeight.w400;
      case 'w500':
        return FontWeight.w500;
      case 'w600':
        return FontWeight.w600;
      case 'w700':
        return FontWeight.w700;
      case 'w800':
        return FontWeight.w800;
      case 'w900':
        return FontWeight.w900;
      default:
        return FontWeight.normal;
    }
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }

  Paint? _buildForegroundPaint(Map<String, dynamic> style) {
    final gradient = style['gradient'];
    final strokeWidth = (style['strokeWidth'] as num?)?.toDouble();
    if (gradient is! List || gradient.isEmpty) {
      if (strokeWidth == null) return null;
      return Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
    }

    final colors = gradient
        .map((value) => _parseColor(value.toString()))
        .whereType<Color>()
        .toList();
    if (colors.isEmpty) return null;
    final width = (style['gradientWidth'] as num?)?.toDouble() ?? 200;
    final height = (style['gradientHeight'] as num?)?.toDouble() ?? 100;
    return Paint()
      ..style = strokeWidth != null ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeWidth = strokeWidth ?? 0
      ..shader = LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: colors,
      ).createShader(Rect.fromLTWH(0, 0, width, height));
  }

  StrutStyle? _buildStrutStyle(Map<String, dynamic> style) {
    final strut = style['strut'];
    if (strut is! Map<String, dynamic>) return null;
    return StrutStyle(
      fontSize: (strut['fontSize'] as num?)?.toDouble(),
      height: (strut['height'] as num?)?.toDouble(),
      leading: (strut['leading'] as num?)?.toDouble(),
      forceStrutHeight: strut['forceStrutHeight'] == true,
    );
  }
}
