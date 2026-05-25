import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonVirtualGamepadWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final height = _num(json['height'], 168);
    final background =
        _color(json['backgroundColor']) ??
        Theme.of(context).colorScheme.surface.withValues(alpha: 0.92);
    final directions = _items(json['directions']);
    final actions = _items(json['actions']);
    final mode = (json['mode'] ?? json['leftMode'] ?? 'dpad')
        .toString()
        .toLowerCase();
    final joystick = json['joystick'] is Map
        ? (json['joystick'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

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
            child: Row(
              children: [
                SizedBox(
                  width: _num(
                    mode == 'joystick'
                        ? json['joystickSize']
                        : json['dpadSize'],
                    128,
                  ),
                  height: _num(
                    mode == 'joystick'
                        ? json['joystickSize']
                        : json['dpadSize'],
                    128,
                  ),
                  child: mode == 'joystick'
                      ? _Joystick(spec: joystick, interpreter: interpreter)
                      : _DPad(items: directions, interpreter: interpreter),
                ),
                const Spacer(),
                Wrap(
                  spacing: _num(json['actionSpacing'], 12),
                  runSpacing: _num(json['actionSpacing'], 12),
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final item in actions)
                      _PadButton(
                        label:
                            item['label']?.toString() ??
                            item['id']?.toString() ??
                            '',
                        symbol: item['symbol']?.toString(),
                        size: _num(item['size'], 64),
                        backgroundColor:
                            _color(item['backgroundColor']) ??
                            const Color(0xFF1E222A),
                        foregroundColor:
                            _color(item['color']) ?? const Color(0xFFFFFFFF),
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
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
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
        ),
        onUp: () => _runAction(
          interpreter,
          context,
          item['onUp'] ?? item['onReleased'],
          id,
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
