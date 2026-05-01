// Card 控件
// 支持: children, layout (row/column), padding, margin, elevation, borderRadius,
//       color, onTap, crossAxisAlignment, mainAxisAlignment
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonCardWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = json['children'] as List<dynamic>? ?? [];
    final layout = json['layout']?.toString() ?? 'column';
    final padding = (json['padding'] as num?)?.toDouble() ?? 16;
    final margin = (json['margin'] as num?)?.toDouble() ?? 8;
    final elevation = (json['elevation'] as num?)?.toDouble() ?? 2;
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 12;
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);

    // build 阶段预解析 onTap 中的 {{ }} 模板
    // —— grid/list item 在循环上下文中构建，点击发生时 loop 上下文已 pop，
    //    必须在此把 {{ loop.item }} / {{ loop.index }} 烘焙进 action
    final rawOnTap = json['onTap'];
    final onTap = rawOnTap is Map<String, dynamic>
        ? resolveActionAtBuildTime(rawOnTap, interpreter)
            as Map<String, dynamic>?
        : null;

    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((c) => interpreter.buildWidget(context, c))
        .toList();

    CrossAxisAlignment crossAlign = layout == 'column'
        ? CrossAxisAlignment.stretch
        : CrossAxisAlignment.center;
    if (json['crossAxisAlignment'] == 'start') {
      crossAlign = CrossAxisAlignment.start;
    } else if (json['crossAxisAlignment'] == 'end') {
      crossAlign = CrossAxisAlignment.end;
    } else if (json['crossAxisAlignment'] == 'center') {
      crossAlign = CrossAxisAlignment.center;
    } else if (json['crossAxisAlignment'] == 'stretch') {
      crossAlign = CrossAxisAlignment.stretch;
    }

    MainAxisAlignment mainAlign = MainAxisAlignment.start;
    if (json['mainAxisAlignment'] == 'center') {
      mainAlign = MainAxisAlignment.center;
    } else if (json['mainAxisAlignment'] == 'end') {
      mainAlign = MainAxisAlignment.end;
    } else if (json['mainAxisAlignment'] == 'spaceBetween') {
      mainAlign = MainAxisAlignment.spaceBetween;
    } else if (json['mainAxisAlignment'] == 'spaceAround') {
      mainAlign = MainAxisAlignment.spaceAround;
    } else if (json['mainAxisAlignment'] == 'spaceEvenly') {
      mainAlign = MainAxisAlignment.spaceEvenly;
    }

    final layoutWidget = layout == 'row'
        ? Row(
            crossAxisAlignment: crossAlign,
            mainAxisAlignment: mainAlign,
            children: childWidgets,
          )
        : Column(
            crossAxisAlignment: crossAlign,
            mainAxisAlignment: mainAlign,
            mainAxisSize: MainAxisSize.min,
            children: childWidgets,
          );

    Widget card = Card(
      elevation: elevation,
      color: color,
      margin: EdgeInsets.all(margin),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: layoutWidget,
      ),
    );

    if (onTap != null) {
      // 点击波纹效果（包在 Card 内部）
      card = Card(
        elevation: elevation,
        color: color,
        margin: EdgeInsets.all(margin),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => interpreter.executeAction(onTap, context),
          borderRadius: BorderRadius.circular(borderRadius),
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: layoutWidget,
          ),
        ),
      );
    }

    return card;
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
