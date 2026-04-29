// TabView 控件 — 单 widget 包含 TabBar + TabBarView
// 支持: tabs ([{label, icon?, content}]),
//       initialIndex (默认 0), color (选中颜色), backgroundColor (TabBar 背景色),
//       isScrollable (默认 false), onTabChange action
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import '../interpreter.dart';

class JsonTabViewWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawTabs = json['tabs'];
    if (rawTabs is! List || rawTabs.isEmpty) {
      return const SizedBox.shrink();
    }

    final initialIndex = (json['initialIndex'] as num?)?.toInt() ?? 0;
    final isScrollable = json['isScrollable'] == true;
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final rawBg = json['backgroundColor']?.toString();
    final bg = _parseColor(
        rawBg != null ? interpreter.resolveTemplate(rawBg) : null);
    final onTabChangeDef = json['onTabChange'];

    final tabs = <Tab>[];
    final contents = <Widget>[];
    for (final t in rawTabs) {
      if (t is Map<String, dynamic>) {
        final label = interpreter.resolveTemplate(t['label']?.toString() ?? '');
        final iconName = t['icon']?.toString();
        final iconData = iconName != null ? IconRegistry.get(iconName) : null;
        tabs.add(Tab(
          text: label,
          icon: iconData != null ? Icon(iconData) : null,
        ));
        final content = t['content'];
        if (content is Map<String, dynamic>) {
          contents.add(interpreter.buildWidget(context, content));
        } else {
          contents.add(const SizedBox.shrink());
        }
      }
    }

    return DefaultTabController(
      length: tabs.length,
      initialIndex: initialIndex.clamp(0, tabs.length - 1),
      child: Builder(
        builder: (innerCtx) {
          // 监听 tab 变化触发回调
          if (onTabChangeDef != null) {
            final controller = DefaultTabController.of(innerCtx);
            controller.addListener(() {
              if (!controller.indexIsChanging) {
                interpreter.executeAction(
                    Map<String, dynamic>.from(onTabChangeDef as Map),
                    innerCtx);
              }
            });
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                color: bg,
                child: TabBar(
                  tabs: tabs,
                  isScrollable: isScrollable,
                  labelColor: color,
                  indicatorColor: color,
                ),
              ),
              SizedBox(
                // 高度由 children 决定不可行（TabBarView 需要明确高度）
                height: (json['height'] as num?)?.toDouble() ?? 400,
                child: TabBarView(children: contents),
              ),
            ],
          );
        },
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
