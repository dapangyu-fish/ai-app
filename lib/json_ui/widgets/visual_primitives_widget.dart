import 'dart:async';
import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

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

class JsonAnimatedCanvasWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final layers = (json['layers'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((layer) => layer.map((key, value) => MapEntry('$key', value)))
        .toList();
    return _AnimatedCanvas(
      layers: layers,
      background: _parseColor(json['backgroundColor']?.toString()),
      speed: _resolveDouble(interpreter, json['speed']) ?? 1,
      durationMs: (_resolveDouble(interpreter, json['durationMs']) ?? 24000)
          .toInt(),
      interactive: json['interactive'] == true,
    );
  }
}

class _AnimatedCanvas extends StatefulWidget {
  final List<Map<String, dynamic>> layers;
  final Color? background;
  final double speed;
  final int durationMs;
  final bool interactive;

  const _AnimatedCanvas({
    required this.layers,
    required this.background,
    required this.speed,
    required this.durationMs,
    required this.interactive,
  });

  @override
  State<_AnimatedCanvas> createState() => _AnimatedCanvasState();
}

class _AnimatedCanvasState extends State<_AnimatedCanvas>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Offset? _touch;
  double _pulse = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: math.max(16, widget.durationMs)),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant _AnimatedCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.durationMs != widget.durationMs) {
      _controller.duration = Duration(
        milliseconds: math.max(16, widget.durationMs),
      );
      if (!_controller.isAnimating) _controller.repeat();
    }
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 300.0;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 300.0;
        final canvas = SizedBox(
          width: width,
          height: height,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final pulse = _pulse;
              _pulse = math.max(0, _pulse - 0.015);
              return CustomPaint(
                painter: _AnimatedCanvasPainter(
                  layers: widget.layers,
                  background: widget.background,
                  time: _controller.value * math.pi * 2 * widget.speed,
                  progress: _controller.value,
                  touch: _touch,
                  pulse: pulse,
                ),
                child: const SizedBox.expand(),
              );
            },
          ),
        );
        if (!widget.interactive) return canvas;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _setTouch(details.localPosition),
          onPanStart: (details) => _setTouch(details.localPosition),
          onPanUpdate: (details) => _setTouch(details.localPosition),
          onPanEnd: (_) => setState(() => _touch = null),
          child: canvas,
        );
      },
    );
  }
}

class _AnimatedCanvasPainter extends CustomPainter {
  final List<Map<String, dynamic>> layers;
  final Color? background;
  final double time;
  final double progress;
  final Offset? touch;
  final double pulse;

  _AnimatedCanvasPainter({
    required this.layers,
    required this.background,
    required this.time,
    required this.progress,
    required this.touch,
    required this.pulse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (background != null) canvas.drawColor(background!, BlendMode.src);
    for (final layer in layers) {
      final vars = _baseVars(size);
      switch (layer['kind']?.toString()) {
        case 'particles':
          _drawRepeated(canvas, size, layer, vars, _drawParticle);
          break;
        case 'segments':
          _drawRepeated(canvas, size, layer, vars, _drawSegment);
          break;
        case 'grid':
          _drawGrid(canvas, size, layer, vars);
          break;
        case 'circle':
          _drawCircle(canvas, size, layer, vars);
          break;
        case 'rect':
          _drawRect(canvas, size, layer, vars);
          break;
        case 'path':
          _drawPath(canvas, size, layer, vars);
          break;
        case 'text':
          _drawText(canvas, size, layer, vars);
          break;
      }
    }
  }

  Map<String, double> _baseVars(Size size) => {
    't': time,
    'time': time,
    'progress': progress,
    'w': size.width,
    'h': size.height,
    'min': math.min(size.width, size.height),
    'max': math.max(size.width, size.height),
    'pi': math.pi,
    'pulse': pulse,
    'touchX': touch?.dx ?? size.width / 2,
    'touchY': touch?.dy ?? size.height / 2,
  };

  void _drawRepeated(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> baseVars,
    void Function(Canvas, Size, Map<String, dynamic>, Map<String, double>) draw,
  ) {
    final count = _num(layer['count'], baseVars).round().clamp(0, 8000);
    if (count <= 0) return;
    for (var i = 0; i < count; i++) {
      final vars = Map<String, double>.from(baseVars)
        ..['i'] = i.toDouble()
        ..['n'] = count.toDouble()
        ..['f'] = count <= 1 ? 0 : i / (count - 1);
      _applyLocals(layer, vars);
      if (_bool(layer['skipWhen'], vars)) continue;
      draw(canvas, size, layer, vars);
    }
  }

  void _drawParticle(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> vars,
  ) {
    final x = _num(layer['x'], vars, size.width / 2);
    final y = _num(layer['y'], vars, size.height / 2);
    final radius = _num(layer['radius'], vars, 2);
    final paint = _paint(layer, vars)..style = PaintingStyle.fill;
    switch (layer['shape']?.toString()) {
      case 'square':
        final side = radius * 2;
        canvas.drawRect(
          Rect.fromCenter(center: Offset(x, y), width: side, height: side),
          paint,
        );
        break;
      default:
        canvas.drawCircle(Offset(x, y), radius, paint);
        break;
    }
  }

  void _drawSegment(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> vars,
  ) {
    final paint = _paint(layer, vars)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _num(layer['strokeWidth'], vars, 1)
      ..strokeCap = _strokeCap(layer['strokeCap']?.toString());
    canvas.drawLine(
      Offset(
        _num(layer['x1'] ?? layer['x'], vars),
        _num(layer['y1'] ?? layer['y'], vars),
      ),
      Offset(_num(layer['x2'], vars), _num(layer['y2'], vars)),
      paint,
    );
  }

  void _drawGrid(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> baseVars,
  ) {
    final columns = _num(layer['columns'], baseVars, 12).round().clamp(1, 400);
    final rows = _num(layer['rows'], baseVars, 12).round().clamp(1, 400);
    final cellW = _num(layer['cellWidth'], baseVars, size.width / columns);
    final cellH = _num(layer['cellHeight'], baseVars, size.height / rows);
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final vars = Map<String, double>.from(baseVars)
          ..['row'] = row.toDouble()
          ..['col'] = col.toDouble()
          ..['i'] = (row * columns + col).toDouble()
          ..['n'] = (rows * columns).toDouble()
          ..['cellW'] = cellW
          ..['cellH'] = cellH;
        _applyLocals(layer, vars);
        if (_bool(layer['skipWhen'], vars)) continue;
        final x = _num(layer['x'], vars, col * cellW);
        final y = _num(layer['y'], vars, row * cellH);
        final width = _num(layer['width'], vars, cellW);
        final height = _num(layer['height'], vars, cellH);
        canvas.drawRect(
          Rect.fromLTWH(x, y, width, height),
          _paint(layer, vars)..style = PaintingStyle.fill,
        );
      }
    }
  }

  void _drawCircle(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> vars,
  ) {
    final paint = _paint(layer, vars)
      ..style = layer['style'] == 'stroke'
          ? PaintingStyle.stroke
          : PaintingStyle.fill
      ..strokeWidth = _num(layer['strokeWidth'], vars, 1);
    canvas.drawCircle(
      Offset(
        _num(layer['x'], vars, size.width / 2),
        _num(layer['y'], vars, size.height / 2),
      ),
      _num(layer['radius'], vars, math.min(size.width, size.height) * 0.1),
      paint,
    );
  }

  void _drawRect(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> vars,
  ) {
    final rect = Rect.fromLTWH(
      _num(layer['x'], vars),
      _num(layer['y'], vars),
      _num(layer['width'], vars, size.width),
      _num(layer['height'], vars, size.height),
    );
    final radius = _num(layer['borderRadius'], vars);
    final paint = _paint(layer, vars)
      ..style = layer['style'] == 'stroke'
          ? PaintingStyle.stroke
          : PaintingStyle.fill
      ..strokeWidth = _num(layer['strokeWidth'], vars, 1);
    if (radius > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius)),
        paint,
      );
    } else {
      canvas.drawRect(rect, paint);
    }
  }

  void _drawPath(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> vars,
  ) {
    _applyLocals(layer, vars);
    final commands = layer['commands'];
    if (commands is! List) return;
    final path = Path();
    for (final raw in commands.whereType<Map>()) {
      final command = raw.map((key, value) => MapEntry('$key', value));
      switch (command['op']?.toString()) {
        case 'moveTo':
          path.moveTo(_num(command['x'], vars), _num(command['y'], vars));
          break;
        case 'lineTo':
          path.lineTo(_num(command['x'], vars), _num(command['y'], vars));
          break;
        case 'quadTo':
          path.quadraticBezierTo(
            _num(command['x1'], vars),
            _num(command['y1'], vars),
            _num(command['x'], vars),
            _num(command['y'], vars),
          );
          break;
        case 'cubicTo':
          path.cubicTo(
            _num(command['x1'], vars),
            _num(command['y1'], vars),
            _num(command['x2'], vars),
            _num(command['y2'], vars),
            _num(command['x'], vars),
            _num(command['y'], vars),
          );
          break;
        case 'close':
          path.close();
          break;
      }
    }
    final paint = _paint(layer, vars)
      ..style = layer['style'] == 'fill'
          ? PaintingStyle.fill
          : PaintingStyle.stroke
      ..strokeWidth = _num(layer['strokeWidth'], vars, 1)
      ..strokeCap = _strokeCap(layer['strokeCap']?.toString());
    canvas.drawPath(path, paint);
  }

  void _drawText(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> vars,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: layer['value']?.toString() ?? '',
        style: TextStyle(
          color: _color(layer, vars),
          fontSize: _num(layer['fontSize'], vars, 24),
          fontWeight: layer['fontWeight'] == 'bold'
              ? FontWeight.bold
              : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        _num(layer['x'], vars, (size.width - painter.width) / 2),
        _num(layer['y'], vars, 0),
      ),
    );
  }

  Paint _paint(Map<String, dynamic> layer, Map<String, double> vars) {
    final paint = Paint()
      ..color = _color(layer, vars)
      ..isAntiAlias = true;
    final blendMode = _blendMode(layer['blendMode']?.toString());
    if (blendMode != null) paint.blendMode = blendMode;
    return paint;
  }

  Color _color(Map<String, dynamic> layer, Map<String, double> vars) {
    final hue = layer['hue'];
    final alpha = _num(layer['alpha'], vars, 1).clamp(0.0, 1.0);
    if (hue != null) {
      return HSVColor.fromAHSV(
        alpha,
        _num(hue, vars) % 360,
        _num(layer['saturation'], vars, 0.85).clamp(0.0, 1.0),
        _num(layer['valueBrightness'], vars, 1).clamp(0.0, 1.0),
      ).toColor();
    }
    final start = _parseColor(layer['color']?.toString()) ?? Colors.white;
    final end = _parseColor(layer['color2']?.toString());
    final mixed = end == null
        ? start
        : Color.lerp(start, end, _num(layer['mix'], vars).clamp(0.0, 1.0))!;
    return mixed.withValues(alpha: alpha);
  }

  void _applyLocals(Map<String, dynamic> layer, Map<String, double> vars) {
    final locals = layer['locals'];
    if (locals is! Map) return;
    for (final entry in locals.entries) {
      vars['${entry.key}'] = _num(entry.value, vars);
    }
  }

  bool _bool(dynamic expression, Map<String, double> vars) {
    final value = _eval(expression, vars);
    if (value is bool) return value;
    if (value is num) return value != 0;
    return false;
  }

  double _num(
    dynamic expression,
    Map<String, double> vars, [
    double fallback = 0,
  ]) {
    final value = _eval(expression, vars);
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }

  dynamic _eval(dynamic expression, Map<String, double> vars) {
    if (expression == null) return null;
    if (expression is num || expression is bool) return expression;
    if (expression is String) {
      if (vars.containsKey(expression)) return vars[expression];
      return double.tryParse(expression) ?? expression;
    }
    if (expression is List) {
      return expression.map((item) => _eval(item, vars)).toList();
    }
    if (expression is! Map || expression.isEmpty) return null;
    final key = expression.keys.first.toString();
    final raw = expression.values.first;
    final values = raw is List ? raw : [raw];
    double at(int index, [double fallback = 0]) {
      if (index >= values.length) return fallback;
      final value = _eval(values[index], vars);
      return value is num && value.isFinite ? value.toDouble() : fallback;
    }

    switch (key) {
      case 'var':
        return vars[raw.toString()] ?? 0;
      case '+':
        return values.fold<double>(0, (sum, item) => sum + _num(item, vars));
      case '-':
        if (values.length == 1) return -at(0);
        return at(0) - at(1);
      case '*':
        return values.fold<double>(
          1,
          (product, item) => product * _num(item, vars, 1),
        );
      case '/':
        final divisor = at(1, 1);
        return divisor == 0 ? 0 : at(0) / divisor;
      case '%':
        final divisor = at(1, 1);
        return divisor == 0 ? 0 : at(0) % divisor;
      case 'sin':
        return math.sin(at(0));
      case 'cos':
        return math.cos(at(0));
      case 'tan':
        return math.tan(at(0));
      case 'sqrt':
        return math.sqrt(math.max(0, at(0)));
      case 'pow':
        return math.pow(at(0), at(1)).toDouble();
      case 'abs':
        return at(0).abs();
      case 'floor':
        return at(0).floorToDouble();
      case 'ceil':
        return at(0).ceilToDouble();
      case 'round':
        return at(0).roundToDouble();
      case 'min':
        if (values.isEmpty) return 0;
        return values.map((item) => _num(item, vars)).reduce(math.min);
      case 'max':
        if (values.isEmpty) return 0;
        return values.map((item) => _num(item, vars)).reduce(math.max);
      case 'clamp':
        return at(0).clamp(at(1), at(2)).toDouble();
      case 'lerp':
        return at(0) + (at(1) - at(0)) * at(2);
      case 'seed':
        final seed = math.sin(at(0) * 12.9898) * 43758.5453;
        return seed - seed.floorToDouble();
      case '>':
        return at(0) > at(1);
      case '>=':
        return at(0) >= at(1);
      case '<':
        return at(0) < at(1);
      case '<=':
        return at(0) <= at(1);
      case '==':
        return at(0) == at(1);
      case '!=':
        return at(0) != at(1);
      case 'and':
        return values.every((item) => _bool(item, vars));
      case 'or':
        return values.any((item) => _bool(item, vars));
      case '!':
        return !_bool(values.isEmpty ? null : values.first, vars);
      case 'if':
        return _bool(values.isEmpty ? null : values[0], vars)
            ? _eval(values.length > 1 ? values[1] : null, vars)
            : _eval(values.length > 2 ? values[2] : null, vars);
      default:
        return null;
    }
  }

  BlendMode? _blendMode(String? value) {
    return switch (value) {
      'plus' => BlendMode.plus,
      'screen' => BlendMode.screen,
      'multiply' => BlendMode.multiply,
      _ => null,
    };
  }

  StrokeCap _strokeCap(String? value) {
    return switch (value) {
      'square' => StrokeCap.square,
      'butt' => StrokeCap.butt,
      _ => StrokeCap.round,
    };
  }

  @override
  bool shouldRepaint(covariant _AnimatedCanvasPainter oldDelegate) => true;
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
