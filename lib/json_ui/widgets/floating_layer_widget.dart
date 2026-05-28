import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class FloatingLayerItemSpec {
  final String id;
  final Offset center;
  final double size;
  final double opacity;
  final Widget child;

  const FloatingLayerItemSpec({
    required this.id,
    required this.center,
    required this.size,
    required this.child,
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

class _FloatingLayerHostState extends State<FloatingLayerHost> {
  OverlayEntry? _overlayEntry;
  late Map<String, Offset> _centers;

  @override
  void initState() {
    super.initState();
    _centers = _defaultCenters();
    _loadPrefs();
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
      _loadPrefs();
    }
    if (oldWidget.resetRevision != widget.resetRevision) {
      _centers = _defaultCenters();
      _savePrefs();
    }
    if (!widget.enabled) {
      _removeOverlay();
    }
    _overlayEntry?.markNeedsBuild();
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _removeOverlay());
      return const SizedBox.shrink();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureOverlay());
    return const SizedBox.shrink();
  }

  Widget _buildOverlay(BuildContext context) {
    return Positioned.fill(
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
    );
  }

  Widget _floatingItem({
    required Size area,
    required FloatingLayerItemSpec item,
  }) {
    final center = _clampNormalized(
      _centers[item.id] ?? item.center,
      area,
      item.size,
    );
    final left = area.width * center.dx - item.size / 2;
    final top = area.height * center.dy - item.size / 2;
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: widget.editing
            ? (details) {
                final next = Offset(
                  (area.width * center.dx + details.delta.dx) / area.width,
                  (area.height * center.dy + details.delta.dy) / area.height,
                );
                setState(() {
                  _centers[item.id] = _clampNormalized(next, area, item.size);
                });
                _overlayEntry?.markNeedsBuild();
              }
            : null,
        onPanEnd: widget.editing ? (_) => _savePrefs() : null,
        onPanCancel: widget.editing ? _savePrefs : null,
        child: DecoratedBox(
          decoration: widget.editing
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(item.size / 2),
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
              child: SizedBox.square(dimension: item.size, child: item.child),
            ),
          ),
        ),
      ),
    );
  }

  void _ensureOverlay() {
    if (!mounted || !widget.enabled) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_overlayEntry == null) {
      _overlayEntry = OverlayEntry(builder: _buildOverlay);
      overlay.insert(_overlayEntry!);
    } else {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = _defaultCenters();
      for (final item in widget.items) {
        final x = prefs.getDouble('$_prefsPrefix.${item.id}.x');
        final y = prefs.getDouble('$_prefsPrefix.${item.id}.y');
        if (x != null && y != null) {
          next[item.id] = Offset(x, y);
        }
      }
      if (!mounted) return;
      setState(() => _centers = next);
      _overlayEntry?.markNeedsBuild();
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
    } catch (_) {
      // Floating controls should continue even if local storage fails.
    }
  }

  Map<String, Offset> _defaultCenters() {
    return {for (final item in widget.items) item.id: item.center};
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
        opacity: _num(item['opacity'], 1.0),
        child: childJson is Map<String, dynamic>
            ? interpreter.buildWidget(context, childJson)
            : const SizedBox.shrink(),
      );
    }).toList();

    return FloatingLayerHost(
      storageKey: _storageKey(json),
      enabled: interpreter.resolveExpression(json['enabled']) != false,
      editing: interpreter.resolveExpression(json['editing']) == true,
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
