// Progress 控件 — 线性进度条
// 与 loading 控件 kind=linear 等价，但更语义化、默认更细一点
// 支持: value (0~1, 不传 = 不确定), color, backgroundColor, height, width
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonProgressWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    double? value;
    final rawValue = interpreter.resolveExpression(json['value']);
    if (rawValue is num) {
      value = rawValue.toDouble().clamp(0.0, 1.0);
    } else if (rawValue is String && rawValue.isNotEmpty) {
      final parsed = double.tryParse(rawValue);
      if (parsed != null) value = parsed.clamp(0.0, 1.0);
    }

    final rawColor = json['color']?.toString();
    final color = _parseColor(
      rawColor != null ? interpreter.resolveTemplate(rawColor) : null,
    );
    final rawBg = json['backgroundColor']?.toString();
    final bg = _parseColor(
      rawBg != null ? interpreter.resolveTemplate(rawBg) : null,
    );
    final height = (json['height'] as num?)?.toDouble() ?? 6;
    final width = (json['width'] as num?)?.toDouble();
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 0;

    Widget progress = LinearProgressIndicator(
      value: value,
      color: color,
      backgroundColor: bg,
      minHeight: height,
    );
    if (borderRadius > 0) {
      progress = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: progress,
      );
    }
    return SizedBox(width: width, child: progress);
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}

class JsonGradientProgressWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final value = (_resolveDouble(interpreter, json['value']) ?? 0)
        .clamp(0, 1)
        .toDouble();
    final width = _resolveDouble(interpreter, json['width']);
    final height = _resolveDouble(interpreter, json['height']) ?? 6;
    final borderRadius =
        _resolveDouble(interpreter, json['borderRadius']) ?? height / 2;
    final animation = json['animation'] is Map
        ? Map<String, dynamic>.from(json['animation'] as Map)
        : const <String, dynamic>{};

    final backgroundGradient =
        _parseLinearGradient(interpreter, json['backgroundGradient']) ??
        LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            _parseColor(
                  json['backgroundColor'] == null
                      ? null
                      : interpreter.resolveTemplate(
                          json['backgroundColor'].toString(),
                        ),
                ) ??
                Colors.black12,
            _parseColor(
                  json['backgroundColor'] == null
                      ? null
                      : interpreter.resolveTemplate(
                          json['backgroundColor'].toString(),
                        ),
                ) ??
                Colors.black12,
          ],
        );
    final rawFillGradients = json['fillGradients'];
    final fillGradients = rawFillGradients is List
        ? rawFillGradients
              .map((item) => _parseLinearGradient(interpreter, item))
              .whereType<LinearGradient>()
              .toList()
        : <LinearGradient>[];
    final border = json['border'] is Map
        ? Map<String, dynamic>.from(json['border'] as Map)
        : const <String, dynamic>{};

    return _GradientProgressControl(
      value: value,
      width: width,
      height: height,
      borderRadius: borderRadius,
      backgroundGradient: backgroundGradient,
      fillGradients: fillGradients,
      borderColor: _parseColor(border['color']?.toString()),
      borderWidth: _resolveDouble(interpreter, border['width']) ?? 0,
      animationMode: animation['mode']?.toString(),
      durationMs: (_resolveDouble(interpreter, animation['durationMs']) ?? 300)
          .round(),
      curve: _parseCurve(animation['curve']?.toString()),
      reverse: animation['reverse'] == true,
    );
  }
}

class _GradientProgressControl extends StatefulWidget {
  final double value;
  final double? width;
  final double height;
  final double borderRadius;
  final LinearGradient backgroundGradient;
  final List<LinearGradient> fillGradients;
  final Color? borderColor;
  final double borderWidth;
  final String? animationMode;
  final int durationMs;
  final Curve curve;
  final bool reverse;

  const _GradientProgressControl({
    required this.value,
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.backgroundGradient,
    required this.fillGradients,
    required this.borderColor,
    required this.borderWidth,
    required this.animationMode,
    required this.durationMs,
    required this.curve,
    required this.reverse,
  });

  @override
  State<_GradientProgressControl> createState() =>
      _GradientProgressControlState();
}

class _GradientProgressControlState extends State<_GradientProgressControl>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _animation;

  @override
  void initState() {
    super.initState();
    _syncController();
  }

  @override
  void didUpdateWidget(covariant _GradientProgressControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationMode != widget.animationMode ||
        oldWidget.durationMs != widget.durationMs ||
        oldWidget.value != widget.value ||
        oldWidget.curve != widget.curve ||
        oldWidget.reverse != widget.reverse) {
      _syncController();
    }
  }

  void _syncController() {
    _controller?.dispose();
    _controller = null;
    _animation = null;
    if (widget.animationMode != 'repeat') return;
    final controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.durationMs.clamp(16, 60000)),
    );
    _controller = controller;
    _animation = Tween<double>(
      begin: 0,
      end: widget.value,
    ).animate(CurvedAnimation(parent: controller, curve: widget.curve));
    controller.repeat(reverse: widget.reverse);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.animationMode == 'repeat' && _animation != null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _animation!,
          builder: (context, _) => _buildPaint(_animation!.value),
        ),
      );
    }
    if (widget.animationMode == 'mount') {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: widget.value),
          duration: Duration(milliseconds: widget.durationMs),
          curve: widget.curve,
          builder: (context, value, _) => _buildPaint(value),
        ),
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: _buildPaint(widget.value),
    );
  }

  Widget _buildPaint(double value) {
    return CustomPaint(
      painter: _GradientProgressPainter(
        value: value.clamp(0, 1).toDouble(),
        borderRadius: widget.borderRadius,
        backgroundGradient: widget.backgroundGradient,
        fillGradients: widget.fillGradients,
        borderColor: widget.borderColor,
        borderWidth: widget.borderWidth,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _GradientProgressPainter extends CustomPainter {
  final double value;
  final double borderRadius;
  final LinearGradient backgroundGradient;
  final List<LinearGradient> fillGradients;
  final Color? borderColor;
  final double borderWidth;

  const _GradientProgressPainter({
    required this.value,
    required this.borderRadius,
    required this.backgroundGradient,
    required this.fillGradients,
    required this.borderColor,
    required this.borderWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Offset.zero & size;
    final radius = Radius.circular(borderRadius);
    final fullRRect = RRect.fromRectAndRadius(fullRect, radius);
    final paint = Paint()..isAntiAlias = true;

    paint.shader = backgroundGradient.createShader(fullRect);
    canvas.drawRRect(fullRRect, paint);

    canvas.save();
    canvas.clipRRect(fullRRect);
    final fillWidth = size.width * value;
    final fillRect = Rect.fromLTWH(0, -5, fillWidth, size.height + 10);
    final fillRRect = RRect.fromRectAndCorners(
      fillRect,
      topLeft: radius,
      bottomLeft: radius,
      topRight: radius,
      bottomRight: radius,
    );
    for (final gradient in fillGradients) {
      paint.shader = gradient.createShader(
        Rect.fromLTWH(0, 0, fillWidth, size.height),
      );
      canvas.drawRRect(fillRRect, paint);
    }
    canvas.restore();

    if (borderColor != null && borderWidth > 0) {
      final borderPaint = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth
        ..color = borderColor!;
      canvas.drawRRect(fullRRect.deflate(borderWidth / 2), borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GradientProgressPainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.backgroundGradient != backgroundGradient ||
        oldDelegate.fillGradients != fillGradients ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth;
  }
}

LinearGradient? _parseLinearGradient(JsonInterpreter interpreter, dynamic raw) {
  if (raw is! Map) return null;
  final map = Map<String, dynamic>.from(raw);
  final colors = map['colors'] is List
      ? (map['colors'] as List)
            .map(
              (item) =>
                  _parseColor(interpreter.resolveTemplate(item.toString())),
            )
            .whereType<Color>()
            .toList()
      : <Color>[];
  if (colors.isEmpty) return null;
  final stops = map['stops'] is List
      ? (map['stops'] as List)
            .map((item) {
              if (item is num) return item.toDouble();
              return double.tryParse(
                interpreter.resolveTemplate(item.toString()),
              );
            })
            .whereType<double>()
            .toList()
      : null;
  return LinearGradient(
    begin: _parseGradientAlignment(map['begin']) ?? Alignment.centerLeft,
    end: _parseGradientAlignment(map['end']) ?? Alignment.centerRight,
    stops: stops != null && stops.length == colors.length ? stops : null,
    colors: colors,
  );
}

Alignment? _parseGradientAlignment(dynamic raw) {
  if (raw is Map) {
    final map = Map<String, dynamic>.from(raw);
    final x = map['x'];
    final y = map['y'];
    if (x is num && y is num) return Alignment(x.toDouble(), y.toDouble());
  }
  return switch (raw?.toString()) {
    'topLeft' => Alignment.topLeft,
    'topCenter' => Alignment.topCenter,
    'topRight' => Alignment.topRight,
    'centerLeft' => Alignment.centerLeft,
    'center' => Alignment.center,
    'centerRight' => Alignment.centerRight,
    'bottomLeft' => Alignment.bottomLeft,
    'bottomCenter' => Alignment.bottomCenter,
    'bottomRight' => Alignment.bottomRight,
    _ => null,
  };
}

Curve _parseCurve(String? value) {
  switch (value) {
    case 'fastOutSlowIn':
      return Curves.fastOutSlowIn;
    case 'bounceInOut':
      return Curves.bounceInOut;
    case 'linear':
      return Curves.linear;
    case 'easeIn':
      return Curves.easeIn;
    case 'easeOut':
      return Curves.easeOut;
    case 'easeInOut':
    default:
      return Curves.easeInOut;
  }
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
