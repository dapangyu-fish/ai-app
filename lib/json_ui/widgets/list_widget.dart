// List 控件 — 增强版
// 支持：source(数据源)、item_template(列表项模板)、
//       onRefresh(下拉刷新)、onLoadMore(上拉加载更多)、
//       emptyText(空状态文案)
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
      final resolved = interpreter.resolveExpression(sourceRaw);
      if (resolved is List) {
        items = resolved;
      }
    } else if (sourceRaw is List) {
      items = sourceRaw;
    }

    final itemTemplate = json['item_template'] as Map<String, dynamic>?;
    final emptyText = json['emptyText']?.toString() ?? '暂无数据';
    final onRefresh = json['onRefresh'] as Map<String, dynamic>?;
    final onLoadMore = json['onLoadMore'] as Map<String, dynamic>?;

    // 空状态
    if (itemTemplate == null || items.isEmpty) {
      Widget emptyWidget = Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(
                items.isEmpty ? emptyText : '缺少 item_template',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );

      // 空状态也支持下拉刷新
      if (onRefresh != null) {
        return Expanded(
          child: RefreshIndicator(
            onRefresh: () => interpreter.executeAction(onRefresh, context),
            child: ListView(
              children: [
                SizedBox(
                  height: 300,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inbox_outlined,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        Text(emptyText,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 14,
                            )),
                        const SizedBox(height: 8),
                        Text('下拉刷新',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                              fontSize: 12,
                            )),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      return emptyWidget;
    }

    // 构建列表
    Widget listView = ListView.separated(
      itemCount: items.length + (onLoadMore != null ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, index) {
        // 最后一项：加载更多
        if (index == items.length && onLoadMore != null) {
          return _LoadMoreTrigger(
            onTrigger: () => interpreter.executeAction(onLoadMore, ctx),
          );
        }

        final itemWidget = interpreter.buildWidgetInLoopContext(
          context: ctx,
          json: itemTemplate,
          loopItem: items[index],
          loopIndex: index,
        );
        return IntrinsicHeight(child: itemWidget);
      },
    );

    // 下拉刷新包裹
    if (onRefresh != null) {
      listView = RefreshIndicator(
        onRefresh: () => interpreter.executeAction(onRefresh, context),
        child: listView,
      );
    }

    return Expanded(child: listView);
  }
}

class _LoadMoreTrigger extends StatefulWidget {
  final Future<void> Function() onTrigger;
  const _LoadMoreTrigger({required this.onTrigger});

  @override
  State<_LoadMoreTrigger> createState() => _LoadMoreTriggerState();
}

class _LoadMoreTriggerState extends State<_LoadMoreTrigger> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onTrigger();
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
