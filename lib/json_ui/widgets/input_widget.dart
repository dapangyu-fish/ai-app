// Input 控件 — 增强版
// 支持：placeholder, bind, maxLines, keyboardType, obscureText,
//       prefix, suffix, style (borderRadius, fontSize, fillColor)
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';
import 'icon_registry.dart';

class JsonInputWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final placeholder = interpreter.resolveTemplate(
      json['placeholder']?.toString() ?? '',
    );
    final bindPath = json['bind'] as String?;
    final maxLines = (json['maxLines'] as num?)?.toInt() ?? 1;
    final obscureText = json['obscureText'] == true;
    final prefix = json['prefix']?.toString();
    final suffix = json['suffix']?.toString();
    final prefixIcon = json['prefixIcon']?.toString();
    final suffixIcon = json['suffixIcon']?.toString();
    final rawLabel = json['label']?.toString();
    final label = rawLabel != null
        ? interpreter.resolveTemplate(rawLabel)
        : null;
    final style = json['style'] as Map<String, dynamic>? ?? {};

    // 键盘类型
    TextInputType keyboardType = TextInputType.text;
    switch (json['keyboardType']?.toString()) {
      case 'number':
        keyboardType = TextInputType.number;
        break;
      case 'email':
        keyboardType = TextInputType.emailAddress;
        break;
      case 'phone':
        keyboardType = TextInputType.phone;
        break;
      case 'url':
        keyboardType = TextInputType.url;
        break;
      case 'multiline':
        keyboardType = TextInputType.multiline;
        break;
    }

    // 样式
    final borderRadius = (style['borderRadius'] as num?)?.toDouble() ?? 8;
    final fontSize = (style['fontSize'] as num?)?.toDouble() ?? 14;
    final borderStyle = style['border']?.toString() ?? 'outline';
    final fillColorStr = style['fillColor'] as String?;
    Color? fillColor;
    if (fillColorStr != null && fillColorStr.startsWith('#')) {
      final hex = fillColorStr.replaceFirst('#', '');
      fillColor = Color(int.parse('FF$hex', radix: 16));
    }

    final currentValue = bindPath != null
        ? interpreter.getVariable(bindPath)?.toString() ?? ''
        : '';

    final InputBorder border;
    final InputBorder enabledBorder;
    final InputBorder focusedBorder;
    if (borderStyle == 'underline') {
      border = const UnderlineInputBorder();
      enabledBorder = UnderlineInputBorder(
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
        ),
      );
      focusedBorder = UnderlineInputBorder(
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      );
    } else if (borderStyle == 'none') {
      border = InputBorder.none;
      enabledBorder = InputBorder.none;
      focusedBorder = InputBorder.none;
    } else {
      border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      );
      enabledBorder = OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
        ),
      );
      focusedBorder = OutlineInputBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: interpreter.getTextController(bindPath ?? '', currentValue),
        maxLines: obscureText ? 1 : maxLines,
        obscureText: obscureText,
        keyboardType: keyboardType,
        style: TextStyle(fontSize: fontSize),
        decoration: InputDecoration(
          hintText: placeholder,
          labelText: label,
          prefixText: prefix,
          suffixText: suffix,
          prefixIcon: prefixIcon != null
              ? Icon(IconRegistry.get(prefixIcon))
              : null,
          suffixIcon: suffixIcon != null
              ? Icon(IconRegistry.get(suffixIcon))
              : null,
          filled: fillColor != null,
          fillColor: fillColor,
          border: border,
          enabledBorder: enabledBorder,
          focusedBorder: focusedBorder,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        ),
        onChanged: (value) {
          if (bindPath != null) {
            interpreter.setVariable(bindPath, value);
          }
        },
      ),
    );
  }
}
