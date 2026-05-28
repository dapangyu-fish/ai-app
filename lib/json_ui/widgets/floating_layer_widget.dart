import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../navigation/app_route_observer.dart';
import '../interpreter.dart';
import 'base_widget.dart';

class FloatingLayerItemSpec {
  final String id;
  final Offset center;
  final double size;
  final double? minSize;
  final double? maxSize;
  final double opacity;
  final Widget child;

  const FloatingLayerItemSpec({
    required this.id,
    required this.center,
    required this.size,
    required this.child,
    this.minSize,
    this.maxSize,
    this.opacity = 1.0,
  });
}

class FloatingLayerHost extends StatefulWidget {
  final String storageKey;
  final bool enabled;
  final bool editing;
  final bool ignoreChildPointerWhenEditing;
  final int resetRevision;
  final Widget? topRight;
  final List<FloatingLayerItemSpec> items;

  const FloatingLayerHost({
    super.key,
    required this.storageKey,
    required this.items,
    this.enabled = true,
    this.editing = false,
    this.ignoreChildPointerWhenEditing = true,
    this.resetRevision = 0,
    this.topRight,
  });

  @override
  State<FloatingLayerHost> createState() => _FloatingLayerHostState();
}

class _FloatingLayerHostState extends State<FloatingLayerHost> with RouteAware {
  OverlayEntry? _overlayEntry;
  late Map<String, Offset> _centers;
  late Map<String, double> _sizes;
  final Map<String, _FloatingEditGesture> _editGestures = {};
  PageRoute<dynamic>? _route;
  bool _routeVisible = true;
  bool _ensureOverlayScheduled = false;
  bool _markOverlayScheduled = false;

  @override
  void initState() {
    super.initState();
    _centers = _defaultCenters();
    _sizes = _defaultSizes();
    _loadPrefs();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextRoute = ModalRoute.of(context);
    if (_route == nextRoute) return;
    if (_route != null) {
      appRouteObserver.unsubscribe(this);
    }
    _route = nextRoute is PageRoute<dynamic> ? nextRoute : null;
    final route = _route;
    if (route != null) {
      appRouteObserver.subscribe(this, route);
      _routeVisible = route.isCurrent;
    } else {
      _routeVisible = true;
    }
    _scheduleEnsureOverlay();
  }

  @override
  void didUpdateWidget(covariant FloatingLayerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final structureChanged =
        oldWidget.storageKey != widget.storageKey ||
        oldWidget.items.map((e) => e.id).join('|') !=
            widget.items.map((e) => e.id).join('|');
    if (structureChanged) {
      _centers = _defaultCenters();
      _sizes = _defaultSizes();
      _editGestures.clear();
      _loadPrefs();
    }
    if (oldWidget.resetRevision != widget.resetRevision) {
      _centers = _defaultCenters();
      _sizes = _defaultSizes();
      _editGestures.clear();
      _savePrefs();
    }
    if (!widget.enabled || !_canShowOverlay) {
      _editGestures.clear();
      _removeOverlay();
      return;
    }
    _scheduleEnsureOverlay();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _removeOverlay();
    super.dispose();
  }

  @override
  void didPush() {
    _routeVisible = true;
    _scheduleEnsureOverlay();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _scheduleEnsureOverlay();
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    _removeOverlay();
  }

  @override
  void didPop() {
    _routeVisible = false;
    _removeOverlay();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !_canShowOverlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _removeOverlay());
      return const SizedBox.shrink();
    }
    _scheduleEnsureOverlay();
    return const SizedBox.shrink();
  }

  Widget _buildOverlay(BuildContext context) {
    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final area = Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final item in widget.items)
                    _floatingItem(area: area, item: item),
                  if (widget.topRight != null)
                    Positioned(top: 10, right: 10, child: widget.topRight!),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _floatingItem({
    required Size area,
    required FloatingLayerItemSpec item,
  }) {
    final size = _currentSize(item, area);
    final center = _clampNormalized(
      _centers[item.id] ?? item.center,
      area,
      size,
    );
    final left = area.width * center.dx - size / 2;
    final top = area.height * center.dy - size / 2;
    return Positioned(
      left: left,
      top: top,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: widget.editing
            ? (event) => _handlePointerDown(
                item: item,
                area: area,
                left: left,
                top: top,
                event: event,
              )
            : null,
        onPointerMove: widget.editing
            ? (event) => _handlePointerMove(
                item: item,
                area: area,
                left: left,
                top: top,
                event: event,
              )
            : null,
        onPointerUp: widget.editing
            ? (event) => _handlePointerUp(item.id, event.pointer)
            : null,
        onPointerCancel: widget.editing
            ? (event) => _handlePointerUp(item.id, event.pointer)
            : null,
        child: DecoratedBox(
          decoration: widget.editing
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(size / 2),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.6),
                    width: 2,
                  ),
                )
              : const BoxDecoration(),
          child: IgnorePointer(
            ignoring: widget.editing && widget.ignoreChildPointerWhenEditing,
            child: Opacity(
              opacity: item.opacity.clamp(0.0, 1.0),
              child: SizedBox.square(
                dimension: size,
                child: FittedBox(
                  fit: BoxFit.fill,
                  child: SizedBox.square(
                    dimension: item.size,
                    child: item.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _ensureOverlay() {
    if (!mounted || !widget.enabled || !_canShowOverlay) {
      _removeOverlay();
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_overlayEntry == null) {
      _overlayEntry = OverlayEntry(builder: _buildOverlay);
      overlay.insert(_overlayEntry!);
    } else {
      _markOverlayNeedsBuild();
    }
  }

  void _scheduleEnsureOverlay() {
    if (_ensureOverlayScheduled) return;
    _ensureOverlayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureOverlayScheduled = false;
      if (!mounted) return;
      _ensureOverlay();
    });
  }

  void _markOverlayNeedsBuild() {
    final entry = _overlayEntry;
    if (entry == null) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    final isBuilding =
        phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
    if (!isBuilding) {
      entry.markNeedsBuild();
      return;
    }
    if (_markOverlayScheduled) return;
    _markOverlayScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markOverlayScheduled = false;
      if (!mounted || _overlayEntry == null) return;
      if (!widget.enabled || !_canShowOverlay) {
        _removeOverlay();
        return;
      }
      _overlayEntry?.markNeedsBuild();
    });
  }

  void _removeOverlay() {
    _editGestures.clear();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final nextCenters = _defaultCenters();
      final nextSizes = _defaultSizes();
      for (final item in widget.items) {
        final x = prefs.getDouble('$_prefsPrefix.${item.id}.x');
        final y = prefs.getDouble('$_prefsPrefix.${item.id}.y');
        if (x != null && y != null) {
          nextCenters[item.id] = Offset(x, y);
        }
        final size = prefs.getDouble('$_prefsPrefix.${item.id}.size');
        if (size != null) {
          nextSizes[item.id] = _clampSize(size, item, Size.zero);
        }
      }
      if (!mounted) return;
      setState(() {
        _centers = nextCenters;
        _sizes = nextSizes;
      });
      _markOverlayNeedsBuild();
    } catch (_) {
      // Floating position is a local preference; defaults are sufficient.
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final entry in _centers.entries) {
        await prefs.setDouble('$_prefsPrefix.${entry.key}.x', entry.value.dx);
        await prefs.setDouble('$_prefsPrefix.${entry.key}.y', entry.value.dy);
      }
      for (final entry in _sizes.entries) {
        await prefs.setDouble('$_prefsPrefix.${entry.key}.size', entry.value);
      }
    } catch (_) {
      // Floating controls should continue even if local storage fails.
    }
  }

  Map<String, Offset> _defaultCenters() {
    return {for (final item in widget.items) item.id: item.center};
  }

  Map<String, double> _defaultSizes() {
    return {for (final item in widget.items) item.id: item.size};
  }

  double _currentSize(FloatingLayerItemSpec item, Size area) {
    return _clampSize(_sizes[item.id] ?? item.size, item, area);
  }

  double _clampSize(double value, FloatingLayerItemSpec item, Size area) {
    final minSize = item.minSize ?? math.max(32.0, item.size * 0.5);
    var maxSize = item.maxSize ?? item.size * 2.0;
    if (area.width > 0 && area.height > 0) {
      maxSize = math.min(maxSize, math.min(area.width, area.height) * 0.72);
    }
    if (maxSize < minSize) return minSize;
    return value.clamp(minSize, maxSize).toDouble();
  }

  void _handlePointerDown({
    required FloatingLayerItemSpec item,
    required Size area,
    required double left,
    required double top,
    required PointerDownEvent event,
  }) {
    final gesture = _editGestures.putIfAbsent(
      item.id,
      _FloatingEditGesture.new,
    );
    final point = Offset(left, top) + event.localPosition;
    gesture.pointers[event.pointer] = point;

    if (gesture.anchorPointer == null) {
      gesture.anchorPointer = event.pointer;
      gesture.lastDragPoint = point;
      return;
    }

    if (gesture.scalePointer == null &&
        event.pointer != gesture.anchorPointer) {
      _beginScaleGesture(gesture, event.pointer, item, area);
    }
  }

  void _handlePointerMove({
    required FloatingLayerItemSpec item,
    required Size area,
    required double left,
    required double top,
    required PointerMoveEvent event,
  }) {
    final gesture = _editGestures[item.id];
    if (gesture == null) return;

    final point = Offset(left, top) + event.localPosition;
    gesture.pointers[event.pointer] = point;

    final anchorPointer = gesture.anchorPointer;
    final scalePointer = gesture.scalePointer;
    if (anchorPointer == null) return;

    if (scalePointer != null && gesture.pointers.containsKey(scalePointer)) {
      _updateScaleGesture(gesture, item, area);
      return;
    }

    if (event.pointer != anchorPointer) return;
    final last = gesture.lastDragPoint;
    if (last == null || area.width <= 0 || area.height <= 0) {
      gesture.lastDragPoint = point;
      return;
    }

    final size = _currentSize(item, area);
    final currentCenter = _centers[item.id] ?? item.center;
    final nextCenterPx = Offset(
      area.width * currentCenter.dx + point.dx - last.dx,
      area.height * currentCenter.dy + point.dy - last.dy,
    );
    final next = Offset(
      nextCenterPx.dx / area.width,
      nextCenterPx.dy / area.height,
    );

    setState(() {
      _centers[item.id] = _clampNormalized(next, area, size);
    });
    gesture.lastDragPoint = point;
    _markOverlayNeedsBuild();
  }

  void _handlePointerUp(String itemId, int pointer) {
    final gesture = _editGestures[itemId];
    if (gesture == null) return;
    final wasAnchor = pointer == gesture.anchorPointer;
    final wasScalePointer = pointer == gesture.scalePointer;
    gesture.pointers.remove(pointer);

    if (gesture.pointers.isEmpty) {
      _editGestures.remove(itemId);
      _savePrefs();
      return;
    }

    if (wasAnchor || wasScalePointer) {
      gesture.scalePointer = null;
      gesture.initialDistance = null;
      gesture.initialSize = null;
      gesture.initialCenter = null;
      gesture.scaleAnchor = null;
    }
    if (wasAnchor) {
      gesture.anchorPointer = gesture.pointers.keys.first;
      gesture.lastDragPoint = gesture.pointers[gesture.anchorPointer];
    } else if (wasScalePointer) {
      gesture.lastDragPoint = gesture.pointers[gesture.anchorPointer];
    }
    _savePrefs();
  }

  void _beginScaleGesture(
    _FloatingEditGesture gesture,
    int scalePointer,
    FloatingLayerItemSpec item,
    Size area,
  ) {
    final anchor = gesture.pointers[gesture.anchorPointer];
    final scalePoint = gesture.pointers[scalePointer];
    if (anchor == null || scalePoint == null) return;

    final distance = (scalePoint - anchor).distance;
    if (distance <= 1) return;

    final currentCenter = _centers[item.id] ?? item.center;
    gesture.scalePointer = scalePointer;
    gesture.scaleAnchor = anchor;
    gesture.initialDistance = distance;
    gesture.initialSize = _currentSize(item, area);
    gesture.initialCenter = Offset(
      area.width * currentCenter.dx,
      area.height * currentCenter.dy,
    );
  }

  void _updateScaleGesture(
    _FloatingEditGesture gesture,
    FloatingLayerItemSpec item,
    Size area,
  ) {
    final anchor = gesture.scaleAnchor;
    final scalePointer = gesture.scalePointer;
    final initialDistance = gesture.initialDistance;
    final initialSize = gesture.initialSize;
    final initialCenter = gesture.initialCenter;
    if (anchor == null ||
        scalePointer == null ||
        initialDistance == null ||
        initialSize == null ||
        initialCenter == null ||
        initialDistance <= 1 ||
        area.width <= 0 ||
        area.height <= 0) {
      return;
    }

    final scalePoint = gesture.pointers[scalePointer];
    if (scalePoint == null) return;

    final ratio = ((scalePoint - anchor).distance / initialDistance).clamp(
      0.35,
      3.0,
    );
    final nextSize = _clampSize(initialSize * ratio, item, area);
    final centerRatio = initialSize <= 0 ? 1.0 : nextSize / initialSize;
    final nextCenterPx = anchor + (initialCenter - anchor) * centerRatio;
    final nextCenter = Offset(
      nextCenterPx.dx / area.width,
      nextCenterPx.dy / area.height,
    );

    setState(() {
      _sizes[item.id] = nextSize;
      _centers[item.id] = _clampNormalized(nextCenter, area, nextSize);
    });
    _markOverlayNeedsBuild();
  }

  Offset _clampNormalized(Offset value, Size area, double controlSize) {
    final minX = area.width <= 0 ? 0.0 : (controlSize / 2) / area.width;
    final minY = area.height <= 0 ? 0.0 : (controlSize / 2) / area.height;
    return Offset(
      value.dx.clamp(minX, 1 - minX).toDouble(),
      value.dy.clamp(minY, 1 - minY).toDouble(),
    );
  }

  String get _prefsPrefix => 'floating_layer.${widget.storageKey}';

  bool get _canShowOverlay => _routeVisible && (_route?.isCurrent ?? true);
}

class _FloatingEditGesture {
  final Map<int, Offset> pointers = {};
  int? anchorPointer;
  int? scalePointer;
  Offset? lastDragPoint;
  Offset? scaleAnchor;
  Offset? initialCenter;
  double? initialDistance;
  double? initialSize;
}

class JsonFloatingLayerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final items = _items(json['items']).map((item) {
      final childJson = item['child'];
      return FloatingLayerItemSpec(
        id: item['id']?.toString() ?? 'item',
        center: _offset(item['center'], const Offset(0.5, 0.5)),
        size: _num(item['size'], 96),
        minSize: item.containsKey('minSize') ? _num(item['minSize'], 0) : null,
        maxSize: item.containsKey('maxSize') ? _num(item['maxSize'], 0) : null,
        opacity: _num(item['opacity'], 1.0),
        child: childJson is Map<String, dynamic>
            ? interpreter.buildWidget(context, childJson)
            : const SizedBox.shrink(),
      );
    }).toList();

    return FloatingLayerHost(
      storageKey: _storageKey(json),
      enabled: _bool(interpreter, json['enabled'], fallback: true),
      editing: _bool(interpreter, json['editing']),
      resetRevision: _int(
        interpreter.resolveExpression(json['resetRevision']),
        0,
      ),
      topRight: json['topRight'] is Map<String, dynamic>
          ? interpreter.buildWidget(
              context,
              json['topRight'] as Map<String, dynamic>,
            )
          : null,
      items: items,
    );
  }

  static String _storageKey(Map<String, dynamic> json) {
    final raw = json['storageKey'] ?? json['id'] ?? 'default';
    final text = raw.toString().trim();
    if (text.isEmpty || text.contains('{{')) return 'default';
    return text;
  }
}

List<Map<String, dynamic>> _items(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.map((k, v) => MapEntry(k.toString(), v)))
      .toList();
}

Offset _offset(dynamic value, Offset fallback) {
  if (value is List && value.length >= 2) {
    return Offset(_num(value[0], fallback.dx), _num(value[1], fallback.dy));
  }
  if (value is Map) {
    return Offset(_num(value['x'], fallback.dx), _num(value['y'], fallback.dy));
  }
  return fallback;
}

double _num(dynamic value, double fallback) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

int _int(dynamic value, int fallback) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool _bool(
  JsonInterpreter interpreter,
  dynamic value, {
  bool fallback = false,
}) {
  dynamic resolved;
  if (value is Map<String, dynamic> && interpreter.looksLikeJsonLogic(value)) {
    resolved = interpreter.evaluateJsonLogicWithLocals(value, const {});
  } else {
    resolved = interpreter.resolveExpression(value);
  }
  if (resolved == null) return fallback;
  if (resolved is bool) return resolved;
  if (resolved is num) return resolved != 0;
  if (resolved is String) {
    final lower = resolved.trim().toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
    return lower.isNotEmpty;
  }
  if (resolved is List) return resolved.isNotEmpty;
  return fallback;
}
