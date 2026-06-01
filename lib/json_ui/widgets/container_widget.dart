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
    final padding = (json['padding'] as num?)?.toDouble() ?? 0;
    final margin = (json['margin'] as num?)?.toDouble() ?? 0;
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 0;
    final elevation = (json['elevation'] as num?)?.toDouble() ?? 0;
    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();

    // 背景色（支持 "{{ loop.item.bubble_color }}" 这类模板）
    final rawColor = json['color']?.toString();
    Color? bgColor = _parseColor(
      rawColor != null ? interpreter.resolveTemplate(rawColor) : null,
    );

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

    Widget container = Container(
      width: width,
      height: height,
      padding: padding > 0 ? EdgeInsets.all(padding) : null,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: borderRadius > 0
            ? BorderRadius.circular(borderRadius)
            : null,
        border: border,
      ),
      child: _wrapWithContrastText(context, bgColor, layoutWidget),
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
          padding: padding > 0 ? EdgeInsets.all(padding) : EdgeInsets.zero,
          child: _wrapWithContrastText(
            context,
            bgColor ?? Theme.of(context).colorScheme.surface,
            layoutWidget,
          ),
        ),
      );
    }

    Widget finalWidget = Padding(
      padding: EdgeInsets.all(margin),
      child: container,
    );

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
}
