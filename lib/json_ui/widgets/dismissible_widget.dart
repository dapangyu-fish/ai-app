// Dismissible 控件 — 滑动删除/确认
// 通常用作 list 的 item_template 包装层
// 支持: key (必填，唯一标识), child, direction (horizontal/leftToRight/rightToLeft/
//       up/down/vertical), onDismissed, background, secondaryBackground,
//       confirmAction (执行前调用，返回 truthy 才执行 onDismissed)
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonDismissibleWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawKey = json['key']?.toString();
    final keyStr = rawKey != null ? interpreter.resolveTemplate(rawKey) : null;
    if (keyStr == null || keyStr.isEmpty) {
      return _buildChild(context, json, interpreter);
    }

    final direction = _parseDirection(json['direction']?.toString());

    final onDismissed =
        resolveActionAtBuildTime(json['onDismissed'], interpreter)
            as Map<String, dynamic>?;
    // confirmAction 同样需要预解析，以便在循环 item_template 里也能拿到 loop.* 上下文
    final confirmActionDef =
        resolveActionAtBuildTime(json['confirmAction'], interpreter)
            as Map<String, dynamic>?;

    Widget? bg = _buildBackground(context, json['background'], interpreter,
        defaultColor: Colors.red, defaultIcon: Icons.delete, alignLeft: true);
    Widget? secondaryBg = _buildBackground(
        context, json['secondaryBackground'], interpreter,
        defaultColor: Colors.red, defaultIcon: Icons.delete, alignLeft: false);

    return Dismissible(
      key: ValueKey(keyStr),
      direction: direction,
      background: bg,
      secondaryBackground: secondaryBg,
      confirmDismiss: confirmActionDef != null
          ? (dir) async {
              // 走 executeAction 期望返回 truthy / "delete" 之类
              final result =
                  await interpreter.executeActionWithResult(confirmActionDef, context);
              if (result == true) return true;
              if (result is String && result.isNotEmpty && result != 'cancel') {
                return true;
              }
              return false;
            }
          : null,
      onDismissed: onDismissed != null
          ? (_) => interpreter.executeAction(onDismissed, context)
          : null,
      child: _buildChild(context, json, interpreter),
    );
  }

  Widget _buildChild(BuildContext context, Map<String, dynamic> json,
      JsonInterpreter interpreter) {
    final childJson = json['child'];
    if (childJson is Map<String, dynamic>) {
      return interpreter.buildWidget(context, childJson);
    }
    return const SizedBox.shrink();
  }

  Widget? _buildBackground(BuildContext context, dynamic raw,
      JsonInterpreter interpreter,
      {required Color defaultColor,
      required IconData defaultIcon,
      required bool alignLeft}) {
    if (raw is Map<String, dynamic>) {
      // 用户自定义 widget
      return interpreter.buildWidget(context, raw);
    }
    if (raw == false) return null;
    // 默认红色 + 图标
    return Container(
      color: defaultColor,
      alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Icon(defaultIcon, color: Colors.white),
    );
  }

  DismissDirection _parseDirection(String? s) {
    switch (s) {
      case 'leftToRight':
      case 'startToEnd':
        return DismissDirection.startToEnd;
      case 'rightToLeft':
      case 'endToStart':
        return DismissDirection.endToStart;
      case 'up':
        return DismissDirection.up;
      case 'down':
        return DismissDirection.down;
      case 'vertical':
        return DismissDirection.vertical;
      case 'horizontal':
      default:
        return DismissDirection.horizontal;
    }
  }
}
