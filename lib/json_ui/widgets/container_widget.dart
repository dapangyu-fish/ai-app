// Container 控件 — 增强版
// 支持：children, layout (row/column/stack), color, padding, margin,
//       borderRadius, border { color, width }, elevation, width, height
//       layout=stack 时子项可用 position.type=absolute 绝对定位
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonContainerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = json['children'] as List<dynamic>? ?? [];
    final layout = json['layout'] ?? 'row';
    final padding = _resolveInsets(interpreter, json['padding']);
    final margin = _resolveInsets(interpreter, json['margin']);
    final borderRadius = _resolveDouble(interpreter, json['borderRadius']) ?? 0;
    final elevation = _resolveDouble(interpreter, json['elevation']) ?? 0;
    final width = _resolveDouble(interpreter, json['width']);
    final height = _resolveDouble(interpreter, json['height']);
    final constraints = _parseConstraints(interpreter, json['constraints']);
    final alignment = _parseAlignment(json['alignment']?.toString());

    // 背景色（支持 "{{ loop.item.bubble_color }}" 这类模板）
    final rawColor = json['color']?.toString();
    Color? bgColor = _parseColor(
      rawColor != null ? interpreter.resolveTemplate(rawColor) : null,
    );
    final gradient = _parseGradient(interpreter, json['gradient']);

    // 边框
    Border? border;
    final borderDef = json['border'] as Map<String, dynamic>?;
    if (borderDef != null) {
      final rawBorderColor = borderDef['color']?.toString();
      final borderColor =
          _parseColor(
            rawBorderColor != null
                ? interpreter.resolveTemplate(rawBorderColor)
                : null,
          ) ??
          Colors.grey;
      final borderWidth = (borderDef['width'] as num?)?.toDouble() ?? 1;
      border = Border.all(color: borderColor, width: borderWidth);
    }

    // 构建子控件
    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((childJson) => interpreter.buildWidget(context, childJson))
        .toList();

    CrossAxisAlignment crossAlign = CrossAxisAlignment.center;
    if (json['crossAxisAlignment'] == 'start') {
      crossAlign = CrossAxisAlignment.start;
    } else if (json['crossAxisAlignment'] == 'end') {
      crossAlign = CrossAxisAlignment.end;
    } else if (json['crossAxisAlignment'] == 'stretch') {
      crossAlign = CrossAxisAlignment.stretch;
    } else if (layout == 'column' && json['crossAxisAlignment'] == null) {
      crossAlign = CrossAxisAlignment.stretch;
    }

    MainAxisAlignment mainAlign = MainAxisAlignment.start;
    if (json['mainAxisAlignment'] == 'center') {
      mainAlign = MainAxisAlignment.center;
    } else if (json['mainAxisAlignment'] == 'end') {
      mainAlign = MainAxisAlignment.end;
    } else if (json['mainAxisAlignment'] == 'spaceBetween') {
      mainAlign = MainAxisAlignment.spaceBetween;
    }

    Widget layoutWidget;
    if (layout == 'row') {
      layoutWidget = Row(
        crossAxisAlignment: crossAlign,
        mainAxisAlignment: mainAlign,
        children: childWidgets,
      );
      if (json['scrollDirection'] == 'horizontal') {
        layoutWidget = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: layoutWidget,
        );
      }
    } else if (layout == 'stack') {
      layoutWidget = Stack(clipBehavior: Clip.none, children: childWidgets);
    } else {
      layoutWidget = Column(
        crossAxisAlignment: crossAlign,
        mainAxisAlignment: mainAlign,
        mainAxisSize: MainAxisSize.min,
        children: childWidgets,
      );
    }

    final shape = json['shape']?.toString();
    final clipBehavior = switch (json['clipBehavior']?.toString()) {
      'hardEdge' => Clip.hardEdge,
      'antiAlias' => Clip.antiAlias,
      'antiAliasWithSaveLayer' => Clip.antiAliasWithSaveLayer,
      _ => Clip.none,
    };

    Widget container = Container(
      width: width,
      height: height,
      constraints: constraints,
      alignment: alignment,
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? bgColor : null,
        gradient: gradient,
        shape: shape == 'circle' ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: shape == 'circle'
            ? null
            : (borderRadius > 0 ? BorderRadius.circular(borderRadius) : null),
        border: border,
      ),
      clipBehavior: clipBehavior,
      child: _wrapWithContrastText(
        context,
        bgColor ?? _firstGradientColor(gradient),
        layoutWidget,
      ),
    );

    // 阴影 (elevation)
    if (elevation > 0) {
      container = Material(
        elevation: elevation,
        borderRadius: borderRadius > 0
            ? BorderRadius.circular(borderRadius)
            : null,
        color: bgColor ?? Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: padding ?? EdgeInsets.zero,
          child: _wrapWithContrastText(
            context,
            bgColor ?? Theme.of(context).colorScheme.surface,
            layoutWidget,
          ),
        ),
      );
    }

    Widget finalWidget = margin == null
        ? container
        : Padding(padding: margin, child: container);

    // 点击事件 (onTap)
    // build 阶段预解析 action 中的 {{ }}：list / grid 的 item_template 在用户点击
    // 时 loop.item / loop.index 已经被 pop，所以模板必须在循环上下文还在的 build
    // 阶段就解析掉。和 button / card / inkwell 等控件保持一致行为。
    final rawOnTap = json['onTap'];
    final onTapDef = rawOnTap is Map<String, dynamic>
        ? resolveActionAtBuildTime(rawOnTap, interpreter)
              as Map<String, dynamic>?
        : null;
    if (onTapDef != null) {
      return GestureDetector(
        onTap: () => interpreter.executeAction(onTapDef, context),
        child: finalWidget,
      );
    }

    return finalWidget;
  }

  /// 当容器有背景色时，自动为子控件设置对比文字颜色
  /// 防止 AI 生成的 JSON-APP 出现背景色和文字颜色相近导致看不清的问题
  Widget _wrapWithContrastText(
    BuildContext context,
    Color? bgColor,
    Widget child,
  ) {
    if (bgColor == null) return child;

    // 计算背景亮度，选择对比文字颜色
    final luminance = bgColor.computeLuminance();
    final contrastColor = luminance > 0.5
        ? const Color(0xFF1A1A1A) // 浅色背景 → 深色文字
        : const Color(0xFFFFFFFF); // 深色背景 → 白色文字

    return DefaultTextStyle.merge(
      style: TextStyle(color: contrastColor),
      child: child,
    );
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }

  Gradient? _parseGradient(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    List<dynamic>? rawColors;
    String? begin;
    String? end;
    if (value is List) {
      rawColors = value;
    } else if (value is Map<String, dynamic>) {
      final colors = value['colors'];
      if (colors is List) rawColors = colors;
      begin = value['begin']?.toString();
      end = value['end']?.toString();
    }
    if (rawColors == null || rawColors.length < 2) return null;
    final colors = rawColors
        .map((raw) => _parseColor(interpreter.resolveTemplate(raw.toString())))
        .whereType<Color>()
        .toList();
    if (colors.length < 2) return null;
    return LinearGradient(
      colors: colors,
      begin: _parseGradientAlignment(begin) ?? Alignment.topCenter,
      end: _parseGradientAlignment(end) ?? Alignment.bottomCenter,
    );
  }

  Alignment? _parseGradientAlignment(String? value) {
    return switch (value) {
      'topLeft' => Alignment.topLeft,
      'topCenter' => Alignment.topCenter,
      'topRight' => Alignment.topRight,
      'centerLeft' => Alignment.centerLeft,
      'centerRight' => Alignment.centerRight,
      'bottomLeft' => Alignment.bottomLeft,
      'bottomCenter' => Alignment.bottomCenter,
      'bottomRight' => Alignment.bottomRight,
      _ => null,
    };
  }

  Color? _firstGradientColor(Gradient? gradient) {
    if (gradient is LinearGradient && gradient.colors.isNotEmpty) {
      return gradient.colors.first;
    }
    return null;
  }

  double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final resolved = interpreter.resolveExpression(value);
    if (resolved is num) return resolved.toDouble();
    return double.tryParse(resolved?.toString() ?? '');
  }

  EdgeInsets? _resolveInsets(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final v = value.toDouble();
      return v == 0 ? null : EdgeInsets.all(v);
    }
    if (value is String) {
      final resolved = interpreter.resolveExpression(value);
      if (resolved is num) {
        final v = resolved.toDouble();
        return v == 0 ? null : EdgeInsets.all(v);
      }
      final parsed = double.tryParse(resolved?.toString() ?? '');
      return parsed == null || parsed == 0 ? null : EdgeInsets.all(parsed);
    }
    if (value is Map<String, dynamic>) {
      final all = _resolveDouble(interpreter, value['all']);
      if (all != null) return all == 0 ? null : EdgeInsets.all(all);
      final horizontal = _resolveDouble(interpreter, value['horizontal']) ?? 0;
      final vertical = _resolveDouble(interpreter, value['vertical']) ?? 0;
      final left = _resolveDouble(interpreter, value['left']) ?? horizontal;
      final right = _resolveDouble(interpreter, value['right']) ?? horizontal;
      final top = _resolveDouble(interpreter, value['top']) ?? vertical;
      final bottom = _resolveDouble(interpreter, value['bottom']) ?? vertical;
      if (left == 0 && right == 0 && top == 0 && bottom == 0) return null;
      return EdgeInsets.fromLTRB(left, top, right, bottom);
    }
    return null;
  }

  BoxConstraints? _parseConstraints(
    JsonInterpreter interpreter,
    dynamic value,
  ) {
    if (value is! Map<String, dynamic>) return null;
    final minWidth = _resolveDouble(interpreter, value['minWidth']) ?? 0;
    final minHeight = _resolveDouble(interpreter, value['minHeight']) ?? 0;
    final maxWidth =
        _resolveDouble(interpreter, value['maxWidth']) ?? double.infinity;
    final maxHeight =
        _resolveDouble(interpreter, value['maxHeight']) ?? double.infinity;
    return BoxConstraints(
      minWidth: minWidth,
      minHeight: minHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
  }

  Alignment? _parseAlignment(String? value) {
    return switch (value) {
      'topLeft' => Alignment.topLeft,
      'topCenter' => Alignment.topCenter,
      'topRight' => Alignment.topRight,
      'centerLeft' => Alignment.centerLeft,
      'center' => Alignment.center,
      'centerRight' => Alignment.centerRight,
      'bottomLeft' => Alignment.bottomLeft,
      'bottomCenter' => Alignment.bottomCenter,
      'bottomRight' => Alignment.bottomRight,
      _ => null,
    };
  }
}
