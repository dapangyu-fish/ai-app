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
                  width: _num(json['dpadSize'], 128),
                  height: _num(json['dpadSize'], 128),
                  child: _DPad(items: directions, interpreter: interpreter),
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
                        size: _num(item['size'], 64),
                        backgroundColor:
                            _color(item['backgroundColor']) ??
                            const Color(0xFFE95656),
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

class _PadButton extends StatelessWidget {
  final String label;
  final double size;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onDown;
  final VoidCallback onUp;

  const _PadButton({
    required this.label,
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
            borderRadius: BorderRadius.circular(size / 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: foregroundColor,
                fontSize: size * 0.36,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _runAction(
  JsonInterpreter interpreter,
  BuildContext context,
  dynamic action,
  String? id,
) {
  if (action is! Map<String, dynamic>) return;
  interpreter
      .executeActionWithEvent(action, context, {if (id != null) 'id': id})
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
