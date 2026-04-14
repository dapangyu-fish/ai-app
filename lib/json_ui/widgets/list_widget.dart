// List 控件
// 支持 source（数据源，可为模板表达式）、item_template（列表项模板）、position 定位
// 注意：list 控件自动使用 Expanded 占据父 Column/Row 的剩余空间
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonListWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    // 解析数据源
    final sourceRaw = json['source'];
    List<dynamic> items = [];

    if (sourceRaw is String) {
      // 模板表达式，如 "{{ $.global.favorites }}"
      final resolved = interpreter.resolveExpression(sourceRaw);
      if (resolved is List) {
        items = resolved;
      }
    } else if (sourceRaw is List) {
      items = sourceRaw;
    }

    final itemTemplate = json['item_template'] as Map<String, dynamic>?;

    if (itemTemplate == null || items.isEmpty) {
      return Expanded(
        child: Center(
          child: Text(
            items.isEmpty ? '暂无数据' : '缺少 item_template',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    // 使用 Expanded 让 ListView 占据剩余空间
    // 外层 Column 已经保证了 bounded constraints
    return Expanded(
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, index) {
          return interpreter.buildWidgetInLoopContext(
            context: ctx,
            json: itemTemplate,
            loopItem: items[index],
            loopIndex: index,
          );
        },
      ),
    );
  }
}
