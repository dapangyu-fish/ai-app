import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonVirtualGamepadWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return _VirtualGamepad(json: json, interpreter: interpreter);
  }
}

class _VirtualGamepad extends StatefulWidget {
  final Map<String, dynamic> json;
  final JsonInterpreter interpreter;

  const _VirtualGamepad({required this.json, required this.interpreter});

  @override
  State<_VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<_VirtualGamepad> {
  static const _styleDefault = 'default';
  static const _styleDpad = 'dpad';
  static const _styleFloating = 'floating';

  String _style = _styleDefault;
  Offset _floatingLeft = const Offset(0.22, 0.78);
  Offset _floatingRight = const Offset(0.78, 0.78);
  bool _editingFloating = false;
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _style = _styleFromJson();
    _loadPrefs();
  }

  @override
  void didUpdateWidget(covariant _VirtualGamepad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_storageKey(oldWidget.json) != _storageKey(widget.json)) {
      _style = _styleFromJson();
      _floatingLeft = const Offset(0.22, 0.78);
      _floatingRight = const Offset(0.78, 0.78);
      _loadPrefs();
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
    if (_style == _styleFloating) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureOverlay());
      return const SizedBox.shrink();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _removeOverlay());
    return _buildDocked(context, _style == _styleDpad);
  }

  Widget _buildDocked(BuildContext context, bool useDpad) {
    final json = widget.json;
    final height = _num(json['height'], 168);
    final background =
        _color(json['backgroundColor']) ??
        Theme.of(context).colorScheme.surface.withValues(alpha: 0.92);

    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(color: background),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              _num(json['paddingHorizontal'], 18),
              _num(json['paddingTop'], 10),
              _num(json['paddingHorizontal'], 18),
              _num(json['paddingBottom'], 12),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final gap = _num(json['gap'], 20);
                final available = math.max(120.0, constraints.maxWidth - gap);
                final leftWanted = _num(
                  useDpad ? json['dpadSize'] : json['joystickSize'],
                  128,
                );
                final clusterWanted = _num(json['actionClusterSize'], 142);
                final maxSide = math.max(92.0, available / 2);
                final leftSize = math.min(leftWanted, maxSide);
                final clusterSize = math.min(clusterWanted, maxSide);
                final left = SizedBox.square(
                  dimension: leftSize,
                  child: useDpad
                      ? _DPad(
                          items: _directions(),
                          interpreter: widget.interpreter,
                        )
                      : _Joystick(
                          spec: _joystick(),
                          interpreter: widget.interpreter,
                        ),
                );
                final actionLayout = (json['actionLayout'] ?? 'wrap')
                    .toString()
                    .toLowerCase();
                final right =
                    actionLayout == 'ps' ||
                        actionLayout == 'playstation' ||
                        actionLayout == 'diamond'
                    ? _ActionCluster(
                        items: _actions(),
                        size: clusterSize,
                        interpreter: widget.interpreter,
                      )
                    : _ActionWrap(
                        items: _actions(),
                        interpreter: widget.interpreter,
                        spacing: _num(json['actionSpacing'], 12),
                      );
                return Stack(
                  children: [
                    Row(
                      children: [
                        left,
                        SizedBox(width: gap),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: right,
                          ),
                        ),
                      ],
                    ),
                    if (_styleMenuEnabled)
                      Positioned(
                        top: 0,
                        left: math.max(0, (constraints.maxWidth - 40) / 2),
                        child: _menuButton(context),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingOverlay(BuildContext context) {
    final joystickSize = _num(widget.json['floatingJoystickSize'], 118);
    final clusterSize = _num(widget.json['floatingActionClusterSize'], 138);
    final opacity = _num(widget.json['floatingOpacity'], 0.72).clamp(0.25, 1.0);

    return Positioned.fill(
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final area = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                _floatingControl(
                  area: area,
                  center: _floatingLeft,
                  size: joystickSize,
                  onChanged: (v) => _updateFloatingPosition(left: v),
                  child: Opacity(
                    opacity: opacity,
                    child: _Joystick(
                      spec: _joystick(),
                      interpreter: widget.interpreter,
                    ),
                  ),
                ),
                _floatingControl(
                  area: area,
                  center: _floatingRight,
                  size: clusterSize,
                  onChanged: (v) => _updateFloatingPosition(right: v),
                  child: Opacity(
                    opacity: opacity,
                    child: _ActionCluster(
                      items: _actions(),
                      size: clusterSize,
                      interpreter: widget.interpreter,
                    ),
                  ),
                ),
                if (_styleMenuEnabled)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: _menuButton(context, floating: true),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _floatingControl({
    required Size area,
    required Offset center,
    required double size,
    required ValueChanged<Offset> onChanged,
    required Widget child,
  }) {
    final clamped = _clampNormalized(center, area, size);
    final left = area.width * clamped.dx - size / 2;
    final top = area.height * clamped.dy - size / 2;
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: _editingFloating
            ? (details) {
                final next = Offset(
                  (area.width * clamped.dx + details.delta.dx) / area.width,
                  (area.height * clamped.dy + details.delta.dy) / area.height,
                );
                onChanged(_clampNormalized(next, area, size));
              }
            : null,
        child: DecoratedBox(
          decoration: _editingFloating
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(size / 2),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.6),
                    width: 2,
                  ),
                )
              : const BoxDecoration(),
          child: IgnorePointer(
            ignoring: _editingFloating,
            child: SizedBox.square(dimension: size, child: child),
          ),
        ),
      ),
    );
  }

  Widget _menuButton(BuildContext context, {bool floating = false}) {
    if (floating && _editingFloating) {
      return _RoundToolButton(
        icon: Icons.check,
        tooltip: _t(context, 'lock'),
        onPressed: () {
          setState(() => _editingFloating = false);
          _savePrefs();
          _overlayEntry?.markNeedsBuild();
        },
      );
    }
    return Material(
      color: Colors.transparent,
      child: PopupMenuButton<String>(
        tooltip: _t(context, 'style'),
        icon: Icon(
          Icons.sports_esports,
          color: Colors.white.withValues(alpha: floating ? 0.88 : 0.78),
          size: 22,
        ),
        color: Theme.of(context).colorScheme.surface,
        onSelected: (value) {
          switch (value) {
            case _styleDefault:
            case _styleDpad:
            case _styleFloating:
              _setStyle(value);
              break;
            case 'edit':
              _setStyle(_styleFloating, edit: true);
              break;
            case 'reset':
              setState(() {
                _floatingLeft = const Offset(0.22, 0.78);
                _floatingRight = const Offset(0.78, 0.78);
              });
              _savePrefs();
              _overlayEntry?.markNeedsBuild();
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: _styleDefault, child: Text(_t(context, 'ps'))),
          PopupMenuItem(value: _styleDpad, child: Text(_t(context, 'dpad'))),
          PopupMenuItem(
            value: _styleFloating,
            child: Text(_t(context, 'floating')),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'edit', child: Text(_t(context, 'edit'))),
          PopupMenuItem(value: 'reset', child: Text(_t(context, 'reset'))),
        ],
      ),
    );
  }

  void _setStyle(String style, {bool edit = false}) {
    setState(() {
      _style = style;
      _editingFloating = style == _styleFloating && edit;
    });
    _savePrefs();
    _overlayEntry?.markNeedsBuild();
  }

  void _updateFloatingPosition({Offset? left, Offset? right}) {
    setState(() {
      if (left != null) _floatingLeft = left;
      if (right != null) _floatingRight = right;
    });
    _overlayEntry?.markNeedsBuild();
  }

  void _ensureOverlay() {
    if (!mounted || _style != _styleFloating) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_overlayEntry == null) {
      _overlayEntry = OverlayEntry(builder: _buildFloatingOverlay);
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
    if (!_styleMenuEnabled) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = _prefsPrefix;
      final savedStyle = prefs.getString('$prefix.style');
      final lx = prefs.getDouble('$prefix.leftX');
      final ly = prefs.getDouble('$prefix.leftY');
      final rx = prefs.getDouble('$prefix.rightX');
      final ry = prefs.getDouble('$prefix.rightY');
      if (!mounted) return;
      setState(() {
        if (_isStyle(savedStyle)) _style = savedStyle!;
        if (lx != null && ly != null) _floatingLeft = Offset(lx, ly);
        if (rx != null && ry != null) _floatingRight = Offset(rx, ry);
      });
      _overlayEntry?.markNeedsBuild();
    } catch (_) {
      // Non-critical local preference; keep JSON defaults if unavailable.
    }
  }

  Future<void> _savePrefs() async {
    if (!_styleMenuEnabled) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = _prefsPrefix;
      await prefs.setString('$prefix.style', _style);
      await prefs.setDouble('$prefix.leftX', _floatingLeft.dx);
      await prefs.setDouble('$prefix.leftY', _floatingLeft.dy);
      await prefs.setDouble('$prefix.rightX', _floatingRight.dx);
      await prefs.setDouble('$prefix.rightY', _floatingRight.dy);
    } catch (_) {
      // Controls must keep working even if preference storage fails.
    }
  }

  List<Map<String, dynamic>> _directions() {
    final explicit = _items(widget.json['directions']);
    if (explicit.isNotEmpty) return explicit;
    final joystick = _joystick();
    return [
      _directionItem('up', '↑', 0, -1, -math.pi / 2, joystick),
      _directionItem('left', '←', -1, 0, math.pi, joystick),
      _directionItem('right', '→', 1, 0, 0, joystick),
      _directionItem('down', '↓', 0, 1, math.pi / 2, joystick),
    ];
  }

  Map<String, dynamic> _directionItem(
    String id,
    String label,
    double x,
    double y,
    double angle,
    Map<String, dynamic> joystick,
  ) {
    return {
      'id': id,
      'label': label,
      'onDown': joystick['onChange'],
      'onUp': joystick['onEnd'] ?? joystick['onChange'],
      '_downEvent': {
        'x': x,
        'y': y,
        'strength': 1.0,
        'angle': angle,
        'direction': id,
      },
      '_upEvent': const {
        'x': 0.0,
        'y': 0.0,
        'strength': 0.0,
        'angle': 0.0,
        'direction': 'center',
      },
    };
  }

  List<Map<String, dynamic>> _actions() => _items(widget.json['actions']);

  Map<String, dynamic> _joystick() => widget.json['joystick'] is Map
      ? (widget.json['joystick'] as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        )
      : <String, dynamic>{};

  Offset _clampNormalized(Offset value, Size area, double controlSize) {
    final minX = area.width <= 0 ? 0.0 : (controlSize / 2) / area.width;
    final minY = area.height <= 0 ? 0.0 : (controlSize / 2) / area.height;
    return Offset(
      value.dx.clamp(minX, 1 - minX).toDouble(),
      value.dy.clamp(minY, 1 - minY).toDouble(),
    );
  }

  String _styleFromJson() {
    final raw = (widget.json['style'] ?? widget.json['controlStyle'])
        ?.toString()
        .toLowerCase();
    if (_isStyle(raw)) return raw!;
    final mode = (widget.json['mode'] ?? widget.json['leftMode'] ?? 'dpad')
        .toString()
        .toLowerCase();
    return mode == 'joystick' ? _styleDefault : _styleDpad;
  }

  bool _isStyle(String? value) {
    return value == _styleDefault ||
        value == _styleDpad ||
        value == _styleFloating;
  }

  bool get _styleMenuEnabled {
    return widget.json['styleMenu'] == true ||
        widget.json['showStyleMenu'] == true;
  }

  String get _prefsPrefix {
    return 'virtual_gamepad.${_storageKey(widget.json)}';
  }

  static String _storageKey(Map<String, dynamic> json) {
    final raw = json['storageKey'] ?? json['id'] ?? 'default';
    final text = raw.toString().trim();
    if (text.isEmpty || text.contains('{{')) return 'default';
    return text;
  }

  String _t(BuildContext context, String key) {
    final code = Localizations.localeOf(context).languageCode;
    const zh = {
      'style': '手柄样式',
      'ps': '默认 PS 样式',
      'dpad': '方向键',
      'floating': '悬浮模式',
      'edit': '调整悬浮位置',
      'reset': '重置悬浮位置',
      'lock': '锁定位置',
    };
    const de = {
      'style': 'Gamepad-Stil',
      'ps': 'Standard PS',
      'dpad': 'Richtungstasten',
      'floating': 'Schwebend',
      'edit': 'Position anpassen',
      'reset': 'Position zurücksetzen',
      'lock': 'Position sperren',
    };
    const es = {
      'style': 'Estilo de mando',
      'ps': 'PS predeterminado',
      'dpad': 'Cruceta',
      'floating': 'Flotante',
      'edit': 'Ajustar posición',
      'reset': 'Restablecer posición',
      'lock': 'Bloquear posición',
    };
    const en = {
      'style': 'Gamepad style',
      'ps': 'Default PS',
      'dpad': 'D-pad',
      'floating': 'Floating',
      'edit': 'Adjust floating layout',
      'reset': 'Reset floating layout',
      'lock': 'Lock layout',
    };
    return switch (code) {
      'zh' => zh[key] ?? en[key]!,
      'de' => de[key] ?? en[key]!,
      'es' => es[key] ?? en[key]!,
      _ => en[key]!,
    };
  }
}

class _ActionWrap extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final JsonInterpreter interpreter;
  final double spacing;

  const _ActionWrap({
    required this.items,
    required this.interpreter,
    required this.spacing,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final item in items)
          _buildActionButton(
            context,
            item,
            interpreter,
            _num(item['size'], 64),
          ),
      ],
    );
  }
}

class _ActionCluster extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final JsonInterpreter interpreter;
  final double size;

  const _ActionCluster({
    required this.items,
    required this.interpreter,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final bySymbol = {
      for (final item in items)
        if (item['symbol'] != null)
          item['symbol'].toString().toLowerCase(): item,
    };
    final byId = {
      for (final item in items)
        if (item['id'] != null) item['id'].toString().toLowerCase(): item,
    };
    Map<String, dynamic>? pick(String symbol, String fallbackId) {
      return bySymbol[symbol] ?? byId[fallbackId];
    }

    final buttonSize = size * 0.34;
    final center = size / 2;
    final offset = size * 0.27;
    Widget positioned(String symbol, String fallbackId, Offset buttonCenter) {
      final item = pick(symbol, fallbackId);
      if (item == null) return const SizedBox.shrink();
      return Positioned(
        left: buttonCenter.dx - buttonSize / 2,
        top: buttonCenter.dy - buttonSize / 2,
        child: _buildActionButton(context, item, interpreter, buttonSize),
      );
    }

    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          positioned('triangle', 'triangle', Offset(center, center - offset)),
          positioned('circle', 'circle', Offset(center + offset, center)),
          positioned('cross', 'cross', Offset(center, center + offset)),
          positioned('square', 'square', Offset(center - offset, center)),
        ],
      ),
    );
  }
}

class _DPad extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final JsonInterpreter interpreter;

  const _DPad({required this.items, required this.interpreter});

  @override
  Widget build(BuildContext context) {
    final byId = {
      for (final item in items)
        if (item['id'] != null) item['id'].toString(): item,
    };

    Widget button(String id, String fallback) {
      final item = byId[id];
      if (item == null) return const SizedBox.expand();
      return _PadButton(
        label: item['label']?.toString() ?? fallback,
        symbol: item['symbol']?.toString(),
        size: _num(item['size'], 42),
        backgroundColor:
            _color(item['backgroundColor']) ?? const Color(0xFF236B7A),
        foregroundColor: _color(item['color']) ?? const Color(0xFFFFFFFF),
        onDown: () => _runAction(
          interpreter,
          context,
          item['onDown'] ?? item['onPressed'],
          id,
          _eventMap(item['_downEvent']),
        ),
        onUp: () => _runAction(
          interpreter,
          context,
          item['onUp'] ?? item['onReleased'],
          id,
          _eventMap(item['_upEvent']),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              const Expanded(child: SizedBox.shrink()),
              Expanded(child: button('up', '↑')),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(child: button('left', '←')),
              const Expanded(child: SizedBox.shrink()),
              Expanded(child: button('right', '→')),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              const Expanded(child: SizedBox.shrink()),
              Expanded(child: button('down', '↓')),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _buildActionButton(
  BuildContext context,
  Map<String, dynamic> item,
  JsonInterpreter interpreter,
  double size,
) {
  return _PadButton(
    label: item['label']?.toString() ?? item['id']?.toString() ?? '',
    symbol: item['symbol']?.toString(),
    size: size,
    backgroundColor: _color(item['backgroundColor']) ?? const Color(0xFF1E222A),
    foregroundColor: _color(item['color']) ?? const Color(0xFFFFFFFF),
    onDown: () => _runAction(
      interpreter,
      context,
      item['onDown'] ?? item['onPressed'],
      item['id']?.toString(),
    ),
    onUp: () => _runAction(
      interpreter,
      context,
      item['onUp'] ?? item['onReleased'],
      item['id']?.toString(),
    ),
  );
}

class _RoundToolButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _RoundToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white, size: 22),
        onPressed: onPressed,
      ),
    );
  }
}

class _Joystick extends StatefulWidget {
  final Map<String, dynamic> spec;
  final JsonInterpreter interpreter;

  const _Joystick({required this.spec, required this.interpreter});

  @override
  State<_Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<_Joystick> {
  Offset _knob = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final baseColor =
        _color(widget.spec['backgroundColor']) ?? const Color(0xFF164B59);
    final knobColor =
        _color(widget.spec['knobColor']) ?? const Color(0xFFEAF7FF);
    final ringColor =
        _color(widget.spec['ringColor']) ?? const Color(0x66FFFFFF);
    final deadZone = _num(widget.spec['deadZone'], 0.08).clamp(0, 0.95);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        final knobSize = _num(widget.spec['knobSize'], size * 0.42);
        final radius = (size - knobSize) / 2;
        final center = Offset(size / 2, size / 2);

        void update(Offset local) {
          final raw = local - center;
          final distance = raw.distance;
          final clamped = distance > radius && distance > 0
              ? raw / distance * radius
              : raw;
          final normalized = radius <= 0 ? Offset.zero : clamped / radius;
          final strength = normalized.distance.clamp(0.0, 1.0);
          final effective = strength < deadZone ? Offset.zero : normalized;
          setState(() => _knob = effective * radius);
          _runAction(
            widget.interpreter,
            context,
            widget.spec['onChange'],
            'joystick',
            {
              'x': effective.dx,
              'y': effective.dy,
              'strength': effective.distance.clamp(0.0, 1.0),
              'angle': math.atan2(effective.dy, effective.dx),
              'direction': _directionFor(effective),
            },
          );
        }

        void reset() {
          setState(() => _knob = Offset.zero);
          _runAction(
            widget.interpreter,
            context,
            widget.spec['onEnd'] ?? widget.spec['onChange'],
            'joystick',
            const {
              'x': 0.0,
              'y': 0.0,
              'strength': 0.0,
              'angle': 0.0,
              'direction': 'center',
            },
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => update(d.localPosition),
          onTapUp: (_) => reset(),
          onTapCancel: reset,
          onPanStart: (d) => update(d.localPosition),
          onPanUpdate: (d) => update(d.localPosition),
          onPanEnd: (_) => reset(),
          onPanCancel: reset,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: baseColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: ringColor, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                ),
                Transform.translate(
                  offset: _knob,
                  child: Container(
                    width: knobSize,
                    height: knobSize,
                    decoration: BoxDecoration(
                      color: knobColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.72),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _directionFor(Offset value) {
    if (value.distance < 0.08) return 'center';
    if (value.dx.abs() > value.dy.abs()) {
      return value.dx >= 0 ? 'right' : 'left';
    }
    return value.dy >= 0 ? 'down' : 'up';
  }
}

class _PadButton extends StatelessWidget {
  final String label;
  final String? symbol;
  final double size;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onDown;
  final VoidCallback onUp;

  const _PadButton({
    required this.label,
    this.symbol,
    required this.size,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onDown,
    required this.onUp,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => onDown(),
      onTapUp: (_) => onUp(),
      onTapCancel: onUp,
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: _ButtonFace(
              label: label,
              symbol: symbol,
              color: foregroundColor,
              size: size,
            ),
          ),
        ),
      ),
    );
  }
}

class _ButtonFace extends StatelessWidget {
  final String label;
  final String? symbol;
  final Color color;
  final double size;

  const _ButtonFace({
    required this.label,
    required this.symbol,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = symbol?.trim().toLowerCase();
    if (normalized == 'triangle' ||
        normalized == 'circle' ||
        normalized == 'cross' ||
        normalized == 'square') {
      return CustomPaint(
        size: Size.square(size * 0.42),
        painter: _GamepadSymbolPainter(normalized!, color),
      );
    }
    return Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: size * 0.36,
        fontWeight: FontWeight.w800,
        height: 1,
      ),
    );
  }
}

class _GamepadSymbolPainter extends CustomPainter {
  final String symbol;
  final Color color;

  const _GamepadSymbolPainter(this.symbol, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, size.shortestSide * 0.12)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final rect = Offset.zero & size;
    switch (symbol) {
      case 'triangle':
        final path = Path()
          ..moveTo(size.width / 2, size.height * 0.08)
          ..lineTo(size.width * 0.9, size.height * 0.86)
          ..lineTo(size.width * 0.1, size.height * 0.86)
          ..close();
        canvas.drawPath(path, stroke);
        break;
      case 'circle':
        canvas.drawCircle(rect.center, size.shortestSide * 0.38, stroke);
        break;
      case 'cross':
        canvas.drawLine(
          Offset(size.width * 0.18, size.height * 0.18),
          Offset(size.width * 0.82, size.height * 0.82),
          stroke,
        );
        canvas.drawLine(
          Offset(size.width * 0.82, size.height * 0.18),
          Offset(size.width * 0.18, size.height * 0.82),
          stroke,
        );
        break;
      case 'square':
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect.deflate(size.shortestSide * 0.14),
            Radius.circular(size.shortestSide * 0.06),
          ),
          stroke,
        );
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _GamepadSymbolPainter oldDelegate) {
    return symbol != oldDelegate.symbol || color != oldDelegate.color;
  }
}

void _runAction(
  JsonInterpreter interpreter,
  BuildContext context,
  dynamic action,
  String? id, [
  Map<String, dynamic> event = const {},
]) {
  if (action is! Map<String, dynamic>) return;
  interpreter
      .executeActionWithEvent(action, context, {
        if (id != null) 'id': id,
        ...event,
      })
      .catchError((e, st) {
        debugPrint('[virtual_gamepad] action error: $e');
      });
}

List<Map<String, dynamic>> _items(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.map((k, v) => MapEntry(k.toString(), v)))
      .toList();
}

Map<String, dynamic> _eventMap(dynamic value) {
  if (value is! Map) return const {};
  return value.map((k, v) => MapEntry(k.toString(), v));
}

double _num(dynamic value, double fallback) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

Color? _color(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  var hex = value.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  return Color(parsed);
}
