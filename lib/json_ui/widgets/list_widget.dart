// List 控件 — 增强版
// 支持：source(数据源)、item_template(列表项模板)、
//       onRefresh(下拉刷新)、onLoadMore(上拉加载更多)、
//       emptyText(空状态文案)
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';
import '../../i18n/framework_strings.dart';

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
    final emptyText = interpreter.resolveTemplate(
        json['emptyText']?.toString() ?? T.of(context).empty);
    final onRefresh = json['onRefresh'] as Map<String, dynamic>?;
    final onLoadMore = json['onLoadMore'] as Map<String, dynamic>?;
    // separator: "none" 时不画横线（聊天气泡列表 / 卡片网格用），
    // 默认（不写或 "divider"）保留 1px 分隔线，跟历史行为一致
    final separator = json['separator']?.toString() ?? 'divider';
    // scrollToEnd: true 时进入页面 / 列表项数增加时自动滚到底（聊天页用）
    final scrollToEnd = json['scrollToEnd'] == true;
    // 跨屏导航时保留滚动位置：JSON 里给 list 设 "key": "唯一名"，
    // 框架包成 PageStorageKey，Flutter 的 PageStorage 自动存/取 scroll offset
    final keyStr = json['key']?.toString();
    final pageKey = keyStr != null && keyStr.isNotEmpty
        ? PageStorageKey<String>(keyStr)
        : null;

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
                items.isEmpty ? emptyText : T.of(context).widgetMissingItemTemplate,
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
                        Text(T.of(context).widgetPullToRefresh,
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
    Widget itemBuilder(BuildContext ctx, int index) {
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
    }

    final totalCount = items.length + (onLoadMore != null ? 1 : 0);
    Widget listView = _AutoScrollListView(
      pageKey: pageKey,
      itemCount: totalCount,
      separator: separator,
      itemBuilder: itemBuilder,
      scrollToEnd: scrollToEnd,
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

/// ListView 的轻量包装：scrollToEnd=true 时第一帧 + 每次 items 变多都跳到底，
/// 用于聊天页打开后直接停在最新消息（不写 reverse 让数据保持升序原样）。
class _AutoScrollListView extends StatefulWidget {
  final Key? pageKey;
  final int itemCount;
  final String separator;
  final Widget Function(BuildContext, int) itemBuilder;
  final bool scrollToEnd;

  const _AutoScrollListView({
    this.pageKey,
    required this.itemCount,
    required this.separator,
    required this.itemBuilder,
    required this.scrollToEnd,
  });

  @override
  State<_AutoScrollListView> createState() => _AutoScrollListViewState();
}

class _AutoScrollListViewState extends State<_AutoScrollListView> {
  late final ScrollController _controller;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    if (widget.scrollToEnd) {
      _scheduleJumpToEnd();
    }
    _lastCount = widget.itemCount;
  }

  @override
  void didUpdateWidget(covariant _AutoScrollListView old) {
    super.didUpdateWidget(old);
    if (widget.scrollToEnd && widget.itemCount > _lastCount) {
      _scheduleJumpToEnd();
    }
    _lastCount = widget.itemCount;
  }

  void _scheduleJumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.separator == 'none') {
      return ListView.builder(
        key: widget.pageKey,
        controller: _controller,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      );
    }
    return ListView.separated(
      key: widget.pageKey,
      controller: _controller,
      itemCount: widget.itemCount,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: widget.itemBuilder,
    );
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
