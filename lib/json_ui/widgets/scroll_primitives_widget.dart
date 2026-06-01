import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      transformer: json['transformer']?.toString() ?? 'none',
      interpreter: interpreter,
    );
  }
}

class _JsonPageView extends StatefulWidget {
  final List<Map<String, dynamic>> children;
  final String transformer;
  final JsonInterpreter interpreter;

  const _JsonPageView({
    required this.children,
    required this.transformer,
    required this.interpreter,
  });

  @override
  State<_JsonPageView> createState() => _JsonPageViewState();
}

class _JsonPageViewState extends State<_JsonPageView> {
  late final PageController _controller = PageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
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
    return _JsonCustomScrollViewHost(
      controllerId: controllerId == null || controllerId.isEmpty
          ? null
          : controllerId,
      physics: _parsePhysics(json['physics']?.toString()),
      onScroll: onScroll is Map<String, dynamic> ? onScroll : null,
      interpreter: interpreter,
      slivers: slivers,
    );
  }

  Widget? _buildSliver(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final visible = json['visible'];
    if (visible != null && interpreter.resolveExpression(visible) != true) {
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
  final Map<String, dynamic>? onScroll;
  final JsonInterpreter interpreter;
  final List<Widget> slivers;

  const _JsonCustomScrollViewHost({
    required this.controllerId,
    required this.physics,
    required this.onScroll,
    required this.interpreter,
    required this.slivers,
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

class JsonVerificationCodeInputWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final onChanged = resolveActionAtBuildTime(json['onChanged'], interpreter);
    final onFilled = resolveActionAtBuildTime(json['onFilled'], interpreter);
    return _VerificationCodeInput(
      length: (json['length'] as num?)?.toInt() ?? 6,
      masked: json['masked'] == true,
      connected: json['connected'] == true,
      titleLeft: json['titleLeft']?.toString(),
      titleRight: json['titleRight']?.toString(),
      onChanged: onChanged is Map<String, dynamic> ? onChanged : null,
      onFilled: onFilled is Map<String, dynamic> ? onFilled : null,
      interpreter: interpreter,
    );
  }
}

class _VerificationCodeInput extends StatefulWidget {
  final int length;
  final bool masked;
  final bool connected;
  final String? titleLeft;
  final String? titleRight;
  final Map<String, dynamic>? onChanged;
  final Map<String, dynamic>? onFilled;
  final JsonInterpreter interpreter;

  const _VerificationCodeInput({
    required this.length,
    required this.masked,
    required this.connected,
    required this.titleLeft,
    required this.titleRight,
    required this.onChanged,
    required this.onFilled,
    required this.interpreter,
  });

  @override
  State<_VerificationCodeInput> createState() => _VerificationCodeInputState();
}

class _VerificationCodeInputState extends State<_VerificationCodeInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _focusNode.requestFocus,
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.titleLeft != null || widget.titleRight != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 50),
                  child: Row(
                    children: [
                      Text(
                        widget.titleLeft ?? '',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(widget.titleRight ?? ''),
                    ],
                  ),
                ),
              if (widget.titleLeft != null || widget.titleRight != null)
                const SizedBox(height: 5),
              widget.connected
                  ? _connectedCells(context)
                  : _spacedCells(context),
            ],
          ),
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: Opacity(
              opacity: 0.01,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(widget.length),
                ],
                onChanged: (value) {
                  setState(() {});
                  if (widget.onChanged != null) {
                    widget.interpreter.executeActionWithEvent(
                      widget.onChanged!,
                      context,
                      {'value': value},
                    );
                  }
                  if (value.length >= widget.length) {
                    _focusNode.unfocus();
                    if (widget.onFilled != null) {
                      widget.interpreter.executeActionWithEvent(
                        widget.onFilled!,
                        context,
                        {'value': value},
                      );
                    }
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _spacedCells(BuildContext context) {
    final value = _controller.text;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final cell = ((width - 32) / widget.length - 20).clamp(28.0, 72.0);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(widget.length, (index) {
              return Container(
                width: cell,
                height: cell,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).primaryColor),
                ),
                child: Text(
                  index < value.length ? value[index] : '',
                  style: TextStyle(
                    color: Theme.of(context).primaryColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }

  Widget _connectedCells(BuildContext context) {
    final value = _controller.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 50),
      child: Row(
        children: List.generate(widget.length, (index) {
          return Expanded(
            child: Container(
              height: 45,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF979797), width: 0.5),
                borderRadius: BorderRadius.horizontal(
                  left: index == 0 ? const Radius.circular(4) : Radius.zero,
                  right: index == widget.length - 1
                      ? const Radius.circular(4)
                      : Radius.zero,
                ),
              ),
              child: Text(
                index < value.length
                    ? (widget.masked ? '•' : value[index])
                    : '',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        }),
      ),
    );
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
    default:
      return null;
  }
}

List<dynamic>? _resolveSource(JsonInterpreter interpreter, dynamic sourceRaw) {
  if (sourceRaw is List) return sourceRaw;
  if (sourceRaw is String) {
    final resolved = interpreter.resolveExpression(sourceRaw);
    if (resolved is List) return resolved;
  }
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
  final resolved = interpreter.resolveExpression(value);
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
  final resolved = interpreter.resolveExpression(value);
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
