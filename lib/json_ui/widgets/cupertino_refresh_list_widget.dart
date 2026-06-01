// Cupertino Sliver Refresh 列表
// 支持: source, item_template, onRefresh, onLoadMore, initialOverscroll,
//       customIndicator, pageSize
import 'dart:math' as math;
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonCupertinoRefreshListWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final sourceRaw = json['source'];
    var items = <dynamic>[];
    if (sourceRaw is String) {
      final resolved = interpreter.resolveExpression(sourceRaw);
      if (resolved is List) items = resolved;
    } else if (sourceRaw is List) {
      items = sourceRaw;
    }

    return _CupertinoRefreshListView(
      items: items,
      itemTemplate: json['item_template'] as Map<String, dynamic>?,
      onRefreshAction: json['onRefresh'] as Map<String, dynamic>?,
      onLoadMoreAction: json['onLoadMore'] as Map<String, dynamic>?,
      interpreter: interpreter,
      initialOverscroll: (json['initialOverscroll'] as num?)?.toDouble() ?? 0,
      initialDelayMs: (json['initialDelayMs'] as num?)?.toInt() ?? 500,
      initialDurationMs: (json['initialDurationMs'] as num?)?.toInt() ?? 600,
      customIndicator: json['customIndicator'] == true,
      pageSize: (json['pageSize'] as num?)?.toInt() ?? 30,
    );
  }
}

class _CupertinoRefreshListView extends StatefulWidget {
  final List<dynamic> items;
  final Map<String, dynamic>? itemTemplate;
  final Map<String, dynamic>? onRefreshAction;
  final Map<String, dynamic>? onLoadMoreAction;
  final JsonInterpreter interpreter;
  final double initialOverscroll;
  final int initialDelayMs;
  final int initialDurationMs;
  final bool customIndicator;
  final int pageSize;

  const _CupertinoRefreshListView({
    required this.items,
    required this.itemTemplate,
    required this.onRefreshAction,
    required this.onLoadMoreAction,
    required this.interpreter,
    required this.initialOverscroll,
    required this.initialDelayMs,
    required this.initialDurationMs,
    required this.customIndicator,
    required this.pageSize,
  });

  @override
  State<_CupertinoRefreshListView> createState() =>
      _CupertinoRefreshListViewState();
}

class _CupertinoRefreshListViewState extends State<_CupertinoRefreshListView> {
  final ScrollController _controller = ScrollController();
  bool _didInitialOverscroll = false;
  bool _loadingMore = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleInitialOverscroll();
  }

  void _scheduleInitialOverscroll() {
    if (_didInitialOverscroll) return;
    _didInitialOverscroll = true;
    if (widget.initialOverscroll == 0) return;
    Future.delayed(Duration(milliseconds: widget.initialDelayMs), () {
      if (!mounted || !_controller.hasClients) return;
      _controller.animateTo(
        widget.initialOverscroll,
        duration: Duration(milliseconds: widget.initialDurationMs),
        curve: Curves.linear,
      );
    });
  }

  Future<void> _refresh() async {
    final action = widget.onRefreshAction;
    if (action != null) {
      await widget.interpreter.executeAction(action, context);
    }
  }

  void _maybeLoadMore(ScrollNotification notification) {
    if (widget.onLoadMoreAction == null || _loadingMore) return;
    if (notification is! ScrollEndNotification) return;
    final metrics = notification.metrics;
    if (metrics.pixels <= 0 || metrics.pixels != metrics.maxScrollExtent) {
      return;
    }
    _loadingMore = true;
    widget.interpreter
        .executeAction(widget.onLoadMoreAction!, context)
        .whenComplete(() {
          if (mounted) _loadingMore = false;
        });
  }

  @override
  Widget build(BuildContext context) {
    final itemCount = widget.items.length >= widget.pageSize
        ? widget.items.length + 1
        : widget.items.length;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        _maybeLoadMore(notification);
        return false;
      },
      child: CustomScrollView(
        controller: _controller,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          cupertino.CupertinoSliverRefreshControl(
            refreshIndicatorExtent: 100,
            refreshTriggerPullDistance: 140,
            onRefresh: _refresh,
            builder: widget.customIndicator
                ? _buildSimpleRefreshIndicator
                : cupertino.CupertinoSliverRefreshControl.buildRefreshIndicator,
          ),
          SliverSafeArea(
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index == widget.items.length) {
                  return Container(
                    margin: const EdgeInsets.all(10),
                    child: const Align(child: CircularProgressIndicator()),
                  );
                }
                if (widget.itemTemplate == null) {
                  return const SizedBox.shrink();
                }
                return widget.interpreter.buildWidgetInLoopContext(
                  context: context,
                  json: widget.itemTemplate!,
                  loopItem: widget.items[index],
                  loopIndex: index,
                );
              }, childCount: itemCount),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

Widget _buildSimpleRefreshIndicator(
  BuildContext context,
  cupertino.RefreshIndicatorMode refreshState,
  double pulledExtent,
  double refreshTriggerPullDistance,
  double refreshIndicatorExtent,
) {
  const opacityCurve = Interval(0.4, 0.8, curve: Curves.easeInOut);
  final refreshing = refreshState == cupertino.RefreshIndicatorMode.refresh;
  final denominator = refreshing
      ? refreshIndicatorExtent
      : refreshTriggerPullDistance;
  final opacity = opacityCurve.transform(
    math.min(pulledExtent / denominator, 1),
  );
  return Align(
    alignment: Alignment.bottomCenter,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Opacity(
        opacity: opacity,
        child: refreshing
            ? const cupertino.CupertinoActivityIndicator(radius: 14)
            : const Icon(
                cupertino.CupertinoIcons.down_arrow,
                color: cupertino.CupertinoColors.inactiveGray,
                size: 36,
              ),
      ),
    ),
  );
}
