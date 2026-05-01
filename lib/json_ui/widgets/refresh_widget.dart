// RefreshIndicator 控件 — 下拉刷新
// 用于包裹任意可滚动的 child（list / 普通 ListView 等）
// 支持: child (必须是可滚动 widget), onRefresh, color, backgroundColor
//
// 注意：list 控件默认返回 Expanded(ListView)。直接放进 RefreshIndicator
// 会让 Expanded 处于非 Flex 父级，触发 Flutter assert。所以这里：
//   1. 自动 unwrap 子级 Expanded
//   2. 整体再用 Expanded 包一层（refresh 期望放在 Column 屏幕里）
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

    // 兜底：list 默认返回 Expanded → unwrap 后给 RefreshIndicator
    if (child is Expanded) {
      child = child.child;
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

    if (onRefresh == null) {
      return Expanded(child: child);
    }

    return Expanded(
      child: RefreshIndicator(
        color: color,
        backgroundColor: bg,
        onRefresh: () async {
          if (context.mounted) {
            await interpreter.executeAction(onRefresh, context);
          }
        },
        child: child,
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
