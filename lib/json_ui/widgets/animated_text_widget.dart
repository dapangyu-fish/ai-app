import 'dart:convert' as convert;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

class JsonAnimatedTextWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final items = _parseItems(json['texts']);
    final style = json['style'] is Map<String, dynamic>
        ? json['style'] as Map<String, dynamic>
        : <String, dynamic>{};
    final width = _resolveDouble(interpreter, json['width']);
    final height = _resolveDouble(interpreter, json['height']);
    final action =
        resolveActionAtBuildTime(json['onTap'], interpreter)
            as Map<String, dynamic>?;
    final signature = convert.jsonEncode(<String, dynamic>{
      'effect': json['effect'],
      'texts': json['texts'],
      'durationMs': json['durationMs'],
      'itemDurationMs': json['itemDurationMs'],
      'cursor': json['cursor'],
    });

    return _AnimatedTextHost(
      items: items,
      effect: json['effect']?.toString() ?? 'fade',
      style: style,
      width: width,
      height: height,
      itemDurationMs:
          (_resolveDouble(interpreter, json['itemDurationMs']) ?? 1600)
              .toInt(),
      totalDurationMs: _resolveDouble(interpreter, json['durationMs'])?.toInt(),
      cursor: json['cursor']?.toString() ?? '',
      colors: _parseColorList(json['colors']),
      action: action,
      actionSignature: signature,
      interpreter: interpreter,
    );
  }

  List<_AnimatedTextItem> _parseItems(dynamic raw) {
    final values = raw is List ? raw : const [];
    return values.map((value) {
      if (value is Map) {
        final map = value.map((key, value) => MapEntry('$key', value));
        return _AnimatedTextItem(
          text: map['text']?.toString() ?? '',
          effect: map['effect']?.toString(),
          cursor: map['cursor']?.toString(),
          style: map['style'] is Map<String, dynamic>
              ? map['style'] as Map<String, dynamic>
              : null,
          durationMs: (map['durationMs'] as num?)?.toInt(),
        );
      }
      return _AnimatedTextItem(text: value.toString());
    }).where((item) => item.text.isNotEmpty).toList();
  }
}

class _AnimatedTextItem {
  final String text;
  final String? effect;
  final String? cursor;
  final Map<String, dynamic>? style;
  final int? durationMs;

  const _AnimatedTextItem({
    required this.text,
    this.effect,
    this.cursor,
    this.style,
    this.durationMs,
  });
}

class _AnimatedTextHost extends StatefulWidget {
  final List<_AnimatedTextItem> items;
  final String effect;
  final Map<String, dynamic> style;
  final double? width;
  final double? height;
  final int itemDurationMs;
  final int? totalDurationMs;
  final String cursor;
  final List<Color> colors;
  final Map<String, dynamic>? action;
  final String actionSignature;
  final JsonInterpreter interpreter;

  const _AnimatedTextHost({
    required this.items,
    required this.effect,
    required this.style,
    required this.width,
    required this.height,
    required this.itemDurationMs,
    required this.totalDurationMs,
    required this.cursor,
    required this.colors,
    required this.action,
    required this.actionSignature,
    required this.interpreter,
  });

  @override
  State<_AnimatedTextHost> createState() => _AnimatedTextHostState();
}

class _AnimatedTextHostState extends State<_AnimatedTextHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _duration(),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant _AnimatedTextHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actionSignature != widget.actionSignature ||
        oldWidget.items.length != widget.items.length) {
      _controller.duration = _duration();
      if (!_controller.isAnimating) _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Duration _duration() {
    final itemCount = math.max(widget.items.length, 1);
    return Duration(
      milliseconds: math.max(
        120,
        widget.totalDurationMs ?? widget.itemDurationMs * itemCount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    Widget content = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final phase = _phase();
        final item = widget.items[phase.index];
        final effect = (item.effect ?? widget.effect).toLowerCase();
        final style = _textStyle(
          widget.style,
          item.style,
          fallbackColor: effect == 'colorize' ? null : Colors.white,
        );
        final cursor = item.cursor ?? widget.cursor;
        return switch (effect) {
          'rotate' => _rotateText(item.text, style, phase.local),
          'typer' => _typingText(item.text, style, phase.local, ''),
          'typewriter' => _typingText(item.text, style, phase.local, cursor),
          'scale' => _scaleText(item.text, style, phase.local),
          'colorize' => _colorizeText(item.text, style, phase.local),
          'liquid' => _liquidText(item.text, style, phase.local),
          'wavy' => _wavyText(item.text, style, phase.local),
          _ => _fadeText(item.text, style, phase.local),
        };
      },
    );

    if (widget.width != null || widget.height != null) {
      content = SizedBox(width: widget.width, height: widget.height, child: content);
    }
    if (widget.action == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.interpreter.executeAction(widget.action!, context),
      child: content,
    );
  }

  _AnimatedTextPhase _phase() {
    final itemCount = widget.items.length;
    final scaled = _controller.value * itemCount;
    final index = scaled.floor().clamp(0, itemCount - 1);
    return _AnimatedTextPhase(index: index, local: scaled - index);
  }

  Widget _fadeText(String text, TextStyle style, double local) {
    final opacity = math.sin(local * math.pi).clamp(0.0, 1.0);
    return Center(
      child: Opacity(
        opacity: opacity,
        child: Text(text, textAlign: TextAlign.center, style: style),
      ),
    );
  }

  Widget _rotateText(String text, TextStyle style, double local) {
    final entering = local < 0.5;
    final t = entering ? local * 2 : (local - 0.5) * 2;
    final angle = entering ? (1 - t) * math.pi / 2 : -t * math.pi / 2;
    return Center(
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateX(angle),
        child: Opacity(
          opacity: math.sin(local * math.pi).clamp(0.0, 1.0),
          child: Text(text, textAlign: TextAlign.center, style: style),
        ),
      ),
    );
  }

  Widget _typingText(
    String text,
    TextStyle style,
    double local,
    String cursor,
  ) {
    final visible = math.max(1, (text.length * local).ceil());
    final clipped = text.substring(0, visible.clamp(0, text.length));
    return Center(
      child: Text(
        '$clipped$cursor',
        textAlign: TextAlign.center,
        style: style,
      ),
    );
  }

  Widget _scaleText(String text, TextStyle style, double local) {
    final scale = 0.65 + math.sin(local * math.pi).clamp(0.0, 1.0) * 0.5;
    return Center(
      child: Transform.scale(
        scale: scale,
        child: Opacity(
          opacity: math.sin(local * math.pi).clamp(0.0, 1.0),
          child: Text(text, textAlign: TextAlign.center, style: style),
        ),
      ),
    );
  }

  Widget _colorizeText(String text, TextStyle style, double local) {
    final colors = widget.colors.isEmpty
        ? const [Colors.purple, Colors.blue, Colors.yellow, Colors.red]
        : widget.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : 280.0;
        final offset = local * width;
        return Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: style.copyWith(
              foreground: Paint()
                ..shader = LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: colors,
                  tileMode: TileMode.mirror,
                ).createShader(Rect.fromLTWH(-offset, 0, width, 80)),
            ),
          ),
        );
      },
    );
  }

  Widget _liquidText(String text, TextStyle style, double local) {
    return Container(
      color: Colors.redAccent,
      alignment: Alignment.center,
      child: ShaderMask(
        shaderCallback: (bounds) {
          final fill = (0.15 + local * 0.85).clamp(0.0, 1.0);
          return LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: const [Colors.blueAccent, Colors.blueAccent, Colors.white],
            stops: [0, fill, fill],
          ).createShader(bounds);
        },
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: style.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _wavyText(String text, TextStyle style, double local) {
    final chars = text.characters.toList();
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < chars.length; i++)
            Transform.translate(
              offset: Offset(
                0,
                math.sin(local * math.pi * 2 + i * 0.75) * 8,
              ),
              child: Text(chars[i], style: style),
            ),
        ],
      ),
    );
  }

  TextStyle _textStyle(
    Map<String, dynamic> base,
    Map<String, dynamic>? itemStyle, {
    Color? fallbackColor,
  }) {
    final merged = <String, dynamic>{...base, ...?itemStyle};
    return TextStyle(
      fontSize: _num(merged['fontSize']) ?? 32,
      fontWeight: _fontWeight(merged['fontWeight']?.toString()),
      color: _parseColor(merged['color']?.toString()) ?? fallbackColor,
      decoration: merged['decoration'] == 'underline'
          ? TextDecoration.underline
          : TextDecoration.none,
      fontFamily: merged['fontFamily']?.toString(),
    );
  }
}

class _AnimatedTextPhase {
  final int index;
  final double local;

  const _AnimatedTextPhase({required this.index, required this.local});
}

List<Color> _parseColorList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((value) => _parseColor(value?.toString()))
      .whereType<Color>()
      .toList();
}

Color? _parseColor(String? colorStr) {
  if (colorStr == null || !colorStr.startsWith('#')) return null;
  final hex = colorStr.replaceFirst('#', '');
  if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
  if (hex.length == 8) return Color(int.parse(hex, radix: 16));
  return null;
}

FontWeight _fontWeight(String? value) {
  return switch (value) {
    'bold' => FontWeight.bold,
    'w100' => FontWeight.w100,
    'w200' => FontWeight.w200,
    'w300' => FontWeight.w300,
    'w500' => FontWeight.w500,
    'w600' => FontWeight.w600,
    'w700' => FontWeight.w700,
    'w800' => FontWeight.w800,
    'w900' => FontWeight.w900,
    _ => FontWeight.normal,
  };
}

double? _num(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final resolved = interpreter.resolveExpression(value);
  if (resolved is num) return resolved.toDouble();
  return double.tryParse(resolved?.toString() ?? '');
}
