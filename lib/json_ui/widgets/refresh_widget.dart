// RefreshIndicator 控件 — 下拉刷新
// 用于包裹任意可滚动的 child（不限于 list）
// 支持: child (必须是可滚动 widget), onRefresh, color, backgroundColor
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonRefreshWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    final onRefresh =
        resolveActionAtBuildTime(json['onRefresh'], interpreter)
            as Map<String, dynamic>?;
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final rawBg = json['backgroundColor']?.toString();
    final bg = _parseColor(
        rawBg != null ? interpreter.resolveTemplate(rawBg) : null);

    if (onRefresh == null) return child;

    return RefreshIndicator(
      color: color,
      backgroundColor: bg,
      onRefresh: () async {
        if (context.mounted) {
          await interpreter.executeAction(onRefresh, context);
        }
      },
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
