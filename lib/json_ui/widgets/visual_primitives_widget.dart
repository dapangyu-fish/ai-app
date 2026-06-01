import 'dart:async';
import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

class JsonWordCloudWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final items = (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final backgroundColor = _parseColor(json['backgroundColor']?.toString());
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math
            .min(
              constraints.maxWidth.isFinite ? constraints.maxWidth : 360,
              constraints.maxHeight.isFinite ? constraints.maxHeight : 360,
            )
            .toDouble();
        return SizedBox.square(
          dimension: size,
          child: FittedBox(
            child: Container(
              width: 430,
              height: 430,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              color: backgroundColor,
              child: Stack(
                clipBehavior: Clip.none,
                children: List.generate(items.length, (index) {
                  final item = items[index];
                  final angle = index * 2.399963229728653;
                  final radius = 8 + index * 4.35;
                  final x = 215 + math.cos(angle) * radius - 45;
                  final y = 215 + math.sin(angle) * radius - 10;
                  final text = Text(
                    interpreter.resolveTemplate(item['text']?.toString() ?? ''),
                    style: TextStyle(
                      fontSize:
                          _resolveDouble(interpreter, item['fontSize']) ?? 14,
                      color:
                          _parseColor(item['color']?.toString()) ??
                          Colors.black,
                    ),
                  );
                  return Positioned(
                    left: x.clamp(0, 350).toDouble(),
                    top: y.clamp(0, 405).toDouble(),
                    child: item['rotate'] == true
                        ? RotatedBox(quarterTurns: 1, child: text)
                        : text,
                  );
                }),
              ),
            ),
          ),
        );
      },
    );
  }
}

class JsonBackdropBlurWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final borderRadius = _resolveDouble(interpreter, json['borderRadius']) ?? 0;
    final sigmaX = _resolveDouble(interpreter, json['sigmaX']) ?? 8;
    final sigmaY = _resolveDouble(interpreter, json['sigmaY']) ?? sigmaX;
    Widget child = childJson is Map<String, dynamic>
        ? interpreter.buildWidget(context, childJson)
        : const SizedBox.shrink();
    child = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigmaX, sigmaY: sigmaY),
      child: child,
    );
    if (borderRadius > 0) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: child,
      );
    }
    return child;
  }
}

class JsonAnimatedContainerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    return AnimatedContainer(
      duration: Duration(
        milliseconds: (_resolveDouble(interpreter, json['durationMs']) ?? 300)
            .toInt(),
      ),
      curve: _parseCurve(json['curve']?.toString()),
      width: _resolveDouble(interpreter, json['width']),
      height: _resolveDouble(interpreter, json['height']),
      alignment: _parseAlignment(json['alignment']?.toString()),
      decoration: BoxDecoration(
        color: _parseColor(
          json['color'] == null
              ? null
              : interpreter.resolveTemplate(json['color'].toString()),
        ),
        borderRadius: BorderRadius.circular(
          _resolveDouble(interpreter, json['borderRadius']) ?? 0,
        ),
      ),
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : null,
    );
  }
}

class JsonAnimatedVisibilityWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final visible = interpreter.resolveExpression(json['visibleWhen']) == true;
    final hiddenOffsetX =
        _resolveDouble(interpreter, json['hiddenOffsetX']) ?? 0;
    final hiddenOffsetY =
        _resolveDouble(interpreter, json['hiddenOffsetY']) ?? -1;
    return AnimatedSlide(
      offset: visible ? Offset.zero : Offset(hiddenOffsetX, hiddenOffsetY),
      duration: Duration(
        milliseconds: (_resolveDouble(interpreter, json['durationMs']) ?? 300)
            .toInt(),
      ),
      curve: _parseCurve(json['curve']?.toString()),
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: Duration(
          milliseconds: (_resolveDouble(interpreter, json['durationMs']) ?? 300)
              .toInt(),
        ),
        child: childJson is Map<String, dynamic>
            ? interpreter.buildWidget(context, childJson)
            : const SizedBox.shrink(),
      ),
    );
  }
}

class JsonAnimatedSwitcherWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final switchKey = interpreter.resolveTemplate(
      json['switchKey']?.toString() ?? '',
    );
    Widget child = childJson is Map<String, dynamic>
        ? interpreter.buildWidget(context, childJson)
        : const SizedBox.shrink();
    if (switchKey.isNotEmpty) {
      child = KeyedSubtree(key: ValueKey(switchKey), child: child);
    }
    return AnimatedSwitcher(
      duration: Duration(
        milliseconds: (_resolveDouble(interpreter, json['durationMs']) ?? 300)
            .toInt(),
      ),
      switchInCurve: _parseCurve(json['switchInCurve']?.toString()),
      switchOutCurve: _parseCurve(json['switchOutCurve']?.toString()),
      transitionBuilder: (child, animation) {
        switch (json['transitionType']?.toString()) {
          case 'slideDown':
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -1),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            );
          case 'scale':
            return ScaleTransition(scale: animation, child: child);
          case 'fade':
          default:
            return FadeTransition(opacity: animation, child: child);
        }
      },
      child: child,
    );
  }
}

class JsonOpacityWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    return Opacity(
      opacity: (_resolveDouble(interpreter, json['opacity']) ?? 1).clamp(0, 1),
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class JsonOverflowBoxWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    return OverflowBox(
      alignment:
          _parseAlignment(json['alignment']?.toString()) ?? Alignment.center,
      minWidth: _resolveDouble(interpreter, json['minWidth']) ?? 0,
      minHeight: _resolveDouble(interpreter, json['minHeight']) ?? 0,
      maxWidth:
          _resolveDouble(interpreter, json['maxWidth']) ?? double.infinity,
      maxHeight:
          _resolveDouble(interpreter, json['maxHeight']) ?? double.infinity,
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class JsonAspectRatioWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    return AspectRatio(
      aspectRatio: _resolveDouble(interpreter, json['aspectRatio']) ?? 1,
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class JsonIntervalActionWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final action = resolveActionAtBuildTime(json['action'], interpreter);
    final actionSignature = action == null ? '' : convert.jsonEncode(action);
    return _IntervalActionHost(
      intervalMs: (_resolveDouble(interpreter, json['intervalMs']) ?? 1000)
          .toInt(),
      runImmediately: json['runImmediately'] != false,
      action: action is Map<String, dynamic> ? action : null,
      actionSignature: actionSignature,
      interpreter: interpreter,
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class _IntervalActionHost extends StatefulWidget {
  final int intervalMs;
  final bool runImmediately;
  final Map<String, dynamic>? action;
  final String actionSignature;
  final JsonInterpreter interpreter;
  final Widget child;

  const _IntervalActionHost({
    required this.intervalMs,
    required this.runImmediately,
    required this.action,
    required this.actionSignature,
    required this.interpreter,
    required this.child,
  });

  @override
  State<_IntervalActionHost> createState() => _IntervalActionHostState();
}

class _IntervalActionHostState extends State<_IntervalActionHost> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _IntervalActionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.intervalMs != widget.intervalMs ||
        oldWidget.runImmediately != widget.runImmediately ||
        oldWidget.actionSignature != widget.actionSignature) {
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    if (widget.action == null || widget.intervalMs <= 0) return;
    if (widget.runImmediately) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
    _timer = Timer.periodic(
      Duration(milliseconds: widget.intervalMs),
      (_) => _run(),
    );
  }

  void _run() {
    if (!mounted || widget.action == null) return;
    widget.interpreter.executeAction(widget.action!, context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class JsonActionRegionWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final action = resolveActionAtBuildTime(json['onTap'], interpreter);
    final childJson = json['child'];
    return GestureDetector(
      onTap: action is Map<String, dynamic>
          ? () => interpreter.executeAction(action, context)
          : null,
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class JsonAnimatedPositionedWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    return AnimatedPositioned(
      duration: Duration(
        milliseconds: (_resolveDouble(interpreter, json['durationMs']) ?? 300)
            .toInt(),
      ),
      curve: _parseCurve(json['curve']?.toString()),
      left: _resolveDouble(interpreter, json['left']),
      top: _resolveDouble(interpreter, json['top']),
      right: _resolveDouble(interpreter, json['right']),
      bottom: _resolveDouble(interpreter, json['bottom']),
      width: _resolveDouble(interpreter, json['width']),
      height: _resolveDouble(interpreter, json['height']),
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class JsonWavePainterWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final height = _resolveDouble(interpreter, json['height']) ?? 100;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WavePainter(
          value: _resolveDouble(interpreter, json['value']) ?? 50,
          gradientColors: _parseColorList(json['gradientColors']),
          fillColor: _parseColor(json['fillColor']?.toString()),
          blurSigma: _resolveDouble(interpreter, json['blurSigma']) ?? 0,
          blurStyle: _parseBlurStyle(json['blurStyle']?.toString()),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double value;
  final List<Color> gradientColors;
  final Color? fillColor;
  final double blurSigma;
  final BlurStyle blurStyle;

  _WavePainter({
    required this.value,
    required this.gradientColors,
    required this.fillColor,
    required this.blurSigma,
    required this.blurStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final y1 = math.sin(value);
    final y2 = math.sin(value + math.pi / 2);
    final y3 = math.sin(value + math.pi);
    final path = Path()
      ..moveTo(0, size.height * (0.5 + 0.4 * y1))
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height * (0.5 + 0.4 * y2),
        size.width,
        size.height * (0.5 + 0.4 * y3),
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    if (gradientColors.length >= 2) {
      final paint = Paint()
        ..shader = LinearGradient(
          colors: gradientColors,
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      if (blurSigma > 0) {
        paint.maskFilter = MaskFilter.blur(blurStyle, blurSigma);
      }
      canvas.drawPath(path, paint);
    }
    if (fillColor != null) {
      final paint = Paint()..color = fillColor!;
      if (blurSigma > 0 && gradientColors.isEmpty) {
        paint.maskFilter = MaskFilter.blur(blurStyle, blurSigma);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.gradientColors != gradientColors ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.blurSigma != blurSigma ||
        oldDelegate.blurStyle != blurStyle;
  }
}

Curve _parseCurve(String? value) {
  switch (value) {
    case 'fastOutSlowIn':
      return Curves.fastOutSlowIn;
    case 'easeInOutExpo':
      return Curves.easeInOutExpo;
    case 'easeOut':
      return Curves.easeOut;
    default:
      return Curves.easeInOut;
  }
}

Alignment? _parseAlignment(String? value) {
  return switch (value) {
    'center' => Alignment.center,
    'topCenter' => Alignment.topCenter,
    'bottomCenter' => Alignment.bottomCenter,
    'centerLeft' => Alignment.centerLeft,
    'centerRight' => Alignment.centerRight,
    _ => null,
  };
}

BlurStyle _parseBlurStyle(String? value) {
  return switch (value) {
    'normal' => BlurStyle.normal,
    'outer' => BlurStyle.outer,
    'inner' => BlurStyle.inner,
    _ => BlurStyle.solid,
  };
}

List<Color> _parseColorList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((raw) => _parseColor(raw?.toString()))
      .whereType<Color>()
      .toList();
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
