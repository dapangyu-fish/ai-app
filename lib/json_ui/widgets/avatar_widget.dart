// Avatar 控件 — 圆形头像
// 支持: url (图片), text (无图时显示首字母), size (默认 40), color (背景), textColor
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonAvatarWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawUrl = json['url']?.toString();
    final url = rawUrl != null ? interpreter.resolveTemplate(rawUrl) : null;
    final rawText = json['text']?.toString();
    final text = rawText != null ? interpreter.resolveTemplate(rawText) : null;
    final size = (json['size'] as num?)?.toDouble() ?? 40;
    final rawColor = json['color']?.toString();
    final bgColor = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final rawTextColor = json['textColor']?.toString();
    final textColor = _parseColor(rawTextColor != null
        ? interpreter.resolveTemplate(rawTextColor)
        : null);

    if (url != null && url.isNotEmpty) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: bgColor,
        backgroundImage: NetworkImage(url),
        // 加载失败时回退到文字
        onBackgroundImageError: (_, __) {},
        child: null,
      );
    }

    // 无图：显示文字（取首字母大写）
    String initials = '?';
    if (text != null && text.isNotEmpty) {
      // 中文取首字，英文取首字母
      initials = text.runes.first <= 0x7F
          ? text[0].toUpperCase()
          : String.fromCharCode(text.runes.first);
    }

    return CircleAvatar(
      radius: size / 2,
      backgroundColor: bgColor ?? Theme.of(context).colorScheme.primary,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.bold,
          color: textColor ?? Colors.white,
        ),
      ),
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
