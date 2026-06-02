import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

class JsonPageViewWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = (json['children'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return _JsonPageView(
      children: children,
      controllerId: json['controller']?.toString(),
      transformer: json['transformer']?.toString() ?? 'none',
      scrollDirection: _parseAxis(json['scrollDirection']?.toString()),
      pageSnapping: json['pageSnapping'] != false,
      physics: _parsePhysics(json['physics']?.toString()),
      viewportFraction:
          _resolveDouble(interpreter, json['viewportFraction']) ?? 1.0,
      interpreter: interpreter,
    );
  }
}

class _JsonPageView extends StatefulWidget {
  final List<Map<String, dynamic>> children;
  final String? controllerId;
  final String transformer;
  final Axis scrollDirection;
  final bool pageSnapping;
  final ScrollPhysics? physics;
  final double viewportFraction;
  final JsonInterpreter interpreter;

  const _JsonPageView({
    required this.children,
    required this.controllerId,
    required this.transformer,
    required this.scrollDirection,
    required this.pageSnapping,
    required this.physics,
    required this.viewportFraction,
    required this.interpreter,
  });

  @override
  State<_JsonPageView> createState() => _JsonPageViewState();
}

class _JsonPageViewState extends State<_JsonPageView> {
  late PageController _controller = PageController(
    viewportFraction: widget.viewportFraction,
  );

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(covariant _JsonPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controllerId != widget.controllerId) {
      _unregister(oldWidget.controllerId);
      _register();
    }
    if (oldWidget.viewportFraction != widget.viewportFraction) {
      _unregister(widget.controllerId);
      _controller.dispose();
      _controller = PageController(viewportFraction: widget.viewportFraction);
      _register();
    }
  }

  @override
  void dispose() {
    _unregister(widget.controllerId);
    _controller.dispose();
    super.dispose();
  }

  void _register() {
    final id = widget.controllerId;
    if (id != null && id.isNotEmpty) {
      widget.interpreter.registerScrollController(id, _controller);
    }
  }

  void _unregister(String? id) {
    if (id != null && id.isNotEmpty) {
      widget.interpreter.unregisterScrollController(id, _controller);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      scrollDirection: widget.scrollDirection,
      pageSnapping: widget.pageSnapping,
      physics: widget.physics,
      itemCount: widget.children.length,
      itemBuilder: (context, index) {
        return AnimatedBuilder(
          animation: _controller,
          child: widget.interpreter.buildWidget(
            context,
            widget.children[index],
          ),
          builder: (context, child) {
            final page = _controller.hasClients && _controller.page != null
                ? _controller.page!
                : _controller.initialPage.toDouble();
            final delta = index - page;
            var transform = Matrix4.identity();
            var opacity = 1.0;
            switch (widget.transformer) {
              case 'accordion':
                transform = Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateY(delta * math.pi / 2);
                break;
              case 'threeD':
              case '3d':
                transform = Matrix4.identity()
                  ..setEntry(3, 2, 0.002)
                  ..rotateY(delta * 0.7);
                break;
              case 'depth':
                final scale = (1 - delta.abs() * 0.25).clamp(0.7, 1.0);
                opacity = (1 - delta.abs() * 0.45).clamp(0.35, 1.0);
                transform = Matrix4.identity()
                  ..scaleByDouble(scale, scale, 1, 1);
                break;
            }
            return Opacity(
              opacity: opacity,
              child: Transform(
                transform: transform,
                alignment: delta >= 0
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: child,
              ),
            );
          },
        );
      },
    );
  }
}

class JsonScrollDragHandoffWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final child = childJson is Map<String, dynamic>
        ? interpreter.buildWidget(context, childJson)
        : const SizedBox.shrink();
    return _ScrollDragHandoff(
      axis: _parseAxis(json['axis']?.toString()),
      defaultControllerId: json['defaultController']?.toString() ?? '',
      touchControllerId: json['touchController']?.toString(),
      touchStart: _resolveDouble(interpreter, json['touchStart']) ?? 0,
      touchEnd: _resolveDouble(interpreter, json['touchEnd']),
      touchRequiresDefaultAtMin: json['touchRequiresDefaultAtMin'] == true,
      switches: (json['switches'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((raw) => _HandoffSwitch.fromJson(raw))
          .toList(),
      interpreter: interpreter,
      child: child,
    );
  }
}

class _ScrollDragHandoff extends StatefulWidget {
  final Axis axis;
  final String defaultControllerId;
  final String? touchControllerId;
  final double touchStart;
  final double? touchEnd;
  final bool touchRequiresDefaultAtMin;
  final List<_HandoffSwitch> switches;
  final JsonInterpreter interpreter;
  final Widget child;

  const _ScrollDragHandoff({
    required this.axis,
    required this.defaultControllerId,
    required this.touchControllerId,
    required this.touchStart,
    required this.touchEnd,
    required this.touchRequiresDefaultAtMin,
    required this.switches,
    required this.interpreter,
    required this.child,
  });

  @override
  State<_ScrollDragHandoff> createState() => _ScrollDragHandoffState();
}

class _ScrollDragHandoffState extends State<_ScrollDragHandoff> {
  String? _activeControllerId;
  Drag? _drag;

  @override
  Widget build(BuildContext context) {
    final gestures = <Type, GestureRecognizerFactory>{};
    if (widget.axis == Axis.vertical) {
      gestures[VerticalDragGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
            VerticalDragGestureRecognizer.new,
            (recognizer) {
              recognizer
                ..onStart = _handleStart
                ..onUpdate = _handleUpdate
                ..onEnd = _handleEnd
                ..onCancel = _handleCancel;
            },
          );
    } else {
      gestures[HorizontalDragGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            HorizontalDragGestureRecognizer.new,
            (recognizer) {
              recognizer
                ..onStart = _handleStart
                ..onUpdate = _handleUpdate
                ..onEnd = _handleEnd
                ..onCancel = _handleCancel;
            },
          );
    }
    return RawGestureDetector(
      gestures: gestures,
      behavior: HitTestBehavior.opaque,
      child: widget.child,
    );
  }

  void _handleStart(DragStartDetails details) {
    final controllerId = _selectStartController(details);
    _startDrag(controllerId, details);
  }

  void _handleUpdate(DragUpdateDetails details) {
    final switchRule = _matchingSwitch(details);
    if (switchRule != null) {
      _drag?.cancel();
      _startDrag(
        switchRule.to,
        DragStartDetails(
          sourceTimeStamp: details.sourceTimeStamp,
          globalPosition: details.globalPosition,
          localPosition: details.localPosition,
        ),
      );
    }
    _drag?.update(details);
  }

  void _handleEnd(DragEndDetails details) {
    _drag?.end(details);
    _drag = null;
    _activeControllerId = null;
  }

  void _handleCancel() {
    _drag?.cancel();
    _drag = null;
    _activeControllerId = null;
  }

  String _selectStartController(DragStartDetails details) {
    final touchId = widget.touchControllerId;
    if (touchId != null && touchId.isNotEmpty) {
      final coordinate = widget.axis == Axis.vertical
          ? details.localPosition.dy
          : details.localPosition.dx;
      final end = widget.touchEnd ?? double.infinity;
      final inTouchBand =
          coordinate >= widget.touchStart && coordinate <= end;
      final defaultAtMin =
          !widget.touchRequiresDefaultAtMin ||
          _isAtMin(widget.defaultControllerId);
      if (inTouchBand && defaultAtMin && _hasController(touchId)) {
        return touchId;
      }
    }
    if (_hasController(widget.defaultControllerId)) {
      return widget.defaultControllerId;
    }
    if (touchId != null && _hasController(touchId)) return touchId;
    return widget.defaultControllerId;
  }

  void _startDrag(String controllerId, DragStartDetails details) {
    _activeControllerId = controllerId;
    final controller = widget.interpreter.scrollController(controllerId);
    if (controller == null || !controller.hasClients) {
      _drag = null;
      return;
    }
    _drag = controller.position.drag(details, _disposeDrag);
  }

  _HandoffSwitch? _matchingSwitch(DragUpdateDetails details) {
    final activeId = _activeControllerId;
    if (activeId == null) return null;
    for (final rule in widget.switches) {
      if (rule.from != activeId) continue;
      if (_matchesCondition(rule.when, details)) return rule;
    }
    return null;
  }

  bool _matchesCondition(String when, DragUpdateDetails details) {
    final activeId = _activeControllerId;
    if (activeId == null) return false;
    final controller = widget.interpreter.scrollController(activeId);
    if (controller == null || !controller.hasClients) return false;
    final delta = details.primaryDelta ?? 0;
    final forward = delta < 0;
    final backward = delta > 0;
    final position = controller.position;
    const epsilon = 0.5;
    final atMax = position.pixels >= position.maxScrollExtent - epsilon;
    final atMin = position.pixels <= position.minScrollExtent + epsilon;
    return switch (when) {
      'fromAtMaxAndForward' => atMax && forward,
      'fromAtMinAndBackward' => atMin && backward,
      'fromAtBoundaryAndForward' => (atMax || atMin) && forward,
      'fromAtBoundaryAndBackward' => (atMax || atMin) && backward,
      _ => false,
    };
  }

  bool _hasController(String id) {
    final controller = widget.interpreter.scrollController(id);
    return controller != null && controller.hasClients;
  }

  bool _isAtMin(String id) {
    final controller = widget.interpreter.scrollController(id);
    if (controller == null || !controller.hasClients) return false;
    return controller.position.pixels <= controller.position.minScrollExtent + 0.5;
  }

  void _disposeDrag() {
    _drag = null;
  }
}

class _HandoffSwitch {
  final String from;
  final String to;
  final String when;

  const _HandoffSwitch({
    required this.from,
    required this.to,
    required this.when,
  });

  factory _HandoffSwitch.fromJson(Map<dynamic, dynamic> json) {
    return _HandoffSwitch(
      from: json['from']?.toString() ?? '',
      to: json['to']?.toString() ?? '',
      when: json['when']?.toString() ?? '',
    );
  }
}

Axis _parseAxis(String? value) {
  return value == 'vertical' ? Axis.vertical : Axis.horizontal;
}

class JsonCustomScrollViewWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final controllerId = json['controller']?.toString();
    final onScroll = resolveActionAtBuildTime(json['onScroll'], interpreter);
    final slivers = <Widget>[];
    final rawSlivers = json['slivers'];
    if (rawSlivers is List) {
      for (final raw in rawSlivers.whereType<Map<String, dynamic>>()) {
        final sliver = _buildSliver(context, raw, interpreter);
        if (sliver != null) slivers.add(sliver);
      }
    }
    final centerIndex = _resolveDouble(
      interpreter,
      json['centerIndex'],
    )?.toInt();
    Key? centerKey;
    if (centerIndex != null &&
        centerIndex >= 0 &&
        centerIndex < slivers.length) {
      centerKey = ValueKey('json_custom_scroll_center_$centerIndex');
      slivers[centerIndex] = KeyedSubtree(
        key: centerKey,
        child: slivers[centerIndex],
      );
    }
    return _JsonCustomScrollViewHost(
      controllerId: controllerId == null || controllerId.isEmpty
          ? null
          : controllerId,
      physics: _parsePhysics(json['physics']?.toString()),
      reverse: _resolveBool(interpreter, json['reverse']),
      onScroll: onScroll is Map<String, dynamic> ? onScroll : null,
      interpreter: interpreter,
      slivers: slivers,
      centerKey: centerKey,
    );
  }

  Widget? _buildSliver(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final visible = json['visible'];
    if (visible != null && !interpreter.evaluateBool(visible)) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    switch (json['kind']?.toString() ?? json['type']?.toString()) {
      case 'sliver_box':
        final childJson = json['child'];
        final height = _resolveDouble(interpreter, json['height']);
        Widget child = childJson is Map<String, dynamic>
            ? interpreter.buildWidget(context, childJson)
            : const SizedBox.shrink();
        if (height != null) child = SizedBox(height: height, child: child);
        return SliverToBoxAdapter(child: child);
      case 'sliver_padding':
        final sliverJson = json['sliver'];
        final sliver = sliverJson is Map<String, dynamic>
            ? _buildSliver(context, sliverJson, interpreter)
            : null;
        if (sliver == null) return null;
        return SliverPadding(
          padding:
              _resolveInsets(interpreter, json['padding']) ?? EdgeInsets.zero,
          sliver: sliver,
        );
      case 'sliver_persistent_header':
        final childJson = json['child'];
        final height =
            _resolveDouble(interpreter, json['height']) ??
            _resolveDouble(interpreter, json['maxHeight']) ??
            56;
        final minHeight =
            _resolveDouble(interpreter, json['minHeight']) ?? height;
        return SliverPersistentHeader(
          pinned: _resolveBool(interpreter, json['pinned']),
          floating: _resolveBool(interpreter, json['floating']),
          delegate: _JsonFixedHeaderDelegate(
            minHeight: minHeight,
            maxHeight: height,
            child: childJson is Map<String, dynamic>
                ? interpreter.buildWidget(context, childJson)
                : const SizedBox.shrink(),
          ),
        );
      case 'sliver_list':
        final source = _resolveSource(interpreter, json['source']);
        final count =
            source?.length ??
            (_resolveDouble(interpreter, json['count']) ?? 0).toInt();
        final template = json['itemTemplate'];
        if (template is! Map<String, dynamic>) return null;
        return SliverList.builder(
          itemCount: count,
          itemBuilder: (context, index) {
            return interpreter.buildWidgetInLoopContext(
              context: context,
              json: template,
              loopItem: source == null ? index : source[index],
              loopIndex: index,
            );
          },
        );
      case 'sliver_grid':
        final source = _resolveSource(interpreter, json['source']);
        final count =
            source?.length ??
            (_resolveDouble(interpreter, json['count']) ?? 0).toInt();
        final template = json['itemTemplate'];
        if (template is! Map<String, dynamic>) return null;
        final maxCrossAxisExtent = _resolveDouble(
          interpreter,
          json['maxCrossAxisExtent'],
        );
        return SliverGrid.builder(
          itemCount: count,
          gridDelegate: maxCrossAxisExtent == null
              ? SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount:
                      (_resolveDouble(interpreter, json['crossAxisCount']) ?? 2)
                          .toInt(),
                  mainAxisSpacing:
                      _resolveDouble(interpreter, json['mainAxisSpacing']) ?? 0,
                  crossAxisSpacing:
                      _resolveDouble(interpreter, json['crossAxisSpacing']) ??
                      0,
                  childAspectRatio:
                      _resolveDouble(interpreter, json['childAspectRatio']) ??
                      1,
                )
              : SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: maxCrossAxisExtent,
                  mainAxisSpacing:
                      _resolveDouble(interpreter, json['mainAxisSpacing']) ?? 0,
                  crossAxisSpacing:
                      _resolveDouble(interpreter, json['crossAxisSpacing']) ??
                      0,
                  childAspectRatio:
                      _resolveDouble(interpreter, json['childAspectRatio']) ??
                      1,
                ),
          itemBuilder: (context, index) {
            return interpreter.buildWidgetInLoopContext(
              context: context,
              json: template,
              loopItem: source == null ? index : source[index],
              loopIndex: index,
            );
          },
        );
    }
    return null;
  }
}

class _JsonCustomScrollViewHost extends StatefulWidget {
  final String? controllerId;
  final ScrollPhysics? physics;
  final bool reverse;
  final Map<String, dynamic>? onScroll;
  final JsonInterpreter interpreter;
  final List<Widget> slivers;
  final Key? centerKey;

  const _JsonCustomScrollViewHost({
    required this.controllerId,
    required this.physics,
    required this.reverse,
    required this.onScroll,
    required this.interpreter,
    required this.slivers,
    required this.centerKey,
  });

  @override
  State<_JsonCustomScrollViewHost> createState() =>
      _JsonCustomScrollViewHostState();
}

class _JsonCustomScrollViewHostState extends State<_JsonCustomScrollViewHost> {
  late final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _register();
    if (widget.onScroll != null) _controller.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant _JsonCustomScrollViewHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controllerId != widget.controllerId) {
      _unregister(oldWidget.controllerId);
      _register();
    }
    if (oldWidget.onScroll == null && widget.onScroll != null) {
      _controller.addListener(_handleScroll);
    } else if (oldWidget.onScroll != null && widget.onScroll == null) {
      _controller.removeListener(_handleScroll);
    }
  }

  void _register() {
    final id = widget.controllerId;
    if (id != null) {
      widget.interpreter.registerScrollController(id, _controller);
    }
  }

  void _unregister(String? id) {
    if (id != null) {
      widget.interpreter.unregisterScrollController(id, _controller);
    }
  }

  void _handleScroll() {
    if (!mounted || !_controller.hasClients || widget.onScroll == null) return;
    final position = _controller.position;
    widget.interpreter.executeActionWithEvent(widget.onScroll!, context, {
      'offset': position.pixels,
      'maxScrollExtent': position.maxScrollExtent,
      'isEnd': position.pixels == position.maxScrollExtent,
    });
  }

  @override
  void dispose() {
    if (widget.onScroll != null) _controller.removeListener(_handleScroll);
    _unregister(widget.controllerId);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: _controller,
      physics: widget.physics,
      reverse: widget.reverse,
      center: widget.centerKey,
      slivers: widget.slivers,
    );
  }
}

class _JsonFixedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double minHeight;
  final double maxHeight;
  final Widget child;

  const _JsonFixedHeaderDelegate({
    required this.minHeight,
    required this.maxHeight,
    required this.child,
  });

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => math.max(maxHeight, minHeight);

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(covariant _JsonFixedHeaderDelegate oldDelegate) {
    return oldDelegate.minHeight != minHeight ||
        oldDelegate.maxHeight != maxHeight ||
        oldDelegate.child != child;
  }
}

class JsonRadialLayoutWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final source = _resolveSource(interpreter, json['source']);
    final count =
        source?.length ??
        (_resolveDouble(interpreter, json['count']) ?? 0).toInt();
    final template = json['itemTemplate'];
    if (template is! Map<String, dynamic>) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math
            .min(
              constraints.maxWidth.isFinite ? constraints.maxWidth : 300,
              constraints.maxHeight.isFinite ? constraints.maxHeight : 300,
            )
            .toDouble();
        final radius =
            _resolveDouble(interpreter, json['radius']) ?? size * .28;
        final childSize = _resolveDouble(interpreter, json['childSize']) ?? 56;
        final color = _parseColor(json['backgroundColor']?.toString());
        final startAngle =
            (_resolveDouble(interpreter, json['startAngleDeg']) ?? -90) *
            math.pi /
            180;
        final sweepAngle =
            (_resolveDouble(interpreter, json['sweepAngleDeg']) ?? 360) *
            math.pi /
            180;
        final rotateItems = json['rotateItems'] == true;
        Widget stack = Stack(
          children: List.generate(count, (index) {
            final divisor = sweepAngle.abs() >= math.pi * 2
                ? math.max(1, count)
                : math.max(1, count - 1);
            final angle = startAngle + index * sweepAngle / divisor;
            Widget item = interpreter.buildWidgetInLoopContext(
              context: context,
              json: template,
              loopItem: source == null ? index : source[index],
              loopIndex: index,
            );
            if (rotateItems) {
              item = Transform.rotate(angle: angle + math.pi / 2, child: item);
            }
            return Positioned(
              left: size / 2 + math.cos(angle) * radius - childSize / 2,
              top: size / 2 + math.sin(angle) * radius - childSize / 2,
              width: childSize,
              height: childSize,
              child: item,
            );
          }),
        );
        if (color != null) stack = ColoredBox(color: color, child: stack);
        return SizedBox.square(dimension: size, child: stack);
      },
    );
  }
}

ScrollPhysics? _parsePhysics(String? value) {
  switch (value) {
    case 'always':
      return const AlwaysScrollableScrollPhysics();
    case 'bouncing':
      return const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      );
    case 'clamping':
      return const ClampingScrollPhysics();
    case 'never':
      return const NeverScrollableScrollPhysics();
    default:
      return null;
  }
}

List<dynamic>? _resolveSource(JsonInterpreter interpreter, dynamic sourceRaw) {
  final resolved = interpreter.evaluateExpression(sourceRaw);
  if (resolved is List) return resolved;
  return null;
}

EdgeInsets? _resolveInsets(JsonInterpreter interpreter, dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final v = value.toDouble();
    return v == 0 ? null : EdgeInsets.all(v);
  }
  if (value is Map<String, dynamic>) {
    final all = _resolveDouble(interpreter, value['all']);
    if (all != null) return all == 0 ? null : EdgeInsets.all(all);
    final horizontal = _resolveDouble(interpreter, value['horizontal']) ?? 0;
    final vertical = _resolveDouble(interpreter, value['vertical']) ?? 0;
    final left = _resolveDouble(interpreter, value['left']) ?? horizontal;
    final right = _resolveDouble(interpreter, value['right']) ?? horizontal;
    final top = _resolveDouble(interpreter, value['top']) ?? vertical;
    final bottom = _resolveDouble(interpreter, value['bottom']) ?? vertical;
    if (left == 0 && right == 0 && top == 0 && bottom == 0) return null;
    return EdgeInsets.fromLTRB(left, top, right, bottom);
  }
  return null;
}

bool _resolveBool(JsonInterpreter interpreter, dynamic value) {
  if (value == null) return false;
  final resolved = interpreter.evaluateExpression(value);
  if (resolved is bool) return resolved;
  if (resolved is num) return resolved != 0;
  if (resolved is String) {
    final normalized = resolved.trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}

double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final resolved = interpreter.evaluateExpression(value);
  if (resolved is num) return resolved.toDouble();
  return double.tryParse(resolved?.toString() ?? '');
}

Color? _parseColor(String? colorStr) {
  if (colorStr == null || !colorStr.startsWith('#')) return null;
  final hex = colorStr.replaceFirst('#', '');
  if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
  if (hex.length == 8) return Color(int.parse(hex, radix: 16));
  return null;
}
