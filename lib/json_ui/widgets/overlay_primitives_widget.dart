import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';
import 'icon_registry.dart';

class JsonAnchoredPopoverWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final triggerJson = json['trigger'];
    final bubbleJson = json['bubble'];
    return _AnchoredPopover(
      width: _resolveDouble(interpreter, json['width']) ?? 120,
      height: _resolveDouble(interpreter, json['height']) ?? 60,
      radius: _resolveDouble(interpreter, json['radius']) ?? 4,
      arrowWidth: _resolveDouble(interpreter, json['arrowWidth']) ?? 10,
      arrowHeight: _resolveDouble(interpreter, json['arrowHeight']) ?? 10,
      arrowLocation: _parseArrowLocation(json['arrowLocation']?.toString()),
      color: _parseColor(json['color']?.toString()) ?? Colors.white,
      text: interpreter.resolveTemplate(json['text']?.toString() ?? ''),
      trigger: triggerJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, triggerJson)
          : const SizedBox.shrink(),
      bubble: bubbleJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, bubbleJson)
          : null,
    );
  }
}

class _AnchoredPopover extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  final double arrowWidth;
  final double arrowHeight;
  final _ArrowLocation arrowLocation;
  final Color color;
  final String text;
  final Widget trigger;
  final Widget? bubble;

  const _AnchoredPopover({
    required this.width,
    required this.height,
    required this.radius,
    required this.arrowWidth,
    required this.arrowHeight,
    required this.arrowLocation,
    required this.color,
    required this.text,
    required this.trigger,
    required this.bubble,
  });

  @override
  State<_AnchoredPopover> createState() => _AnchoredPopoverState();
}

class _AnchoredPopoverState extends State<_AnchoredPopover> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
  }

  void _show() {
    if (_entry != null) {
      _dismiss();
      return;
    }
    final anchorBox = _anchorKey.currentContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final overlayBox = overlay?.context.findRenderObject();
    if (anchorBox is! RenderBox ||
        overlay == null ||
        overlayBox is! RenderBox) {
      return;
    }
    final topLeft = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final rect = topLeft & anchorBox.size;
    final overlaySize = overlayBox.size;
    final placement = _placementFor(rect, overlaySize);
    _entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _dismiss,
          child: Stack(
            children: [
              Positioned(
                left: placement.left,
                top: placement.top,
                width: widget.width,
                height: widget.height,
                child: _BubbleSurface(
                  width: widget.width,
                  height: widget.height,
                  radius: widget.radius,
                  arrowWidth: widget.arrowWidth,
                  arrowHeight: widget.arrowHeight,
                  arrowLocation: widget.arrowLocation,
                  arrowPosition: placement.arrowPosition,
                  color: widget.color,
                  child: widget.bubble ?? _defaultBubbleContent(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  _PopoverPlacement _placementFor(Rect anchor, Size overlaySize) {
    double left;
    double top;
    switch (widget.arrowLocation) {
      case _ArrowLocation.top:
        left = anchor.center.dx - widget.width / 2;
        top = anchor.bottom;
        break;
      case _ArrowLocation.right:
        left = anchor.left - widget.width;
        top = anchor.center.dy - widget.height / 2;
        break;
      case _ArrowLocation.left:
        left = anchor.right;
        top = anchor.center.dy - widget.height / 2;
        break;
      case _ArrowLocation.bottom:
        left = anchor.center.dx - widget.width / 2;
        top = anchor.top - widget.height;
        break;
    }

    final unclampedLeft = left;
    final unclampedTop = top;
    left = left.clamp(0, math.max(0, overlaySize.width - widget.width));
    top = top.clamp(0, math.max(0, overlaySize.height - widget.height));

    double arrowPosition;
    if (widget.arrowLocation == _ArrowLocation.top ||
        widget.arrowLocation == _ArrowLocation.bottom) {
      arrowPosition = anchor.center.dx - left - widget.arrowWidth / 2;
      if (unclampedLeft != left) {
        arrowPosition = arrowPosition.clamp(
          widget.radius + 4,
          widget.width - widget.radius - widget.arrowWidth - 4,
        );
      }
    } else {
      arrowPosition = anchor.center.dy - top - widget.arrowHeight / 2;
      if (unclampedTop != top) {
        arrowPosition = arrowPosition.clamp(
          widget.radius + 4,
          widget.height - widget.radius - widget.arrowHeight - 4,
        );
      }
    }
    return _PopoverPlacement(
      left: left.toDouble(),
      top: top.toDouble(),
      arrowPosition: arrowPosition.toDouble(),
    );
  }

  Widget _defaultBubbleContent() {
    final margin = widget.arrowLocation == _ArrowLocation.top
        ? EdgeInsets.only(top: widget.arrowHeight, left: 5, right: 5)
        : widget.arrowLocation == _ArrowLocation.bottom
        ? EdgeInsets.only(bottom: widget.arrowHeight, left: 5, right: 5)
        : widget.arrowLocation == _ArrowLocation.left
        ? EdgeInsets.only(left: widget.arrowWidth)
        : EdgeInsets.only(right: widget.arrowWidth);
    return Container(
      margin: margin,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            margin: const EdgeInsets.only(left: 20),
            height: widget.height,
            child: Icon(
              IconRegistry.get('notifications'),
              size: math.max(0, widget.height - 30),
              color: Colors.black87,
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(left: 5, right: 5),
              child: Text(
                widget.text,
                style: const TextStyle(fontSize: 14, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _anchorKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _show,
        child: widget.trigger,
      ),
    );
  }
}

class _BubbleSurface extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final double arrowWidth;
  final double arrowHeight;
  final _ArrowLocation arrowLocation;
  final double arrowPosition;
  final Color color;
  final Widget child;

  const _BubbleSurface({
    required this.width,
    required this.height,
    required this.radius,
    required this.arrowWidth,
    required this.arrowHeight,
    required this.arrowLocation,
    required this.arrowPosition,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _BubblePainter(
        radius: radius,
        arrowWidth: arrowWidth,
        arrowHeight: arrowHeight,
        arrowLocation: arrowLocation,
        arrowPosition: arrowPosition,
        color: color,
      ),
      child: SizedBox(width: width, height: height, child: child),
    );
  }
}

class _BubblePainter extends CustomPainter {
  final double radius;
  final double arrowWidth;
  final double arrowHeight;
  final _ArrowLocation arrowLocation;
  final double arrowPosition;
  final Color color;

  _BubblePainter({
    required this.radius,
    required this.arrowWidth,
    required this.arrowHeight,
    required this.arrowLocation,
    required this.arrowPosition,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path();
    switch (arrowLocation) {
      case _ArrowLocation.left:
        path
          ..moveTo(arrowWidth, arrowPosition + arrowHeight)
          ..lineTo(0, arrowPosition + arrowHeight / 2)
          ..lineTo(arrowWidth, arrowPosition)
          ..addRRect(
            RRect.fromLTRBR(
              arrowHeight,
              0,
              size.width,
              size.height,
              Radius.circular(radius),
            ),
          );
        break;
      case _ArrowLocation.right:
        path
          ..moveTo(size.width - arrowWidth, arrowPosition)
          ..lineTo(size.width, arrowPosition + arrowHeight / 2)
          ..lineTo(size.width - arrowWidth, arrowPosition + arrowHeight)
          ..addRRect(
            RRect.fromLTRBR(
              0,
              0,
              size.width - arrowHeight,
              size.height,
              Radius.circular(radius),
            ),
          );
        break;
      case _ArrowLocation.top:
        path
          ..moveTo(arrowPosition, arrowHeight)
          ..lineTo(arrowPosition + arrowWidth / 2, 0)
          ..lineTo(arrowPosition + arrowWidth, arrowHeight)
          ..addRRect(
            RRect.fromLTRBR(
              0,
              arrowHeight,
              size.width,
              size.height,
              Radius.circular(radius),
            ),
          );
        break;
      case _ArrowLocation.bottom:
        path
          ..moveTo(arrowPosition + arrowWidth, size.height - arrowHeight)
          ..lineTo(arrowPosition + arrowWidth / 2, size.height)
          ..lineTo(arrowPosition, size.height - arrowHeight)
          ..addRRect(
            RRect.fromLTRBR(
              0,
              0,
              size.width,
              size.height - arrowHeight,
              Radius.circular(radius),
            ),
          );
        break;
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) {
    return oldDelegate.radius != radius ||
        oldDelegate.arrowWidth != arrowWidth ||
        oldDelegate.arrowHeight != arrowHeight ||
        oldDelegate.arrowLocation != arrowLocation ||
        oldDelegate.arrowPosition != arrowPosition ||
        oldDelegate.color != color;
  }
}

class JsonOverlaySpawnerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final triggerJson = json['trigger'];
    final entryJson = json['entry'];
    return _OverlaySpawner(
      initialLeft: _resolveDouble(interpreter, json['initialLeft']) ?? 200,
      initialTop: _resolveDouble(interpreter, json['initialTop']) ?? 200,
      entryWidth: _resolveDouble(interpreter, json['entryWidth']) ?? 80,
      entryHeight: _resolveDouble(interpreter, json['entryHeight']) ?? 80,
      draggable: json['draggable'] != false,
      longPressRemove: json['longPressRemove'] != false,
      interpreter: interpreter,
      triggerJson: triggerJson is Map<String, dynamic> ? triggerJson : null,
      entryJson: entryJson is Map<String, dynamic> ? entryJson : null,
    );
  }
}

class _OverlaySpawner extends StatefulWidget {
  final double initialLeft;
  final double initialTop;
  final double entryWidth;
  final double entryHeight;
  final bool draggable;
  final bool longPressRemove;
  final JsonInterpreter interpreter;
  final Map<String, dynamic>? triggerJson;
  final Map<String, dynamic>? entryJson;

  const _OverlaySpawner({
    required this.initialLeft,
    required this.initialTop,
    required this.entryWidth,
    required this.entryHeight,
    required this.draggable,
    required this.longPressRemove,
    required this.interpreter,
    required this.triggerJson,
    required this.entryJson,
  });

  @override
  State<_OverlaySpawner> createState() => _OverlaySpawnerState();
}

class _OverlaySpawnerState extends State<_OverlaySpawner> {
  final List<OverlayEntry> _entries = [];

  @override
  void dispose() {
    for (final entry in List<OverlayEntry>.from(_entries)) {
      entry.remove();
    }
    _entries.clear();
    super.dispose();
  }

  void _spawn() {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null || widget.entryJson == null) return;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => _SpawnedOverlayEntry(
        initialLeft: widget.initialLeft,
        initialTop: widget.initialTop,
        width: widget.entryWidth,
        height: widget.entryHeight,
        draggable: widget.draggable,
        longPressRemove: widget.longPressRemove,
        onRemove: () {
          entry.remove();
          _entries.remove(entry);
        },
        childBuilder: (context) =>
            widget.interpreter.buildWidget(context, widget.entryJson!),
      ),
    );
    _entries.add(entry);
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final trigger = widget.triggerJson == null
        ? const SizedBox.shrink()
        : widget.interpreter.buildWidget(context, widget.triggerJson!);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _spawn,
      child: trigger,
    );
  }
}

class _SpawnedOverlayEntry extends StatefulWidget {
  final double initialLeft;
  final double initialTop;
  final double width;
  final double height;
  final bool draggable;
  final bool longPressRemove;
  final VoidCallback onRemove;
  final Widget Function(BuildContext context) childBuilder;

  const _SpawnedOverlayEntry({
    required this.initialLeft,
    required this.initialTop,
    required this.width,
    required this.height,
    required this.draggable,
    required this.longPressRemove,
    required this.onRemove,
    required this.childBuilder,
  });

  @override
  State<_SpawnedOverlayEntry> createState() => _SpawnedOverlayEntryState();
}

class _SpawnedOverlayEntryState extends State<_SpawnedOverlayEntry> {
  late Offset _offset;

  @override
  void initState() {
    super.initState();
    _offset = Offset(widget.initialLeft, widget.initialTop);
  }

  void _panDown(DragDownDetails details) {
    if (!widget.draggable) return;
    setState(() {
      _offset =
          details.globalPosition - Offset(widget.width / 2, widget.height / 2);
    });
  }

  void _panUpdate(DragUpdateDetails details) {
    if (!widget.draggable) return;
    setState(() {
      _offset += details.delta;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _offset.dx,
      top: _offset.dy,
      width: widget.width,
      height: widget.height,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onPanDown: _panDown,
        onPanUpdate: _panUpdate,
        onLongPress: widget.longPressRemove ? widget.onRemove : null,
        child: Material(
          color: Colors.transparent,
          child: widget.childBuilder(context),
        ),
      ),
    );
  }
}

class _PopoverPlacement {
  final double left;
  final double top;
  final double arrowPosition;

  const _PopoverPlacement({
    required this.left,
    required this.top,
    required this.arrowPosition,
  });
}

enum _ArrowLocation { left, right, top, bottom }

_ArrowLocation _parseArrowLocation(String? value) {
  switch (value) {
    case 'left':
      return _ArrowLocation.left;
    case 'right':
      return _ArrowLocation.right;
    case 'top':
      return _ArrowLocation.top;
    case 'bottom':
    default:
      return _ArrowLocation.bottom;
  }
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
