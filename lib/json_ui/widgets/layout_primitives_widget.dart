import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

class JsonMeasuredBoxWidget extends JsonBaseWidget {
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
    final bind = json['bind']?.toString();
    final onMeasure = resolveActionAtBuildTime(json['onMeasure'], interpreter);
    return _JsonMeasuredBoxHost(
      bind: bind == null || bind.isEmpty ? null : bind,
      onMeasure: onMeasure is Map<String, dynamic> ? onMeasure : null,
      includeSafeArea: json['includeSafeArea'] != false,
      includeToolbar: json['includeToolbar'] == true,
      interpreter: interpreter,
      child: child,
    );
  }
}

class _JsonMeasuredBoxHost extends StatefulWidget {
  final String? bind;
  final Map<String, dynamic>? onMeasure;
  final bool includeSafeArea;
  final bool includeToolbar;
  final JsonInterpreter interpreter;
  final Widget child;

  const _JsonMeasuredBoxHost({
    required this.bind,
    required this.onMeasure,
    required this.includeSafeArea,
    required this.includeToolbar,
    required this.interpreter,
    required this.child,
  });

  @override
  State<_JsonMeasuredBoxHost> createState() => _JsonMeasuredBoxHostState();
}

class _JsonMeasuredBoxHostState extends State<_JsonMeasuredBoxHost> {
  final GlobalKey _key = GlobalKey();
  String? _lastSignature;
  bool _measureScheduled = false;

  @override
  void didUpdateWidget(covariant _JsonMeasuredBoxHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return KeyedSubtree(key: _key, child: widget.child);
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      _publishMeasure();
    });
  }

  void _publishMeasure() {
    final renderObject = _key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;

    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final media = MediaQuery.maybeOf(context);
    final view = View.of(context);
    final viewport = media?.size ?? view.physicalSize / view.devicePixelRatio;
    final padding = media?.padding ?? EdgeInsets.zero;
    final data = <String, dynamic>{
      'x': _round(topLeft.dx),
      'y': _round(topLeft.dy),
      'left': _round(topLeft.dx),
      'top': _round(topLeft.dy),
      'width': _round(size.width),
      'height': _round(size.height),
      'right': _round(topLeft.dx + size.width),
      'bottom': _round(topLeft.dy + size.height),
      'viewportWidth': _round(viewport.width),
      'viewportHeight': _round(viewport.height),
      'safeTop': widget.includeSafeArea ? _round(padding.top) : 0,
      'safeBottom': widget.includeSafeArea ? _round(padding.bottom) : 0,
      'safeLeft': widget.includeSafeArea ? _round(padding.left) : 0,
      'safeRight': widget.includeSafeArea ? _round(padding.right) : 0,
      'toolbarHeight': widget.includeToolbar ? kToolbarHeight : 0,
    };
    final signature = data.toString();
    if (signature == _lastSignature) return;
    _lastSignature = signature;

    final bind = widget.bind;
    if (bind != null) {
      widget.interpreter.setVariable(bind, data);
    }
    final onMeasure = widget.onMeasure;
    if (onMeasure != null && mounted) {
      widget.interpreter
          .executeActionWithEvent(onMeasure, context, data)
          .catchError((e, st) {
            debugPrint('[measured_box] onMeasure error: $e');
          });
    }
  }

  double _round(double value) => double.parse(value.toStringAsFixed(3));
}

class JsonSpiralFlowWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = (json['children'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((child) => interpreter.buildWidget(context, child))
        .toList();
    final ratio = _resolveDouble(interpreter, json['ratio']) ?? 1;
    final padding = _resolveInsets(json['padding']) ?? EdgeInsets.zero;
    final color = _parseColor(json['color']?.toString());
    final fitToSquare = json['fitToSquare'] != false;
    final width = _resolveDouble(interpreter, json['width']);
    final height = _resolveDouble(interpreter, json['height']);
    final clipBehavior = switch (json['clipBehavior']?.toString()) {
      'hardEdge' => Clip.hardEdge,
      'antiAlias' => Clip.antiAlias,
      'antiAliasWithSaveLayer' => Clip.antiAliasWithSaveLayer,
      _ => Clip.none,
    };

    Widget content = Container(
      padding: padding,
      color: color,
      child: _SpiralFlowLayout(
        ratio: ratio,
        clipBehavior: clipBehavior,
        children: children,
      ),
    );

    if (fitToSquare) {
      final flowContent = content;
      content = LayoutBuilder(
        builder: (context, constraints) {
          final fallback = MediaQuery.sizeOf(context).width;
          final side = math.min(
            width ?? constraints.maxWidth,
            height ?? constraints.maxHeight,
          );
          final resolvedSide = side.isFinite && side > 0 ? side : fallback;
          return SizedBox(
            width: width ?? resolvedSide,
            height: height ?? resolvedSide,
            child: FittedBox(child: flowContent),
          );
        },
      );
    } else if (width != null || height != null) {
      content = SizedBox(width: width, height: height, child: content);
    }

    return content;
  }
}

class _SpiralFlowLayout extends MultiChildRenderObjectWidget {
  final double ratio;
  final Clip clipBehavior;

  const _SpiralFlowLayout({
    required this.ratio,
    required this.clipBehavior,
    required super.children,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSpiralFlowLayout(ratio: ratio, clipBehavior: clipBehavior);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSpiralFlowLayout renderObject,
  ) {
    renderObject
      ..ratio = ratio
      ..clipBehavior = clipBehavior;
  }
}

class _RenderSpiralFlowLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SpiralFlowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SpiralFlowParentData> {
  static const double _tau = math.pi * 2;
  double _ratio;
  Clip _clipBehavior;
  bool _needsClip = false;

  _RenderSpiralFlowLayout({required double ratio, required Clip clipBehavior})
    : _ratio = ratio,
      _clipBehavior = clipBehavior;

  double get ratio => _ratio;
  set ratio(double value) {
    if (_ratio == value) return;
    _ratio = value;
    markNeedsLayout();
  }

  Clip get clipBehavior => _clipBehavior;
  set clipBehavior(Clip value) {
    if (_clipBehavior == value) return;
    _clipBehavior = value;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SpiralFlowParentData) {
      child.parentData = _SpiralFlowParentData();
    }
  }

  @override
  void performLayout() {
    _needsClip = false;
    if (childCount == 0) {
      size = constraints.smallest;
      return;
    }

    var recordRect = Rect.zero;
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData as _SpiralFlowParentData;
      child.layout(const BoxConstraints(), parentUsesSize: true);
      parentData
        ..width = child.size.width
        ..height = child.size.height;

      var attempt = -1;
      do {
        final rx = ratio >= 1 ? ratio : 1.0;
        final ry = ratio <= 1 ? ratio : 1.0;
        final angle = attempt * 0.02 * _tau;
        final radius = 5 + 5 * angle;
        final position = Offset(
          rx * radius * math.cos(angle),
          ry * radius * math.sin(angle),
        );
        parentData.offset = position - Alignment.center.alongSize(child.size);
        attempt += 1;
      } while (_overlaps(parentData));

      recordRect = recordRect.expandToInclude(parentData.content);
      child = parentData.nextSibling;
    }

    size = constraints
        .tighten(width: recordRect.width, height: recordRect.height)
        .smallest;

    final delta = size.center(Offset.zero) - recordRect.center;
    child = firstChild;
    while (child != null) {
      final parentData = child.parentData as _SpiralFlowParentData;
      parentData.offset += delta;
      child = parentData.nextSibling;
    }

    _needsClip =
        size.width < recordRect.width || size.height < recordRect.height;
  }

  bool _overlaps(_SpiralFlowParentData data) {
    var child = data.previousSibling;
    while (child != null) {
      final childData = child.parentData as _SpiralFlowParentData;
      if (data.content.overlaps(childData.content)) return true;
      child = childData.previousSibling;
    }
    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_needsClip || clipBehavior == Clip.none) {
      defaultPaint(context, offset);
      return;
    }
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      defaultPaint,
      clipBehavior: clipBehavior,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    return defaultComputeDistanceToHighestActualBaseline(baseline);
  }
}

class _SpiralFlowParentData extends ContainerBoxParentData<RenderBox> {
  late double width;
  late double height;

  Rect get content => Rect.fromLTWH(offset.dx, offset.dy, width, height);
}

double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final resolved = interpreter.evaluateExpression(value);
  if (resolved is num) return resolved.toDouble();
  return double.tryParse(resolved?.toString() ?? '');
}

EdgeInsets? _resolveInsets(dynamic value) {
  if (value == null) return null;
  if (value is num) return EdgeInsets.all(value.toDouble());
  if (value is Map<String, dynamic>) {
    final horizontal = (value['horizontal'] as num?)?.toDouble();
    final vertical = (value['vertical'] as num?)?.toDouble();
    return EdgeInsets.only(
      left: (value['left'] as num?)?.toDouble() ?? horizontal ?? 0,
      right: (value['right'] as num?)?.toDouble() ?? horizontal ?? 0,
      top: (value['top'] as num?)?.toDouble() ?? vertical ?? 0,
      bottom: (value['bottom'] as num?)?.toDouble() ?? vertical ?? 0,
    );
  }
  return null;
}

Color? _parseColor(String? colorStr) {
  if (colorStr == null || !colorStr.startsWith('#')) return null;
  final hex = colorStr.replaceFirst('#', '');
  if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
  if (hex.length == 8) return Color(int.parse(hex, radix: 16));
  return null;
}
