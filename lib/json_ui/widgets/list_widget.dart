// List 控件 — 增强版
// 支持：source(数据源)、item_template(列表项模板)、
//       onRefresh(下拉刷新)、onLoadMore(上拉加载更多)、
//       emptyText(空状态文案)、shrinkWrap(嵌入外层滚动页)
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
      json['emptyText']?.toString() ?? T.of(context).empty,
    );
    final onRefresh = json['onRefresh'] as Map<String, dynamic>?;
    final onLoadMore = json['onLoadMore'] as Map<String, dynamic>?;
    final onScroll = json['onScroll'] as Map<String, dynamic>?;
    final onScrollNotification =
        json['onScrollNotification'] as Map<String, dynamic>?;
    final controllerId = json['controller']?.toString();
    // separator: "none" 时不画横线（聊天气泡列表 / 卡片网格用），
    // 默认（不写或 "divider"）保留 1px 分隔线，跟历史行为一致
    final separator = json['separator']?.toString() ?? 'divider';
    // scrollToEnd: true 时进入页面 / 列表项数增加时自动滚到底（聊天页用）
    final scrollToEnd = json['scrollToEnd'] == true;
    // initialRefresh: true 时首帧后主动展示 RefreshIndicator，并触发 onRefresh。
    // 用于复刻 Flutter demo 里 refreshKey.currentState!.show() 的行为。
    final initialRefresh = json['initialRefresh'] == true;
    final emptyState = json['emptyState']?.toString() ?? 'default';
    // shrinkWrap: true 时 list 不再占满剩余高度，适合放在可滚动详情页 /
    // 仪表盘页里。长列表、聊天页仍应保持默认 Expanded(ListView)。
    final shrinkWrap = json['shrinkWrap'] == true;
    // 跨屏导航时保留滚动位置：JSON 里给 list 设 "key": "唯一名"，
    // 框架包成 PageStorageKey，Flutter 的 PageStorage 自动存/取 scroll offset
    final keyStr = json['key']?.toString();
    final pageKey = keyStr != null && keyStr.isNotEmpty
        ? PageStorageKey<String>(keyStr)
        : null;

    // 空状态
    if (itemTemplate == null || items.isEmpty) {
      if (itemTemplate != null && items.isEmpty && emptyState == 'none') {
        final emptyList = ListView(
          shrinkWrap: shrinkWrap,
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [SizedBox(height: 1)],
        );

        if (onRefresh != null) {
          final refreshWidget = _RefreshIndicatorWithInitial(
            initialRefresh: initialRefresh,
            onRefresh: () => interpreter.executeAction(onRefresh, context),
            child: emptyList,
          );
          return shrinkWrap ? refreshWidget : Expanded(child: refreshWidget);
        }

        return shrinkWrap ? emptyList : Expanded(child: emptyList);
      }

      final emptyContent = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 48,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              items.isEmpty
                  ? emptyText
                  : T.of(context).widgetMissingItemTemplate,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
      Widget emptyWidget = shrinkWrap
          ? SizedBox(height: 160, child: emptyContent)
          : Expanded(child: emptyContent);

      // 空状态也支持下拉刷新
      if (onRefresh != null) {
        final refreshChild = ListView(
          shrinkWrap: shrinkWrap,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: shrinkWrap ? 160 : 300,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 48,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      emptyText,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      T.of(context).widgetPullToRefresh,
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
        final refreshWidget = _RefreshIndicatorWithInitial(
          initialRefresh: initialRefresh,
          onRefresh: () => interpreter.executeAction(onRefresh, context),
          child: refreshChild,
        );
        return shrinkWrap ? refreshWidget : Expanded(child: refreshWidget);
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
      final wrapped = IntrinsicHeight(child: itemWidget);
      if (controllerId != null && controllerId.isNotEmpty) {
        return KeyedSubtree(
          key: interpreter.scrollTargetKey(controllerId, index),
          child: wrapped,
        );
      }
      return wrapped;
    }

    final totalCount = items.length + (onLoadMore != null ? 1 : 0);
    Widget listView = _AutoScrollListView(
      pageKey: pageKey,
      itemCount: totalCount,
      separator: separator,
      itemBuilder: itemBuilder,
      scrollToEnd: scrollToEnd,
      shrinkWrap: shrinkWrap,
      controllerId: controllerId,
      interpreter: interpreter,
      onScroll: onScroll,
      onScrollNotification: onScrollNotification,
    );

    // 下拉刷新包裹
    if (onRefresh != null) {
      listView = _RefreshIndicatorWithInitial(
        initialRefresh: initialRefresh,
        onRefresh: () => interpreter.executeAction(onRefresh, context),
        child: listView,
      );
    }

    return shrinkWrap ? listView : Expanded(child: listView);
  }
}

class _RefreshIndicatorWithInitial extends StatefulWidget {
  final bool initialRefresh;
  final RefreshCallback onRefresh;
  final Widget child;

  const _RefreshIndicatorWithInitial({
    required this.initialRefresh,
    required this.onRefresh,
    required this.child,
  });

  @override
  State<_RefreshIndicatorWithInitial> createState() =>
      _RefreshIndicatorWithInitialState();
}

class _RefreshIndicatorWithInitialState
    extends State<_RefreshIndicatorWithInitial> {
  final _key = GlobalKey<RefreshIndicatorState>();
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _scheduleInitialRefresh();
  }

  @override
  void didUpdateWidget(covariant _RefreshIndicatorWithInitial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.initialRefresh && widget.initialRefresh) {
      _scheduleInitialRefresh();
    }
  }

  void _scheduleInitialRefresh() {
    if (!widget.initialRefresh || _shown) return;
    _shown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _key.currentState?.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      key: _key,
      onRefresh: widget.onRefresh,
      child: widget.child,
    );
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
  final bool shrinkWrap;
  final String? controllerId;
  final JsonInterpreter interpreter;
  final Map<String, dynamic>? onScroll;
  final Map<String, dynamic>? onScrollNotification;

  const _AutoScrollListView({
    this.pageKey,
    required this.itemCount,
    required this.separator,
    required this.itemBuilder,
    required this.scrollToEnd,
    required this.shrinkWrap,
    required this.controllerId,
    required this.interpreter,
    required this.onScroll,
    required this.onScrollNotification,
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
    if (widget.controllerId != null && widget.controllerId!.isNotEmpty) {
      widget.interpreter.registerScrollController(
        widget.controllerId!,
        _controller,
      );
    }
    if (widget.onScroll != null) {
      _controller.addListener(_handleScroll);
    }
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

  void _handleScroll() {
    if (!mounted || !_controller.hasClients || widget.onScroll == null) {
      return;
    }
    final position = _controller.position;
    widget.interpreter.executeActionWithEvent(widget.onScroll!, context, {
      'offset': position.pixels,
      'maxScrollExtent': position.maxScrollExtent,
      'isEnd': position.pixels == position.maxScrollExtent,
    });
  }

  bool _handleNotification(ScrollNotification notification) {
    if (widget.onScrollNotification == null) return false;
    final type = switch (notification) {
      ScrollStartNotification() => 'ScrollStart',
      ScrollUpdateNotification() => 'ScrollUpdate',
      ScrollEndNotification() => 'ScrollEnd',
      UserScrollNotification() => ' UserScroll',
      _ => '',
    };
    widget.interpreter.executeActionWithEvent(
      widget.onScrollNotification!,
      context,
      {
        'type': type,
        'offset': notification.metrics.pixels,
        'maxScrollExtent': notification.metrics.maxScrollExtent,
        'isEnd':
            notification.metrics.pixels == notification.metrics.maxScrollExtent,
      },
    );
    return false;
  }

  @override
  void dispose() {
    if (widget.controllerId != null && widget.controllerId!.isNotEmpty) {
      widget.interpreter.unregisterScrollController(
        widget.controllerId!,
        _controller,
      );
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget list;
    if (widget.separator == 'none') {
      list = ListView.builder(
        key: widget.pageKey,
        controller: _controller,
        shrinkWrap: widget.shrinkWrap,
        physics: widget.shrinkWrap
            ? const NeverScrollableScrollPhysics()
            : null,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      );
    } else {
      list = ListView.separated(
        key: widget.pageKey,
        controller: _controller,
        shrinkWrap: widget.shrinkWrap,
        physics: widget.shrinkWrap
            ? const NeverScrollableScrollPhysics()
            : null,
        itemCount: widget.itemCount,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: widget.itemBuilder,
      );
    }
    if (widget.onScrollNotification != null) {
      list = NotificationListener<ScrollNotification>(
        onNotification: _handleNotification,
        child: list,
      );
    }
    return list;
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
