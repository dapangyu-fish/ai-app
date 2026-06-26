import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonAnalogStickWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final spec = json.map((k, v) => MapEntry(k.toString(), v));
    return _AnalogStick(spec: spec, interpreter: interpreter);
  }
}

class _AnalogStick extends StatefulWidget {
  final Map<String, dynamic> spec;
  final JsonInterpreter interpreter;

  const _AnalogStick({required this.spec, required this.interpreter});

  @override
  State<_AnalogStick> createState() => _AnalogStickState();
}

class _AnalogStickState extends State<_AnalogStick> {
  Offset _knob = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final baseColor =
        _color(widget.spec['backgroundColor']) ?? const Color(0x66164B59);
    final knobColor =
        _color(widget.spec['knobColor']) ?? const Color(0xCCEAF7FF);
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
          _runAction(widget.interpreter, context, widget.spec['onChange'], {
            'x': effective.dx,
            'y': effective.dy,
            'strength': effective.distance.clamp(0.0, 1.0),
            'angle': math.atan2(effective.dy, effective.dx),
            'direction': _directionFor(effective),
          });
        }

        void reset() {
          setState(() => _knob = Offset.zero);
          _runAction(
            widget.interpreter,
            context,
            widget.spec['onEnd'] ?? widget.spec['onChange'],
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

void _runAction(
  JsonInterpreter interpreter,
  BuildContext context,
  dynamic action,
  Map<String, dynamic> event,
) {
  if (action is! Map<String, dynamic>) return;
  interpreter.executeActionWithEvent(action, context, event).catchError((
    e,
    st,
  ) {
    debugPrint('[analog_stick] action error: $e');
  });
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
