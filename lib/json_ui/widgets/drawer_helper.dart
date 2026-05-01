// Drawer 构建器 — 由 screen.drawer 配置驱动
// 配置格式：
// {
//   "drawer": {
//     "header": { ...widget... },           // 可选，drawer 顶部
//     "items": [
//       { "icon": "home",     "label": "首页",  "action": {...} },
//       { "icon": "settings", "label": "设置",  "action": {...} }
//     ],
//     "backgroundColor": "#FFFFFF"
//   }
// }
import 'package:flutter/material.dart';
import 'icon_registry.dart';
import '../interpreter.dart';

Widget buildDrawer(
  BuildContext context,
  Map<String, dynamic> json,
  JsonInterpreter interpreter,
) {
  final headerJson = json['header'] as Map<String, dynamic>?;
  final rawItems = json['items'];
  final bgColorStr = json['backgroundColor']?.toString();
  Color? bgColor;
  if (bgColorStr != null && bgColorStr.startsWith('#')) {
    final hex = bgColorStr.replaceFirst('#', '');
    if (hex.length == 6) bgColor = Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) bgColor = Color(int.parse(hex, radix: 16));
  }

  final children = <Widget>[];
  if (headerJson != null) {
    children.add(SizedBox(
      width: double.infinity,
      child: DrawerHeader(
        margin: EdgeInsets.zero,
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary),
        child: interpreter.buildWidget(context, headerJson),
      ),
    ));
  }

  if (rawItems is List) {
    for (final raw in rawItems) {
      if (raw is Map<String, dynamic>) {
        final iconName = raw['icon']?.toString();
        final iconData = iconName != null ? IconRegistry.get(iconName) : null;
        final label = interpreter
            .resolveTemplate(raw['label']?.toString() ?? '');
        final action = raw['action'] as Map<String, dynamic>?;
        children.add(ListTile(
          leading: iconData != null ? Icon(iconData) : null,
          title: Text(label),
          onTap: () {
            // 关闭 drawer 后再执行 action
            Navigator.of(context).pop();
            if (action != null) {
              interpreter.executeAction(action, context);
            }
          },
        ));
      }
    }
  }

  return Drawer(
    backgroundColor: bgColor,
    child: SafeArea(
      child: ListView(padding: EdgeInsets.zero, children: children),
    ),
  );
}
