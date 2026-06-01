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

class JsonParticleBurstButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final action = resolveActionAtBuildTime(json['onTap'], interpreter);
    return _ParticleBurstButton(
      size: _resolveDouble(interpreter, json['size']) ?? 300,
      color: _parseColor(json['color']?.toString()) ?? Colors.yellow,
      particleCount: (_resolveDouble(interpreter, json['particleCount']) ?? 30)
          .toInt(),
      durationMs: (_resolveDouble(interpreter, json['durationMs']) ?? 500)
          .toInt(),
      shape: json['shape']?.toString() ?? 'star',
      action: action is Map<String, dynamic> ? action : null,
      interpreter: interpreter,
    );
  }
}

class _ParticleBurstButton extends StatefulWidget {
  final double size;
  final Color color;
  final int particleCount;
  final int durationMs;
  final String shape;
  final Map<String, dynamic>? action;
  final JsonInterpreter interpreter;

  const _ParticleBurstButton({
    required this.size,
    required this.color,
    required this.particleCount,
    required this.durationMs,
    required this.shape,
    required this.action,
    required this.interpreter,
  });

  @override
  State<_ParticleBurstButton> createState() => _ParticleBurstButtonState();
}

class _ParticleBurstButtonState extends State<_ParticleBurstButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _exploding = false;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: Duration(milliseconds: widget.durationMs),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _exploding = false);
          }
        });
  }

  @override
  void didUpdateWidget(covariant _ParticleBurstButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.durationMs != widget.durationMs) {
      _controller.duration = Duration(milliseconds: widget.durationMs);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _tap() {
    if (!_exploding) {
      setState(() => _exploding = true);
      _controller.forward(from: 0);
    }
    final action = widget.action;
    if (action != null) {
      widget.interpreter.executeAction(action, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _tap,
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(
              painter: _ParticleBurstPainter(
                value: _controller.value,
                exploding: _exploding,
                color: widget.color,
                particleCount: widget.particleCount,
                shape: widget.shape,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ParticleBurstPainter extends CustomPainter {
  final double value;
  final bool exploding;
  final Color color;
  final int particleCount;
  final String shape;

  _ParticleBurstPainter({
    required this.value,
    required this.exploding,
    required this.color,
    required this.particleCount,
    required this.shape,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    if (exploding) {
      final count = math.max(1, particleCount);
      final particleSize = side * 0.4 / 30;
      for (var i = 0; i < count; i++) {
        final angle = -math.pi / 2 + i * math.pi * 2 / count;
        final wave = math.sin(i * 12.9898) * 0.5 + 0.5;
        final radius = side * (0.08 + 0.32 * value) * (0.7 + wave * 0.6);
        final opacity = (1 - value).clamp(0.0, 1.0);
        paint.color = color.withValues(alpha: opacity);
        canvas.drawCircle(
          center + Offset(math.cos(angle) * radius, math.sin(angle) * radius),
          particleSize * (1 + value),
          paint,
        );
      }
      return;
    }

    if (shape == 'circle') {
      canvas.drawCircle(center, side * 0.18, paint);
      return;
    }
    canvas.drawPath(_starPath(center, side * 0.2, side * 0.08), paint);
  }

  Path _starPath(Offset center, double outerRadius, double innerRadius) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? outerRadius : innerRadius;
      final angle = -math.pi / 2 + i * math.pi / 5;
      final point =
          center + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant _ParticleBurstPainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.exploding != exploding ||
        oldDelegate.color != color ||
        oldDelegate.particleCount != particleCount ||
        oldDelegate.shape != shape;
  }
}

class JsonGesturePasswordWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final action = resolveActionAtBuildTime(json['onDone'], interpreter);
    return _GesturePasswordPad(
      size: _resolveDouble(interpreter, json['size']) ?? 300,
      frameRadius: _resolveDouble(interpreter, json['frameRadius']) ?? 30,
      pointRadius: _resolveDouble(interpreter, json['pointRadius']) ?? 10,
      pathWidth: _resolveDouble(interpreter, json['pathWidth']) ?? 6,
      color: _parseColor(json['color']?.toString()) ?? Colors.grey,
      highlightColor:
          _parseColor(json['highlightColor']?.toString()) ?? Colors.blue,
      pathColor: _parseColor(json['pathColor']?.toString()) ?? Colors.blue,
      action: action is Map<String, dynamic> ? action : null,
      interpreter: interpreter,
    );
  }
}

class _GesturePasswordPad extends StatefulWidget {
  final double size;
  final double frameRadius;
  final double pointRadius;
  final double pathWidth;
  final Color color;
  final Color highlightColor;
  final Color pathColor;
  final Map<String, dynamic>? action;
  final JsonInterpreter interpreter;

  const _GesturePasswordPad({
    required this.size,
    required this.frameRadius,
    required this.pointRadius,
    required this.pathWidth,
    required this.color,
    required this.highlightColor,
    required this.pathColor,
    required this.action,
    required this.interpreter,
  });

  @override
  State<_GesturePasswordPad> createState() => _GesturePasswordPadState();
}

class _GesturePasswordPadState extends State<_GesturePasswordPad> {
  final List<int> _selected = [];
  Offset? _moving;

  List<Offset> _centers(Size size) {
    final cell = size.width / 3;
    return List.generate(9, (index) {
      final row = index ~/ 3;
      final col = index % 3;
      return Offset(col * cell + cell / 2, row * cell + cell / 2);
    });
  }

  void _trySelect(Offset position, Size size) {
    final centers = _centers(size);
    for (var i = 0; i < centers.length; i++) {
      if (_selected.contains(i)) continue;
      if ((position - centers[i]).distance <= widget.frameRadius) {
        setState(() => _selected.add(i));
        return;
      }
    }
  }

  void _finish() {
    final password = _selected.join();
    final action = widget.action;
    if (action != null) {
      widget.interpreter.executeActionWithEvent(action, context, {
        'password': password,
        'sequence': List<int>.from(_selected),
      });
    }
    setState(() {
      _selected.clear();
      _moving = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.min(constraints.maxWidth, constraints.maxHeight);
          final size = Size.square(side.isFinite ? side : widget.size);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (details) => _trySelect(details.localPosition, size),
            onPanUpdate: (details) {
              _trySelect(details.localPosition, size);
              setState(() => _moving = details.localPosition);
            },
            onPanEnd: (_) => _finish(),
            onPanCancel: _finish,
            child: CustomPaint(
              size: size,
              painter: _GesturePasswordPainter(
                centers: _centers(size),
                selected: List<int>.from(_selected),
                moving: _moving,
                frameRadius: widget.frameRadius,
                pointRadius: widget.pointRadius,
                pathWidth: widget.pathWidth,
                color: widget.color,
                highlightColor: widget.highlightColor,
                pathColor: widget.pathColor,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GesturePasswordPainter extends CustomPainter {
  final List<Offset> centers;
  final List<int> selected;
  final Offset? moving;
  final double frameRadius;
  final double pointRadius;
  final double pathWidth;
  final Color color;
  final Color highlightColor;
  final Color pathColor;

  _GesturePasswordPainter({
    required this.centers,
    required this.selected,
    required this.moving,
    required this.frameRadius,
    required this.pointRadius,
    required this.pathWidth,
    required this.color,
    required this.highlightColor,
    required this.pathColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pathPaint = Paint()
      ..color = pathColor
      ..strokeWidth = pathWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    if (selected.length > 1) {
      for (var i = 0; i < selected.length - 1; i++) {
        canvas.drawLine(
          centers[selected[i]],
          centers[selected[i + 1]],
          pathPaint,
        );
      }
    }
    if (selected.isNotEmpty && moving != null) {
      canvas.drawLine(centers[selected.last], moving!, pathPaint);
    }

    final fill = Paint()..isAntiAlias = true;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..isAntiAlias = true;
    for (var i = 0; i < centers.length; i++) {
      final active = selected.contains(i);
      fill.color = active ? highlightColor : color;
      stroke.color = active ? highlightColor : color;
      canvas.drawCircle(centers[i], frameRadius, stroke);
      canvas.drawCircle(centers[i], pointRadius, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _GesturePasswordPainter oldDelegate) {
    return oldDelegate.centers != centers ||
        oldDelegate.selected != selected ||
        oldDelegate.moving != moving ||
        oldDelegate.frameRadius != frameRadius ||
        oldDelegate.pointRadius != pointRadius ||
        oldDelegate.pathWidth != pathWidth ||
        oldDelegate.color != color ||
        oldDelegate.highlightColor != highlightColor ||
        oldDelegate.pathColor != pathColor;
  }
}

class JsonProceduralVisualWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final mode =
        interpreter.resolveExpression(json['mode'])?.toString() ??
        json['mode']?.toString() ??
        'galaxy';
    return _ProceduralVisual(
      mode: mode,
      particleCount:
          (_resolveDouble(interpreter, json['particleCount']) ?? 1200).toInt(),
      pointSize: _resolveDouble(interpreter, json['pointSize']) ?? 1.6,
      speed: _resolveDouble(interpreter, json['speed']) ?? 1,
      primary:
          _parseColor(json['color']?.toString()) ?? const Color(0xFFFFFFFF),
      secondary:
          _parseColor(json['secondaryColor']?.toString()) ??
          const Color(0xFF00E5FF),
      background:
          _parseColor(json['backgroundColor']?.toString()) ?? Colors.black,
    );
  }
}

class _ProceduralVisual extends StatefulWidget {
  final String mode;
  final int particleCount;
  final double pointSize;
  final double speed;
  final Color primary;
  final Color secondary;
  final Color background;

  const _ProceduralVisual({
    required this.mode,
    required this.particleCount,
    required this.pointSize,
    required this.speed,
    required this.primary,
    required this.secondary,
    required this.background,
  });

  @override
  State<_ProceduralVisual> createState() => _ProceduralVisualState();
}

class _ProceduralVisualState extends State<_ProceduralVisual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Offset? _touch;
  double _pulse = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setTouch(Offset position) {
    setState(() {
      _touch = position;
      _pulse = (_pulse + 0.35).clamp(0, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _setTouch(details.localPosition),
      onPanStart: (details) => _setTouch(details.localPosition),
      onPanUpdate: (details) => _setTouch(details.localPosition),
      onPanEnd: (_) => setState(() => _touch = null),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final pulse = _pulse;
          _pulse = math.max(0, _pulse - 0.015);
          return CustomPaint(
            painter: _ProceduralVisualPainter(
              mode: widget.mode,
              time: _controller.value * math.pi * 2 * widget.speed,
              particleCount: widget.particleCount.clamp(80, 6000),
              pointSize: widget.pointSize,
              primary: widget.primary,
              secondary: widget.secondary,
              background: widget.background,
              touch: _touch,
              pulse: pulse,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _ProceduralVisualPainter extends CustomPainter {
  final String mode;
  final double time;
  final int particleCount;
  final double pointSize;
  final Color primary;
  final Color secondary;
  final Color background;
  final Offset? touch;
  final double pulse;

  _ProceduralVisualPainter({
    required this.mode,
    required this.time,
    required this.particleCount,
    required this.pointSize,
    required this.primary,
    required this.secondary,
    required this.background,
    required this.touch,
    required this.pulse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(background, BlendMode.src);
    switch (mode) {
      case 'fibonacciSphere':
        _drawFibonacciSphere(canvas, size);
        break;
      case 'attractor':
        _drawAttractor(canvas, size);
        break;
      case 'radialLines':
        _drawRadialLines(canvas, size);
        break;
      case 'blackHoleDisk':
        _drawBlackHoleDisk(canvas, size);
        break;
      case 'taiChiParticles':
        _drawTaiChi(canvas, size);
        break;
      case 'boomParticles':
        _drawBoom(canvas, size);
        break;
      case 'discoSphere':
        _drawDiscoSphere(canvas, size);
        break;
      case 'spatialGrid':
        _drawSpatialGrid(canvas, size);
        break;
      case 'fire':
        _drawFire(canvas, size);
        break;
      case 'particleTree':
        _drawParticleTree(canvas, size);
        break;
      case 'mosaicScanner':
        _drawMosaicScanner(canvas, size);
        break;
      case 'koiFish':
        _drawKoiFish(canvas, size);
        break;
      case 'shockwave':
        _drawShockwave(canvas, size);
        break;
      case 'jawControl':
        _drawJawControl(canvas, size);
        break;
      case 'galaxy':
      default:
        _drawGalaxy(canvas, size);
        break;
    }
  }

  void _drawFibonacciSphere(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.36);
    final radius = math.min(size.width, size.height) * 0.36;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = pointSize;
    const goldenAngle = math.pi * (3 - 2.23606797749979);
    for (var i = 0; i < particleCount; i++) {
      final y = 1 - (i / (particleCount - 1)) * 2;
      final r = math.sqrt(math.max(0, 1 - y * y));
      final theta = goldenAngle * i;
      final x = math.cos(theta) * r;
      final z = math.sin(theta) * r;
      final rotX = x * math.cos(time * 0.4) - z * math.sin(time * 0.4);
      final rotZ = x * math.sin(time * 0.4) + z * math.cos(time * 0.4);
      final perspective = 720 / (720 - rotZ * radius);
      final alpha = ((rotZ + 1) / 2).clamp(0.18, 1.0);
      paint.color = Color.lerp(
        secondary,
        primary,
        alpha,
      )!.withValues(alpha: alpha);
      canvas.drawCircle(
        Offset(
          center.dx + rotX * radius * perspective,
          center.dy + y * radius * perspective,
        ),
        pointSize * perspective,
        paint,
      );
    }
  }

  void _drawAttractor(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = math.min(size.width, size.height) * 0.18;
    final paint = Paint()
      ..color = secondary.withValues(alpha: 0.65)
      ..strokeWidth = pointSize
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.plus;
    final points = <Offset>[];
    for (var i = 0; i < particleCount; i++) {
      final t = i * 0.018 + time * 0.3;
      final x = math.sin(t * 1.7) * math.cos(t * 0.41) * 2.1;
      final y = math.sin(t * 1.13 + math.sin(t * 0.23)) * 2.0;
      final z = math.cos(t * 0.71) * 1.3;
      final rx = x * math.cos(time * 0.3) - z * math.sin(time * 0.3);
      points.add(center + Offset(rx * scale, y * scale));
    }
    canvas.drawPoints(PointMode.points, points, paint);
    _drawTitle(canvas, size, 'HALVORSEN', primary);
  }

  void _drawGalaxy(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) * 0.43;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = pointSize
      ..blendMode = BlendMode.plus;
    for (var i = 0; i < particleCount; i++) {
      final f = i / particleCount;
      final arm = i % 2 == 0 ? 0 : math.pi;
      final wobble = math.sin(i * 12.9898) * 0.08;
      final r = math.sqrt(f) * maxR;
      final angle = arm + f * 7.5 + time * (0.08 + f * 0.1) + wobble;
      final alpha = (1 - f).clamp(0.15, 0.9);
      paint.color = Color.lerp(primary, secondary, f)!.withValues(alpha: alpha);
      canvas.drawCircle(
        center + Offset(math.cos(angle) * r, math.sin(angle) * r * 0.58),
        pointSize * (1.2 - f * 0.5),
        paint,
      );
    }
    final core = Paint()
      ..shader = RadialGradient(
        colors: [
          primary.withValues(alpha: 0.8),
          secondary.withValues(alpha: 0.25),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: maxR * 0.35))
      ..blendMode = BlendMode.plus;
    canvas.drawCircle(center, maxR * 0.35, core);
  }

  void _drawRadialLines(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    List<Offset>? prev;
    for (var layer = 1; layer < 180; layer++) {
      final r = layer * math.min(size.width, size.height) / 360;
      final a = time * 0.2 + layer * 0.09;
      final vertices = List.generate(8, (i) {
        final angle = i * math.pi / 4 + a + math.sin(layer * 0.05 + time) * 0.8;
        return center + Offset(math.cos(angle) * r, math.sin(angle) * r);
      });
      final v = (239 * (1 - layer / 180) + 39 * layer / 180).toInt();
      paint.color = Color.fromARGB(255, v, v, v);
      if (prev != null) {
        for (var i = 0; i < vertices.length; i++) {
          canvas.drawLine(prev[i], vertices[i], paint);
        }
      }
      prev = vertices;
    }
  }

  void _drawBlackHoleDisk(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final base = math.min(size.width, size.height) * 0.12;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = pointSize
      ..blendMode = BlendMode.plus;
    for (var i = 0; i < particleCount; i++) {
      final f = i / particleCount;
      final r = base * (1.6 + math.sqrt(f) * 5.4);
      final theta = i * 2.399963 + time * (2.8 / math.sqrt(r / base));
      final y = math.sin(theta) * r * 0.34;
      final x = math.cos(theta) * r;
      final hot = (1 - f).clamp(0.0, 1.0);
      final color = hot > 0.7
          ? Colors.white
          : Color.lerp(const Color(0xFFFFD180), const Color(0xFFFF3D00), f)!;
      paint.color = color.withValues(alpha: 0.55 + hot * 0.3);
      canvas.drawCircle(
        center + Offset(x, y),
        pointSize * (1.4 - f * 0.6),
        paint,
      );
    }
    canvas.drawCircle(center, base * 1.45, Paint()..color = Colors.black);
  }

  void _drawTaiChi(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.43;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = pointSize
      ..blendMode = BlendMode.plus;
    final points = <Offset>[];
    for (var i = 0; i < particleCount; i++) {
      final rnd = math.sin(i * 78.233) * 43758.5453;
      final frac = rnd - rnd.floorToDouble();
      final r = math.sqrt(frac) * 1.02;
      final angle = i * 2.399963 + time * 0.16;
      final x = math.cos(angle) * r;
      final y = math.sin(angle) * r;
      final top = math.sqrt(x * x + (y - 0.5) * (y - 0.5));
      final bottom = math.sqrt(x * x + (y + 0.5) * (y + 0.5));
      var bright = x > 0 ? 1.0 : 0.08;
      if (top < 0.5) bright = 1.0;
      if (bottom < 0.5) bright = 0.08;
      if (top < 0.13) bright = 0.06;
      if (bottom < 0.13) bright = 1.0;
      if (bright > 0.2) points.add(center + Offset(x * radius, y * radius));
    }
    paint.color = primary.withValues(alpha: 0.75);
    canvas.drawPoints(PointMode.points, points, paint);
  }

  void _drawBoom(Canvas canvas, Size size) {
    final center = touch ?? Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = pointSize
      ..blendMode = BlendMode.plus;
    for (var i = 0; i < particleCount; i++) {
      final f = i / particleCount;
      final angle = i * 2.399963 + time * 0.8;
      final orbit = math.min(size.width, size.height) * (0.08 + 0.32 * f);
      final burst = pulse * math.min(size.width, size.height) * 0.2;
      final x = math.cos(angle) * (orbit + burst * math.sin(i));
      final y = math.sin(angle * 1.7) * (orbit * 0.6 + burst * math.cos(i));
      paint.color = secondary.withValues(alpha: 0.25 + 0.55 * (1 - f));
      canvas.drawCircle(center + Offset(x, y), pointSize, paint);
    }
  }

  void _drawDiscoSphere(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.43);
    final radius = math.min(size.width, size.height) * 0.34;
    final paint = Paint()..blendMode = BlendMode.plus;
    const goldenAngle = math.pi * (3 - 2.23606797749979);
    for (var i = 0; i < particleCount; i++) {
      final y = 1 - (i / (particleCount - 1)) * 2;
      final r = math.sqrt(math.max(0, 1 - y * y));
      final theta = goldenAngle * i;
      final x = math.cos(theta) * r;
      final z = math.sin(theta) * r;
      final rx = x * math.cos(time * 0.35) - z * math.sin(time * 0.35);
      final rz = x * math.sin(time * 0.35) + z * math.cos(time * 0.35);
      if (rz < -0.7) continue;
      final hue = (i * 37 + time * 80) % 360;
      paint.color = HSVColor.fromAHSV(
        0.35 + rz.clamp(0, 1) * 0.55,
        hue.toDouble(),
        0.85,
        1,
      ).toColor();
      final p = center + Offset(rx * radius, y * radius);
      canvas.drawRect(
        Rect.fromCenter(center: p, width: pointSize * 4, height: pointSize * 4),
        paint,
      );
    }
  }

  void _drawSpatialGrid(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.52);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = secondary.withValues(alpha: 0.55)
      ..blendMode = BlendMode.plus;
    for (var z = 1; z < 26; z++) {
      final depth = z / 26;
      final y = center.dy + 260 * (1 - depth) + math.sin(time + z) * 3;
      final half = size.width * (0.08 + depth * 0.55);
      final alpha = (1 - depth).clamp(0.05, 0.8);
      paint.color = secondary.withValues(alpha: alpha);
      canvas.drawLine(
        Offset(center.dx - half, y),
        Offset(center.dx + half, y),
        paint,
      );
    }
    for (var i = -9; i <= 9; i++) {
      final x0 = center.dx + i * 12.0;
      final x1 = center.dx + i * 42.0;
      paint.color = primary.withValues(alpha: 0.25);
      canvas.drawLine(
        Offset(x0, center.dy + 260),
        Offset(x1, center.dy - 220),
        paint,
      );
    }
  }

  void _drawFire(Canvas canvas, Size size) {
    final paint = Paint()..blendMode = BlendMode.plus;
    for (var i = 0; i < particleCount; i++) {
      final f = i / particleCount;
      final seed = math.sin(i * 91.345) * 43758.5453;
      final xSeed = seed - seed.floorToDouble();
      final y = size.height * (0.92 - f * 0.78);
      final width = size.width * (0.35 * (1 - f) + 0.04);
      final x =
          size.width / 2 +
          (xSeed - 0.5) * width +
          math.sin(time * 2 + i * 0.05) * 18 * (1 - f);
      final hot = 1 - f;
      paint.color = Color.lerp(
        const Color(0xFFFFF59D),
        const Color(0xFFFF3D00),
        f,
      )!.withValues(alpha: 0.08 + hot * 0.55);
      canvas.drawCircle(Offset(x, y), pointSize * (1.2 + hot * 2.4), paint);
    }
  }

  void _drawParticleTree(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.58);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = pointSize
      ..blendMode = BlendMode.plus;
    for (var i = 0; i < particleCount; i++) {
      final f = i / particleCount;
      final h = f * 1.8 - 0.9;
      final radius = (1 - f) * math.min(size.width, size.height) * 0.28;
      final angle = i * 2.399963 + time * 0.3;
      final x = math.cos(angle) * radius;
      final y = -h * math.min(size.width, size.height) * 0.33;
      paint.color = Color.lerp(
        const Color(0xFF00E676),
        const Color(0xFFFFFFFF),
        f,
      )!.withValues(alpha: 0.55);
      canvas.drawCircle(
        center + Offset(x, y),
        pointSize * (1.4 - f * 0.5),
        paint,
      );
    }
    _drawTitle(canvas, size, '*', const Color(0xFFFFF176));
  }

  void _drawMosaicScanner(Canvas canvas, Size size) {
    final cell = math.max(10.0, size.width / 22);
    final scanY = (time * 80) % (size.height + cell * 4) - cell * 2;
    final paint = Paint();
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        final v =
            (math.sin(x * 0.03 + time) + math.cos(y * 0.04 - time)) * 0.5 + 0.5;
        final nearScan = (y - scanY).abs() < cell * 2;
        paint.color = Color.lerp(
          primary,
          secondary,
          v,
        )!.withValues(alpha: nearScan ? 0.85 : 0.25);
        canvas.drawRect(Rect.fromLTWH(x + 1, y + 1, cell - 2, cell - 2), paint);
      }
    }
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = secondary;
    canvas.drawLine(Offset(0, scanY), Offset(size.width, scanY), paint);
  }

  void _drawKoiFish(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.plus;
    for (var fish = 0; fish < 3; fish++) {
      final baseAngle = time * (0.25 + fish * 0.08) + fish * math.pi * 2 / 3;
      final orbit = math.min(size.width, size.height) * (0.18 + fish * 0.06);
      final head =
          center +
          Offset(math.cos(baseAngle) * orbit, math.sin(baseAngle) * orbit);
      for (var i = 0; i < 90; i++) {
        final t = i / 90;
        final bend = math.sin(t * math.pi * 2 + time * 2 + fish) * 12;
        final dir = baseAngle + math.pi + bend * 0.01;
        final p =
            head +
            Offset(math.cos(dir) * t * 92, math.sin(dir) * t * 34 + bend * t);
        paint.color = Color.lerp(
          const Color(0xFFFFF8E1),
          const Color(0xFFFF7043),
          t,
        )!.withValues(alpha: 0.75 * (1 - t * 0.45));
        canvas.drawCircle(p, pointSize * (4 - t * 2.2), paint);
      }
    }
  }

  void _drawShockwave(Canvas canvas, Size size) {
    final center = touch ?? Offset(size.width / 2, size.height * 0.62);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..blendMode = BlendMode.plus;
    for (var i = 0; i < 8; i++) {
      final r = ((time * 80 + i * 44) % 360).toDouble();
      paint.color = secondary.withValues(alpha: (1 - r / 360).clamp(0, 0.65));
      canvas.drawCircle(center, r, paint);
    }
  }

  void _drawJawControl(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.52);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = primary;
    final open = 0.35 + 0.25 * math.sin(time * 2);
    final jaw = Path()
      ..moveTo(center.dx - 88, center.dy)
      ..quadraticBezierTo(
        center.dx,
        center.dy + 86 + open * 80,
        center.dx + 88,
        center.dy,
      )
      ..moveTo(center.dx - 78, center.dy - 6)
      ..quadraticBezierTo(
        center.dx,
        center.dy - 55,
        center.dx + 78,
        center.dy - 6,
      );
    canvas.drawPath(jaw, paint);
    paint.strokeWidth = 2;
    for (var i = -4; i <= 4; i++) {
      final x = center.dx + i * 18;
      canvas.drawLine(
        Offset(x, center.dy + 6),
        Offset(x + i.sign * 2, center.dy + 32 + open * 34),
        paint,
      );
    }
  }

  void _drawTitle(Canvas canvas, Size size, String value, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: 28,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset((size.width - painter.width) / 2, 28));
  }

  @override
  bool shouldRepaint(covariant _ProceduralVisualPainter oldDelegate) => true;
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
