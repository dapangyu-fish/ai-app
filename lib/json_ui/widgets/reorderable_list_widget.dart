// ReorderableList 控件 — 拖拽排序列表
//
// 与 list 的区别：长按 item 可以拖拽移动顺序。拖完后框架自动把新顺序写回
// `bind` 指向的变量（必须是 global.xxx 路径），同时调用可选的 onReorder 回调。
//
// 字段：
//   - source       : "{{ global.xxx }}" 或字面 List
//   - bind         : "global.xxx"（必填——拖拽完成后写回新顺序）
//   - item_template: 列表项模板（同 list）
//   - onReorder    : 可选 action，会传递 params.from / params.to / params.list
//   - emptyText    : 空状态文案
//   - padding      : 列表内边距
//   - itemKey      : 取每项的稳定 key 字段，默认 'id'。没有就用 index 兜底
//
// 注意：framework 渲染时给每个 item 套 Key（ReorderableListView 的硬性要求）
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonReorderableListWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final sourceRaw = json['source'];
    List<dynamic> items = [];
    if (sourceRaw is String) {
      final resolved = interpreter.resolveExpression(sourceRaw);
      if (resolved is List) items = resolved;
    } else if (sourceRaw is List) {
      items = sourceRaw;
    }

    final itemTemplate = json['item_template'] as Map<String, dynamic>?;
    final bindPath = json['bind']?.toString();
    final emptyText = json['emptyText']?.toString() ?? '暂无数据';
    final padding = (json['padding'] as num?)?.toDouble() ?? 0;
    final itemKeyField = json['itemKey']?.toString() ?? 'id';

    final onReorder =
        resolveActionAtBuildTime(json['onReorder'], interpreter)
            as Map<String, dynamic>?;

    if (itemTemplate == null || items.isEmpty) {
      return Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.drag_handle,
                    size: 40,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.5)),
                const SizedBox(height: 8),
                Text(
                  items.isEmpty ? emptyText : '缺少 item_template',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    void handleReorder(int oldIndex, int newIndex) {
      // ReorderableListView 的回调里 newIndex 在向后移动时多了 1，做一次校正
      if (newIndex > oldIndex) newIndex -= 1;

      final newList = List<dynamic>.from(items);
      final moved = newList.removeAt(oldIndex);
      newList.insert(newIndex, moved);

      // 1. 写回 bind 变量（同步状态）
      if (bindPath != null && bindPath.isNotEmpty) {
        interpreter.setVariable(bindPath, newList);
      }

      // 2. 触发回调（传递 from / to / list）
      if (onReorder != null) {
        // 复制一份 action，把动态参数塞进 args
        final actionCopy = Map<String, dynamic>.from(onReorder);
        final argsCopy = Map<String, dynamic>.from(
            (actionCopy['args'] as Map<String, dynamic>?) ?? {});
        argsCopy['from'] = oldIndex;
        argsCopy['to'] = newIndex;
        argsCopy['list'] = newList;
        actionCopy['args'] = argsCopy;
        // ignore: discarded_futures
        interpreter.executeAction(actionCopy, context);
      }
    }

    return Expanded(
      child: ReorderableListView.builder(
        padding: EdgeInsets.all(padding),
        itemCount: items.length,
        itemBuilder: (ctx, index) {
          final item = items[index];
          // 选 key：优先 item.id（或 itemKey 字段），fallback 到 index
          final keyValue = (item is Map && item[itemKeyField] != null)
              ? item[itemKeyField].toString()
              : 'idx_$index';
          return Padding(
            key: ValueKey(keyValue),
            padding: EdgeInsets.zero,
            child: interpreter.buildWidgetInLoopContext(
              context: ctx,
              json: itemTemplate,
              loopItem: item,
              loopIndex: index,
            ),
          );
        },
        onReorder: handleReorder,
      ),
    );
  }
}
