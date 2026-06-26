import 'dart:async';
import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

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

class JsonImageFilterWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final sigmaX = _resolveDouble(interpreter, json['sigmaX']) ?? 8;
    final sigmaY = _resolveDouble(interpreter, json['sigmaY']) ?? sigmaX;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: sigmaX, sigmaY: sigmaY),
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
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
    final visible = interpreter.evaluateBool(json['visibleWhen']);
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

class JsonCircularRevealWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final visible = interpreter.evaluateBool(json['visibleWhen']);
    final durationMs = (_resolveDouble(interpreter, json['durationMs']) ?? 300)
        .toInt();
    final curve = _parseCurve(json['curve']?.toString());
    final centerX = _resolveDouble(interpreter, json['centerX']);
    final centerY = _resolveDouble(interpreter, json['centerY']);
    final centerXFactor =
        _resolveDouble(interpreter, json['centerXFactor']) ?? 0.5;
    final centerYFactor =
        _resolveDouble(interpreter, json['centerYFactor']) ?? 0.5;
    final minRadius = _resolveDouble(interpreter, json['minRadius']) ?? 0;
    final maxRadius = _resolveDouble(interpreter, json['maxRadius']);

    return LayoutBuilder(
      builder: (context, constraints) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: visible ? 1 : 0),
          duration: Duration(milliseconds: durationMs),
          curve: curve,
          builder: (context, value, child) {
            return ClipPath(
              clipper: _CircularRevealClipper(
                progress: value,
                centerX: centerX,
                centerY: centerY,
                centerXFactor: centerXFactor,
                centerYFactor: centerYFactor,
                minRadius: minRadius,
                maxRadius: maxRadius,
              ),
              child: child,
            );
          },
          child: childJson is Map<String, dynamic>
              ? interpreter.buildWidget(context, childJson)
              : const SizedBox.shrink(),
        );
      },
    );
  }
}

class JsonClipPathWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    final child = childJson is Map<String, dynamic>
        ? interpreter.buildWidget(context, childJson)
        : const SizedBox.shrink();
    final mode = json['mode']?.toString() ?? 'rect';
    final points = (json['points'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((point) => _clipPoint(interpreter, point.cast<dynamic, dynamic>()))
        .toList();
    final commands = (json['commands'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final command = raw.cast<dynamic, dynamic>();
          return _ClipCommand(
            op: command['op']?.toString() ?? '',
            point: _clipPoint(interpreter, command),
            control1: _clipPoint(interpreter, command, suffix: '1'),
            control2: _clipPoint(interpreter, command, suffix: '2'),
          );
        })
        .toList();
    final rect = _ClipRectSpec(
      x: _resolveDouble(interpreter, json['x']),
      y: _resolveDouble(interpreter, json['y']),
      width: _resolveDouble(interpreter, json['width']),
      height: _resolveDouble(interpreter, json['height']),
      xFactor: _resolveDouble(interpreter, json['xFactor']),
      yFactor: _resolveDouble(interpreter, json['yFactor']),
      widthFactor: _resolveDouble(interpreter, json['widthFactor']),
      heightFactor: _resolveDouble(interpreter, json['heightFactor']),
      xOffset: _resolveDouble(interpreter, json['xOffset']) ?? 0,
      yOffset: _resolveDouble(interpreter, json['yOffset']) ?? 0,
    );
    return ClipPath(
      clipper: _JsonPathClipper(
        mode: mode,
        points: points,
        commands: commands,
        rect: rect,
      ),
      clipBehavior: _parseClip(json['clipBehavior']?.toString()),
      child: child,
    );
  }

  _ClipPoint _clipPoint(
    JsonInterpreter interpreter,
    Map<dynamic, dynamic> point, {
    String suffix = '',
  }) {
    return _ClipPoint(
      x: _resolveDouble(interpreter, point['x$suffix']),
      y: _resolveDouble(interpreter, point['y$suffix']),
      xFactor: _resolveDouble(interpreter, point['x${suffix}Factor']),
      yFactor: _resolveDouble(interpreter, point['y${suffix}Factor']),
      xOffset: _resolveDouble(interpreter, point['x${suffix}Offset']) ?? 0,
      yOffset: _resolveDouble(interpreter, point['y${suffix}Offset']) ?? 0,
    );
  }

  Clip _parseClip(String? value) {
    return switch (value) {
      'hardEdge' => Clip.hardEdge,
      'antiAliasWithSaveLayer' => Clip.antiAliasWithSaveLayer,
      _ => Clip.antiAlias,
    };
  }
}

class JsonImageShaderPathWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final commands = (json['commands'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final command = raw.cast<dynamic, dynamic>();
          return _ClipCommand(
            op: command['op']?.toString() ?? '',
            point: _clipPoint(interpreter, command),
            control1: _clipPoint(interpreter, command, suffix: '1'),
            control2: _clipPoint(interpreter, command, suffix: '2'),
          );
        })
        .toList();
    final points = (json['points'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((point) => _clipPoint(interpreter, point.cast<dynamic, dynamic>()))
        .toList();
    final rect = _ClipRectSpec(
      x: _resolveDouble(interpreter, json['x']),
      y: _resolveDouble(interpreter, json['y']),
      width: _resolveDouble(interpreter, json['pathWidth']),
      height: _resolveDouble(interpreter, json['pathHeight']),
      xFactor: _resolveDouble(interpreter, json['xFactor']),
      yFactor: _resolveDouble(interpreter, json['yFactor']),
      widthFactor: _resolveDouble(interpreter, json['pathWidthFactor']),
      heightFactor: _resolveDouble(interpreter, json['pathHeightFactor']),
      xOffset: _resolveDouble(interpreter, json['xOffset']) ?? 0,
      yOffset: _resolveDouble(interpreter, json['yOffset']) ?? 0,
    );
    return _ImageShaderPathView(
      src: interpreter.resolveTemplate(
        (json['src'] ?? json['image'] ?? json['url'] ?? '').toString(),
      ),
      width: _resolveDouble(interpreter, json['width']),
      height: _resolveDouble(interpreter, json['height']),
      mode: json['mode']?.toString() ?? 'path',
      points: points,
      commands: commands,
      rect: rect,
      tileModeX: _tileMode(json['tileModeX']?.toString()),
      tileModeY: _tileMode(json['tileModeY']?.toString()),
      shaderScaleX: _resolveDouble(interpreter, json['shaderScaleX']) ?? 1,
      shaderScaleY: _resolveDouble(interpreter, json['shaderScaleY']) ?? 1,
      shaderTranslateX:
          _resolveDouble(interpreter, json['shaderTranslateX']) ?? 0,
      shaderTranslateY:
          _resolveDouble(interpreter, json['shaderTranslateY']) ?? 0,
      style: json['style']?.toString() == 'fill'
          ? PaintingStyle.fill
          : PaintingStyle.stroke,
      strokeWidth: _resolveDouble(interpreter, json['strokeWidth']) ?? 1,
      strokeCap: _strokeCap(json['strokeCap']?.toString()),
      fallbackColor:
          _parseColor(
            json['fallbackColor'] == null
                ? null
                : interpreter.resolveTemplate(json['fallbackColor'].toString()),
          ) ??
          Colors.black,
      drawGrid: json['drawGrid'] == true,
      gridStep: _resolveDouble(interpreter, json['gridStep']) ?? 1,
      gridStrokeWidth:
          _resolveDouble(interpreter, json['gridStrokeWidth']) ?? 1,
      gridColor:
          _parseColor(
            json['gridColor'] == null
                ? null
                : interpreter.resolveTemplate(json['gridColor'].toString()),
          ) ??
          Colors.black,
    );
  }

  _ClipPoint _clipPoint(
    JsonInterpreter interpreter,
    Map<dynamic, dynamic> point, {
    String suffix = '',
  }) {
    return _ClipPoint(
      x: _resolveDouble(interpreter, point['x$suffix']),
      y: _resolveDouble(interpreter, point['y$suffix']),
      xFactor: _resolveDouble(interpreter, point['x${suffix}Factor']),
      yFactor: _resolveDouble(interpreter, point['y${suffix}Factor']),
      xOffset: _resolveDouble(interpreter, point['x${suffix}Offset']) ?? 0,
      yOffset: _resolveDouble(interpreter, point['y${suffix}Offset']) ?? 0,
    );
  }
}

class _ImageShaderPathView extends StatefulWidget {
  final String src;
  final double? width;
  final double? height;
  final String mode;
  final List<_ClipPoint> points;
  final List<_ClipCommand> commands;
  final _ClipRectSpec rect;
  final TileMode tileModeX;
  final TileMode tileModeY;
  final double shaderScaleX;
  final double shaderScaleY;
  final double shaderTranslateX;
  final double shaderTranslateY;
  final PaintingStyle style;
  final double strokeWidth;
  final StrokeCap strokeCap;
  final Color fallbackColor;
  final bool drawGrid;
  final double gridStep;
  final double gridStrokeWidth;
  final Color gridColor;

  const _ImageShaderPathView({
    required this.src,
    required this.width,
    required this.height,
    required this.mode,
    required this.points,
    required this.commands,
    required this.rect,
    required this.tileModeX,
    required this.tileModeY,
    required this.shaderScaleX,
    required this.shaderScaleY,
    required this.shaderTranslateX,
    required this.shaderTranslateY,
    required this.style,
    required this.strokeWidth,
    required this.strokeCap,
    required this.fallbackColor,
    required this.drawGrid,
    required this.gridStep,
    required this.gridStrokeWidth,
    required this.gridColor,
  });

  @override
  State<_ImageShaderPathView> createState() => _ImageShaderPathViewState();
}

class _ImageShaderPathViewState extends State<_ImageShaderPathView> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ImageShaderPathView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src) {
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _clearStream();
    super.dispose();
  }

  void _resolveImage() {
    _clearStream();
    if (widget.src.isEmpty) {
      setState(() => _image = null);
      return;
    }
    final provider =
        widget.src.startsWith('http://') || widget.src.startsWith('https://')
        ? NetworkImage(widget.src)
        : AssetImage(widget.src) as ImageProvider;
    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _image = info.image);
      },
      onError: (_, __) {
        if (!mounted) return;
        setState(() => _image = null);
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _clearStream() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            widget.width ??
            (constraints.hasBoundedWidth ? constraints.maxWidth : 300.0);
        final height =
            widget.height ??
            (constraints.hasBoundedHeight ? constraints.maxHeight : width);
        return SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            painter: _ImageShaderPathPainter(
              image: _image,
              mode: widget.mode,
              points: widget.points,
              commands: widget.commands,
              rect: widget.rect,
              tileModeX: widget.tileModeX,
              tileModeY: widget.tileModeY,
              shaderScaleX: widget.shaderScaleX,
              shaderScaleY: widget.shaderScaleY,
              shaderTranslateX: widget.shaderTranslateX,
              shaderTranslateY: widget.shaderTranslateY,
              style: widget.style,
              strokeWidth: widget.strokeWidth,
              strokeCap: widget.strokeCap,
              fallbackColor: widget.fallbackColor,
              drawGrid: widget.drawGrid,
              gridStep: widget.gridStep,
              gridStrokeWidth: widget.gridStrokeWidth,
              gridColor: widget.gridColor,
            ),
          ),
        );
      },
    );
  }
}

class _ImageShaderPathPainter extends CustomPainter {
  final ui.Image? image;
  final String mode;
  final List<_ClipPoint> points;
  final List<_ClipCommand> commands;
  final _ClipRectSpec rect;
  final TileMode tileModeX;
  final TileMode tileModeY;
  final double shaderScaleX;
  final double shaderScaleY;
  final double shaderTranslateX;
  final double shaderTranslateY;
  final PaintingStyle style;
  final double strokeWidth;
  final StrokeCap strokeCap;
  final Color fallbackColor;
  final bool drawGrid;
  final double gridStep;
  final double gridStrokeWidth;
  final Color gridColor;

  const _ImageShaderPathPainter({
    required this.image,
    required this.mode,
    required this.points,
    required this.commands,
    required this.rect,
    required this.tileModeX,
    required this.tileModeY,
    required this.shaderScaleX,
    required this.shaderScaleY,
    required this.shaderTranslateX,
    required this.shaderTranslateY,
    required this.style,
    required this.strokeWidth,
    required this.strokeCap,
    required this.fallbackColor,
    required this.drawGrid,
    required this.gridStep,
    required this.gridStrokeWidth,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = _JsonPathClipper(
      mode: mode,
      points: points,
      commands: commands,
      rect: rect,
    ).getClip(size);
    final paint = Paint()
      ..isAntiAlias = true
      ..color = fallbackColor
      ..style = style
      ..strokeWidth = strokeWidth
      ..strokeCap = strokeCap;
    if (image != null) {
      final matrix = Matrix4.identity()
        ..translateByDouble(shaderTranslateX, shaderTranslateY, 0, 1)
        ..scaleByDouble(shaderScaleX, shaderScaleY, 1, 1);
      paint.shader = ImageShader(image!, tileModeX, tileModeY, matrix.storage);
    }
    canvas.drawPath(path, paint);

    if (!drawGrid) return;
    final bounds = path.getBounds();
    final step = math.max(0.25, gridStep);
    final gridPaint = Paint()
      ..isAntiAlias = false
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = gridStrokeWidth;
    canvas.save();
    canvas.clipPath(path);
    for (var x = step; x < bounds.width; x += step) {
      canvas.drawLine(
        Offset(bounds.left + x, bounds.top),
        Offset(bounds.left + x, bounds.bottom),
        gridPaint,
      );
    }
    for (var y = step; y < bounds.height; y += step) {
      canvas.drawLine(
        Offset(bounds.left, bounds.top + y),
        Offset(bounds.right, bounds.top + y),
        gridPaint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ImageShaderPathPainter oldDelegate) => true;
}

class _ClipPoint {
  final double? x;
  final double? y;
  final double? xFactor;
  final double? yFactor;
  final double xOffset;
  final double yOffset;

  const _ClipPoint({
    required this.x,
    required this.y,
    required this.xFactor,
    required this.yFactor,
    required this.xOffset,
    required this.yOffset,
  });

  Offset resolve(Size size) => Offset(
    x ?? size.width * (xFactor ?? 0) + xOffset,
    y ?? size.height * (yFactor ?? 0) + yOffset,
  );
}

class _ClipRectSpec {
  final double? x;
  final double? y;
  final double? width;
  final double? height;
  final double? xFactor;
  final double? yFactor;
  final double? widthFactor;
  final double? heightFactor;
  final double xOffset;
  final double yOffset;

  const _ClipRectSpec({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.xFactor,
    required this.yFactor,
    required this.widthFactor,
    required this.heightFactor,
    required this.xOffset,
    required this.yOffset,
  });

  Rect resolve(Size size) {
    final left = x ?? size.width * (xFactor ?? 0) + xOffset;
    final top = y ?? size.height * (yFactor ?? 0) + yOffset;
    final resolvedWidth = width ?? size.width * (widthFactor ?? 1);
    final resolvedHeight = height ?? size.height * (heightFactor ?? 1);
    return Rect.fromLTWH(left, top, resolvedWidth, resolvedHeight);
  }
}

class _ClipCommand {
  final String op;
  final _ClipPoint point;
  final _ClipPoint control1;
  final _ClipPoint control2;

  const _ClipCommand({
    required this.op,
    required this.point,
    required this.control1,
    required this.control2,
  });
}

class _JsonPathClipper extends CustomClipper<Path> {
  final String mode;
  final List<_ClipPoint> points;
  final List<_ClipCommand> commands;
  final _ClipRectSpec rect;

  const _JsonPathClipper({
    required this.mode,
    required this.points,
    required this.commands,
    required this.rect,
  });

  @override
  Path getClip(Size size) {
    if (mode == 'polygon' && points.length >= 3) {
      final resolved = points.map((point) => point.resolve(size)).toList();
      final path = Path()..moveTo(resolved.first.dx, resolved.first.dy);
      for (final point in resolved.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      return path..close();
    }
    if (mode == 'path' && commands.isNotEmpty) {
      final path = Path();
      for (final command in commands) {
        final point = command.point.resolve(size);
        switch (command.op) {
          case 'moveTo':
            path.moveTo(point.dx, point.dy);
            break;
          case 'lineTo':
            path.lineTo(point.dx, point.dy);
            break;
          case 'quadTo':
            final control = command.control1.resolve(size);
            path.quadraticBezierTo(control.dx, control.dy, point.dx, point.dy);
            break;
          case 'cubicTo':
            final control1 = command.control1.resolve(size);
            final control2 = command.control2.resolve(size);
            path.cubicTo(
              control1.dx,
              control1.dy,
              control2.dx,
              control2.dy,
              point.dx,
              point.dy,
            );
            break;
          case 'close':
            path.close();
            break;
        }
      }
      return path;
    }
    return Path()..addRect(rect.resolve(size));
  }

  @override
  bool shouldReclip(covariant _JsonPathClipper oldClipper) => true;
}

class _CircularRevealClipper extends CustomClipper<Path> {
  final double progress;
  final double? centerX;
  final double? centerY;
  final double centerXFactor;
  final double centerYFactor;
  final double minRadius;
  final double? maxRadius;

  const _CircularRevealClipper({
    required this.progress,
    required this.centerX,
    required this.centerY,
    required this.centerXFactor,
    required this.centerYFactor,
    required this.minRadius,
    required this.maxRadius,
  });

  @override
  Path getClip(Size size) {
    final center = Offset(
      centerX ?? size.width * centerXFactor,
      centerY ?? size.height * centerYFactor,
    );
    final radius = _lerpDouble(
      minRadius,
      maxRadius ?? _radiusToCover(size, center),
      progress,
    );
    return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(covariant _CircularRevealClipper oldClipper) {
    return oldClipper.progress != progress ||
        oldClipper.centerX != centerX ||
        oldClipper.centerY != centerY ||
        oldClipper.centerXFactor != centerXFactor ||
        oldClipper.centerYFactor != centerYFactor ||
        oldClipper.minRadius != minRadius ||
        oldClipper.maxRadius != maxRadius;
  }

  double _radiusToCover(Size size, Offset center) {
    final left = center.dx;
    final right = size.width - center.dx;
    final top = center.dy;
    final bottom = size.height - center.dy;
    final farX = math.max(left.abs(), right.abs());
    final farY = math.max(top.abs(), bottom.abs());
    return math.sqrt(farX * farX + farY * farY);
  }

  double _lerpDouble(double a, double b, double t) => a + (b - a) * t;
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
    final variables = <String, double>{};
    final rawVariables = json['variables'];
    if (rawVariables is Map) {
      for (final entry in rawVariables.entries) {
        final resolved = interpreter.evaluateExpression(entry.value);
        final numeric = switch (resolved) {
          num value when value.isFinite => value.toDouble(),
          bool value => value ? 1.0 : 0.0,
          _ => double.tryParse(resolved?.toString() ?? ''),
        };
        if (numeric != null && numeric.isFinite) {
          variables['${entry.key}'] = numeric;
        }
      }
    }
    return _AnimatedCanvas(
      layers: layers,
      background: _parseColor(json['backgroundColor']?.toString()),
      width: _resolveDouble(interpreter, json['width']),
      height: _resolveDouble(interpreter, json['height']),
      variables: variables,
      speed: _resolveDouble(interpreter, json['speed']) ?? 1,
      durationMs: (_resolveDouble(interpreter, json['durationMs']) ?? 24000)
          .toInt(),
      interactive: json['interactive'] == true,
    );
  }
}

class JsonParticleStreamCanvasWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final variables = <String, double>{};
    final rawVariables = json['variables'];
    if (rawVariables is Map) {
      for (final entry in rawVariables.entries) {
        final resolved = interpreter.evaluateExpression(entry.value);
        final numeric = switch (resolved) {
          num value when value.isFinite => value.toDouble(),
          bool value => value ? 1.0 : 0.0,
          _ => double.tryParse(resolved?.toString() ?? ''),
        };
        if (numeric != null && numeric.isFinite) {
          variables['${entry.key}'] = numeric;
        }
      }
    }
    return _ParticleStreamCanvas(
      background: _parseColor(json['backgroundColor']?.toString()),
      width: _resolveDouble(interpreter, json['width']),
      height: _resolveDouble(interpreter, json['height']),
      variables: variables,
      intervalMs: (_resolveDouble(interpreter, json['intervalMs']) ?? 50)
          .toInt(),
      appendCount: (_resolveDouble(interpreter, json['appendCount']) ?? 1)
          .toInt(),
      maxCount: (_resolveDouble(interpreter, json['maxCount']) ?? 300).toInt(),
      runImmediately: json['runImmediately'] != false,
      x: json['x'],
      y: json['y'],
      radius: json['radius'],
      hue: json['hue'],
      saturation: json['saturation'],
      lightness: json['lightness'],
      alpha: json['alpha'],
      linearLightnessOffset: _resolveDouble(
        interpreter,
        json['linearLightnessOffset'],
      ),
      radialHighlight: json['radialHighlight'] == true,
      radialHighlightColor:
          _parseColor(json['radialHighlightColor']?.toString()) ??
          const Color(0x53FFFFFF),
      postRotate: json['postRotate'],
    );
  }
}

class _ParticleStreamCanvas extends StatefulWidget {
  final Color? background;
  final double? width;
  final double? height;
  final Map<String, double> variables;
  final int intervalMs;
  final int appendCount;
  final int maxCount;
  final bool runImmediately;
  final dynamic x;
  final dynamic y;
  final dynamic radius;
  final dynamic hue;
  final dynamic saturation;
  final dynamic lightness;
  final dynamic alpha;
  final double? linearLightnessOffset;
  final bool radialHighlight;
  final Color radialHighlightColor;
  final dynamic postRotate;

  const _ParticleStreamCanvas({
    required this.background,
    required this.width,
    required this.height,
    required this.variables,
    required this.intervalMs,
    required this.appendCount,
    required this.maxCount,
    required this.runImmediately,
    required this.x,
    required this.y,
    required this.radius,
    required this.hue,
    required this.saturation,
    required this.lightness,
    required this.alpha,
    required this.linearLightnessOffset,
    required this.radialHighlight,
    required this.radialHighlightColor,
    required this.postRotate,
  });

  @override
  State<_ParticleStreamCanvas> createState() => _ParticleStreamCanvasState();
}

class _ParticleStreamCanvasState extends State<_ParticleStreamCanvas> {
  final List<_StreamParticle> _particles = [];
  Timer? _timer;
  int _sequence = 0;
  Size? _size;
  bool _initialAppendScheduled = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant _ParticleStreamCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.intervalMs != widget.intervalMs ||
        oldWidget.appendCount != widget.appendCount ||
        oldWidget.maxCount != widget.maxCount ||
        oldWidget.x != widget.x ||
        oldWidget.y != widget.y ||
        oldWidget.radius != widget.radius ||
        oldWidget.hue != widget.hue ||
        oldWidget.saturation != widget.saturation ||
        oldWidget.lightness != widget.lightness ||
        oldWidget.alpha != widget.alpha) {
      _particles.clear();
      _sequence = 0;
      _initialAppendScheduled = false;
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.intervalMs <= 0) return;
    _timer = Timer.periodic(
      Duration(milliseconds: widget.intervalMs),
      (_) => _appendParticles(),
    );
  }

  void _appendParticles() {
    final size = _size;
    if (!mounted || size == null || size.isEmpty) return;
    final appendCount = widget.appendCount.clamp(0, 500);
    if (appendCount <= 0) return;
    final maxCount = widget.maxCount.clamp(1, 12000);
    final next = List<_StreamParticle>.from(_particles);
    for (var localIndex = 0; localIndex < appendCount; localIndex++) {
      final vars = _baseVars(size)
        ..['seq'] = _sequence.toDouble()
        ..['i'] = localIndex.toDouble();
      final x = _num(widget.x, vars, size.width / 2);
      final y = _num(widget.y, vars, size.height / 2);
      final radius = _num(widget.radius, vars, 2);
      final alpha = _num(widget.alpha, vars, 1).clamp(0.0, 1.0);
      next.add(
        _StreamParticle(
          x: x,
          y: y,
          radius: radius,
          hue: _num(widget.hue, vars, 0) % 360,
          saturation: _num(widget.saturation, vars, 1).clamp(0.0, 1.0),
          lightness: _num(widget.lightness, vars, 0.5).clamp(0.0, 1.0),
          alpha: alpha,
        ),
      );
      _sequence++;
    }
    if (next.length > maxCount) {
      next.removeRange(0, next.length - maxCount);
    }
    setState(() {
      _particles
        ..clear()
        ..addAll(next);
    });
  }

  Map<String, double> _baseVars(Size size) => {
    'w': size.width,
    'h': size.height,
    'min': math.min(size.width, size.height),
    'max': math.max(size.width, size.height),
    'pi': math.pi,
  }..addAll(widget.variables);

  double _num(
    dynamic expression,
    Map<String, double> vars, [
    double fallback = 0,
  ]) {
    final value = _eval(expression, vars);
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }

  bool _bool(dynamic expression, Map<String, double> vars) {
    final value = _eval(expression, vars);
    if (value is bool) return value;
    if (value is num) return value != 0;
    return false;
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
      case 'abs':
        return at(0).abs();
      case 'min':
        if (values.isEmpty) return 0;
        return values.map((item) => _num(item, vars)).reduce(math.min);
      case 'max':
        if (values.isEmpty) return 0;
        return values.map((item) => _num(item, vars)).reduce(math.max);
      case 'clamp':
        return at(0).clamp(at(1), at(2)).toDouble();
      case 'if':
        return _bool(values.isEmpty ? null : values[0], vars)
            ? _eval(values.length > 1 ? values[1] : null, vars)
            : _eval(values.length > 2 ? values[2] : null, vars);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            widget.width ??
            (constraints.hasBoundedWidth
                ? constraints.maxWidth
                : constraints.hasBoundedHeight
                ? constraints.maxHeight
                : 300.0);
        final height =
            widget.height ??
            (constraints.hasBoundedHeight
                ? constraints.maxHeight
                : constraints.hasBoundedWidth
                ? constraints.maxWidth
                : 300.0);
        _size = Size(width, height);
        if (widget.runImmediately &&
            _particles.isEmpty &&
            !_initialAppendScheduled) {
          _initialAppendScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _appendParticles();
          });
        }
        return SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            painter: _ParticleStreamPainter(
              background: widget.background,
              particles: List<_StreamParticle>.unmodifiable(_particles),
              linearLightnessOffset: widget.linearLightnessOffset,
              radialHighlight: widget.radialHighlight,
              radialHighlightColor: widget.radialHighlightColor,
              postRotate: _num(widget.postRotate, _baseVars(_size!), 0),
            ),
          ),
        );
      },
    );
  }
}

class _StreamParticle {
  final double x;
  final double y;
  final double radius;
  final double hue;
  final double saturation;
  final double lightness;
  final double alpha;

  const _StreamParticle({
    required this.x,
    required this.y,
    required this.radius,
    required this.hue,
    required this.saturation,
    required this.lightness,
    required this.alpha,
  });

  Color get color =>
      HSLColor.fromAHSL(alpha, hue, saturation, lightness).toColor();
}

class _ParticleStreamPainter extends CustomPainter {
  final Color? background;
  final List<_StreamParticle> particles;
  final double? linearLightnessOffset;
  final bool radialHighlight;
  final Color radialHighlightColor;
  final double postRotate;

  const _ParticleStreamPainter({
    required this.background,
    required this.particles,
    required this.linearLightnessOffset,
    required this.radialHighlight,
    required this.radialHighlightColor,
    required this.postRotate,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (background != null) canvas.drawColor(background!, BlendMode.src);
    for (final particle in particles) {
      final color = particle.color;
      final paint = Paint()
        ..isAntiAlias = true
        ..color = color
        ..style = PaintingStyle.fill;
      final lightnessOffset = linearLightnessOffset;
      if (lightnessOffset != null) {
        final topColor = HSLColor.fromAHSL(
          particle.alpha,
          particle.hue,
          particle.saturation,
          (particle.lightness + lightnessOffset).clamp(0.0, 1.0),
        ).toColor();
        paint.shader = ui.Gradient.linear(
          Offset(particle.x, particle.y),
          Offset(particle.x, particle.y + particle.radius),
          [topColor, color],
        );
      }
      canvas.drawCircle(Offset(particle.x, particle.y), particle.radius, paint);
      if (radialHighlight) {
        canvas.drawCircle(
          Offset(particle.x, particle.y),
          particle.radius,
          Paint()
            ..isAntiAlias = true
            ..shader = ui.Gradient.radial(
              Offset(particle.x, particle.y - particle.radius),
              particle.radius,
              [radialHighlightColor, Colors.transparent],
            ),
        );
      }
      if (postRotate != 0) canvas.rotate(postRotate);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticleStreamPainter oldDelegate) => true;
}

class JsonProjectedSceneWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final nodes = (json['nodes'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((node) {
          return node.map((key, value) {
            final name = '$key';
            if (name == 'src' && value is String) {
              return MapEntry(name, interpreter.resolveTemplate(value));
            }
            return MapEntry(name, value);
          });
        })
        .toList();
    final locals = _resolveSceneLocals(interpreter, json['locals']);
    return _ProjectedScene(
      nodes: nodes,
      locals: locals,
      background: _parseColor(json['backgroundColor']?.toString()),
      width: _resolveDouble(interpreter, json['width']),
      height: _resolveDouble(interpreter, json['height']),
      zoom: _resolveDouble(interpreter, json['zoom']) ?? 1,
      perspective: _resolveDouble(interpreter, json['perspective']) ?? 800,
      rotationX: _resolveDouble(interpreter, json['rotationX']) ?? 0,
      rotationY: _resolveDouble(interpreter, json['rotationY']) ?? 0,
      rotationZ: _resolveDouble(interpreter, json['rotationZ']) ?? 0,
      durationMs: (_resolveDouble(interpreter, json['durationMs']) ?? 10000)
          .toInt(),
      speed: _resolveDouble(interpreter, json['speed']) ?? 1,
      sortMode: json['sortMode']?.toString() ?? 'depth',
      interactive: json['interactive'] == true,
      dragRotationScale:
          _resolveDouble(interpreter, json['dragRotationScale']) ?? 0.01,
    );
  }

  Map<String, dynamic> _resolveSceneLocals(
    JsonInterpreter interpreter,
    dynamic raw,
  ) {
    if (raw is! Map) return const {};
    return raw.map((key, value) {
      if (value is String) {
        final resolved = interpreter.evaluateExpression(value);
        if (resolved is num || resolved is bool) {
          return MapEntry('$key', resolved);
        }
        final parsed = double.tryParse(resolved?.toString() ?? '');
        if (parsed != null) return MapEntry('$key', parsed);
      }
      return MapEntry('$key', value);
    });
  }
}

class _ProjectedScene extends StatefulWidget {
  final List<Map<String, dynamic>> nodes;
  final Map<String, dynamic> locals;
  final Color? background;
  final double? width;
  final double? height;
  final double zoom;
  final double perspective;
  final double rotationX;
  final double rotationY;
  final double rotationZ;
  final int durationMs;
  final double speed;
  final String sortMode;
  final bool interactive;
  final double dragRotationScale;

  const _ProjectedScene({
    required this.nodes,
    required this.locals,
    required this.background,
    required this.width,
    required this.height,
    required this.zoom,
    required this.perspective,
    required this.rotationX,
    required this.rotationY,
    required this.rotationZ,
    required this.durationMs,
    required this.speed,
    required this.sortMode,
    required this.interactive,
    required this.dragRotationScale,
  });

  @override
  State<_ProjectedScene> createState() => _ProjectedSceneState();
}

class _ProjectedSceneState extends State<_ProjectedScene>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final Map<String, ui.Image> _images = {};
  final Map<String, ImageStream> _imageStreams = {};
  final Map<String, ImageStreamListener> _imageListeners = {};
  double _dragRotationX = 0;
  double _dragRotationY = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: math.max(16, widget.durationMs)),
    )..repeat();
    _syncImages();
  }

  @override
  void didUpdateWidget(covariant _ProjectedScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.durationMs != widget.durationMs) {
      _controller.duration = Duration(
        milliseconds: math.max(16, widget.durationMs),
      );
      if (!_controller.isAnimating) _controller.repeat();
    }
    if (oldWidget.nodes != widget.nodes) {
      _syncImages();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _clearImages();
    super.dispose();
  }

  void _syncImages() {
    final wanted = <String>{
      for (final node in widget.nodes)
        if (node['kind'] == 'image' &&
            (node['src']?.toString() ?? '').isNotEmpty)
          node['src'].toString(),
    };
    for (final src in _imageStreams.keys.toList()) {
      if (!wanted.contains(src)) _removeImage(src);
    }
    for (final src in wanted) {
      if (_imageStreams.containsKey(src)) continue;
      final provider = src.startsWith('http://') || src.startsWith('https://')
          ? NetworkImage(src)
          : AssetImage(src) as ImageProvider;
      final stream = provider.resolve(const ImageConfiguration());
      final listener = ImageStreamListener(
        (info, _) {
          if (!mounted) return;
          setState(() => _images[src] = info.image);
        },
        onError: (_, __) {
          if (!mounted) return;
          setState(() => _images.remove(src));
        },
      );
      _imageStreams[src] = stream;
      _imageListeners[src] = listener;
      stream.addListener(listener);
    }
  }

  void _removeImage(String src) {
    final stream = _imageStreams.remove(src);
    final listener = _imageListeners.remove(src);
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _images.remove(src);
  }

  void _clearImages() {
    for (final src in _imageStreams.keys.toList()) {
      _removeImage(src);
    }
  }

  void _drag(DragUpdateDetails details) {
    setState(() {
      _dragRotationY += details.delta.dx * widget.dragRotationScale;
      _dragRotationX -= details.delta.dy * widget.dragRotationScale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            widget.width ??
            (constraints.hasBoundedWidth
                ? constraints.maxWidth
                : constraints.hasBoundedHeight
                ? constraints.maxHeight
                : 300.0);
        final height =
            widget.height ??
            (constraints.hasBoundedHeight
                ? constraints.maxHeight
                : constraints.hasBoundedWidth
                ? constraints.maxWidth
                : 300.0);
        final scene = SizedBox(
          width: width,
          height: height,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return CustomPaint(
                painter: _ProjectedScenePainter(
                  nodes: widget.nodes,
                  locals: widget.locals,
                  background: widget.background,
                  images: Map<String, ui.Image>.unmodifiable(_images),
                  zoom: widget.zoom,
                  perspective: widget.perspective,
                  rotationX: widget.rotationX + _dragRotationX,
                  rotationY: widget.rotationY + _dragRotationY,
                  rotationZ: widget.rotationZ,
                  time: _controller.value * math.pi * 2 * widget.speed,
                  progress: _controller.value,
                  sortMode: widget.sortMode,
                ),
                child: const SizedBox.expand(),
              );
            },
          ),
        );
        if (!widget.interactive) return scene;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: _drag,
          child: scene,
        );
      },
    );
  }
}

class _ScenePoint {
  final double x;
  final double y;
  final double z;

  const _ScenePoint(this.x, this.y, this.z);
}

class _ProjectedPoint {
  final Offset offset;
  final double z;
  final double scale;

  const _ProjectedPoint(this.offset, this.z, this.scale);
}

class _ProjectedDrawCommand {
  final double z;
  final int order;
  final void Function(Canvas) draw;

  const _ProjectedDrawCommand({
    required this.z,
    required this.order,
    required this.draw,
  });
}

class _ProjectedScenePainter extends CustomPainter {
  final List<Map<String, dynamic>> nodes;
  final Map<String, dynamic> locals;
  final Color? background;
  final Map<String, ui.Image> images;
  final double zoom;
  final double perspective;
  final double rotationX;
  final double rotationY;
  final double rotationZ;
  final double time;
  final double progress;
  final String sortMode;

  _ProjectedScenePainter({
    required this.nodes,
    required this.locals,
    required this.background,
    required this.images,
    required this.zoom,
    required this.perspective,
    required this.rotationX,
    required this.rotationY,
    required this.rotationZ,
    required this.time,
    required this.progress,
    required this.sortMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (background != null) canvas.drawColor(background!, BlendMode.src);
    final baseVars = _baseVars(size);
    _applyLocals(locals, baseVars);
    final commands = <_ProjectedDrawCommand>[];
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final vars = Map<String, double>.from(baseVars)..['i'] = index.toDouble();
      _applyLocals(
        (node['locals'] as Map?)?.map(
              (key, value) => MapEntry('$key', value),
            ) ??
            const {},
        vars,
      );
      if (_bool(node['visibleWhen'], vars) == false &&
          node.containsKey('visibleWhen')) {
        continue;
      }
      final command = _drawCommandFor(node, vars, size, index);
      if (command != null) commands.add(command);
    }
    if (sortMode == 'depth') {
      commands.sort((a, b) {
        final depth = a.z.compareTo(b.z);
        return depth == 0 ? a.order.compareTo(b.order) : depth;
      });
    }
    for (final command in commands) {
      command.draw(canvas);
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
  };

  _ProjectedDrawCommand? _drawCommandFor(
    Map<String, dynamic> node,
    Map<String, double> vars,
    Size size,
    int order,
  ) {
    final kind = node['kind']?.toString() ?? 'circle';
    final center = _project(
      _point(
        _num(node['x'], vars),
        _num(node['y'], vars),
        _num(node['z'], vars),
      ),
      size,
    );
    final paint = _paint(node, vars);
    final strokeWidth =
        _num(node['strokeWidth'], vars, 1) *
        zoom *
        center.scale.clamp(0.2, 4.0);
    final fill = node['fill'] != false;
    final style = fill ? PaintingStyle.fill : PaintingStyle.stroke;
    paint
      ..style = style
      ..strokeWidth = strokeWidth;

    switch (kind) {
      case 'ellipse':
        return _ProjectedDrawCommand(
          z: center.z,
          order: order,
          draw: (canvas) {
            final width =
                _num(
                  node['width'] ?? node['diameter'],
                  vars,
                  _num(node['radius'], vars, 10) * 2,
                ) *
                zoom *
                center.scale;
            final height =
                _num(
                  node['height'] ?? node['diameter'],
                  vars,
                  _num(node['radius'], vars, 10) * 2,
                ) *
                zoom *
                center.scale;
            final rotateZ = _num(node['rotateZ'], vars);
            canvas.save();
            canvas.translate(center.offset.dx, center.offset.dy);
            if (rotateZ != 0) canvas.rotate(rotateZ);
            canvas.drawOval(
              Rect.fromCenter(
                center: Offset.zero,
                width: width.abs(),
                height: height.abs(),
              ),
              paint,
            );
            canvas.restore();
          },
        );
      case 'roundedRect':
        return _ProjectedDrawCommand(
          z: center.z,
          order: order,
          draw: (canvas) {
            final width = _num(node['width'], vars, 80) * zoom * center.scale;
            final height = _num(node['height'], vars, 48) * zoom * center.scale;
            final radius =
                _num(node['borderRadius'], vars, 8) * zoom * center.scale;
            final rotateZ = _num(node['rotateZ'], vars);
            canvas.save();
            canvas.translate(center.offset.dx, center.offset.dy);
            if (rotateZ != 0) canvas.rotate(rotateZ);
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(
                  center: Offset.zero,
                  width: width.abs(),
                  height: height.abs(),
                ),
                Radius.circular(radius),
              ),
              paint,
            );
            canvas.restore();
          },
        );
      case 'path':
      case 'polygon':
        final path = _path(node, vars, size);
        if (path == null) return null;
        return _ProjectedDrawCommand(
          z: center.z,
          order: order,
          draw: (canvas) => canvas.drawPath(path, paint),
        );
      case 'image':
        final src = node['src']?.toString() ?? '';
        final image = images[src];
        return _ProjectedDrawCommand(
          z: center.z,
          order: order,
          draw: (canvas) {
            final width = _num(node['width'], vars, 80) * zoom * center.scale;
            final height = _num(node['height'], vars, 48) * zoom * center.scale;
            final rotateZ = _num(node['rotateZ'], vars);
            final rect = Rect.fromCenter(
              center: Offset.zero,
              width: width.abs(),
              height: height.abs(),
            );
            canvas.save();
            canvas.translate(center.offset.dx, center.offset.dy);
            if (rotateZ != 0) canvas.rotate(rotateZ);
            if (image != null) {
              paintImage(
                canvas: canvas,
                rect: rect,
                image: image,
                fit: _boxFit(node['fit']?.toString()),
                filterQuality: FilterQuality.medium,
              );
            } else {
              canvas.drawRect(rect, paint);
            }
            canvas.restore();
          },
        );
      case 'text':
        return _ProjectedDrawCommand(
          z: center.z,
          order: order,
          draw: (canvas) {
            final fontSize =
                _num(node['fontSize'], vars, 18) * zoom * center.scale;
            final painter = TextPainter(
              text: TextSpan(
                text: node['value']?.toString() ?? '',
                style: TextStyle(
                  color: paint.color,
                  fontSize: fontSize,
                  fontWeight: node['fontWeight'] == 'bold'
                      ? FontWeight.bold
                      : FontWeight.normal,
                  fontStyle: node['fontStyle'] == 'italic'
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
              ),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
            )..layout();
            canvas.save();
            canvas.translate(
              center.offset.dx - painter.width / 2,
              center.offset.dy - painter.height / 2,
            );
            painter.paint(canvas, Offset.zero);
            canvas.restore();
          },
        );
      case 'cone':
        final radius = _num(node['diameter'], vars, 10) / 2;
        final length = _num(node['length'], vars, 10);
        final p1 = _project(
          _point(-radius, 0, 0, origin: node, vars: vars),
          size,
        );
        final p2 = _project(
          _point(radius, 0, 0, origin: node, vars: vars),
          size,
        );
        final p3 = _project(
          _point(0, length, length, origin: node, vars: vars),
          size,
        );
        final path = Path()
          ..moveTo(p1.offset.dx, p1.offset.dy)
          ..lineTo(p2.offset.dx, p2.offset.dy)
          ..lineTo(p3.offset.dx, p3.offset.dy)
          ..close();
        return _ProjectedDrawCommand(
          z: (p1.z + p2.z + p3.z) / 3,
          order: order,
          draw: (canvas) => canvas.drawPath(path, paint),
        );
      case 'circle':
      default:
        return _ProjectedDrawCommand(
          z: center.z,
          order: order,
          draw: (canvas) {
            final diameter =
                _num(
                  node['diameter'],
                  vars,
                  _num(node['radius'], vars, 10) * 2,
                ) *
                zoom *
                center.scale;
            canvas.drawCircle(center.offset, diameter.abs() / 2, paint);
          },
        );
    }
  }

  Path? _path(Map<String, dynamic> node, Map<String, double> vars, Size size) {
    final commands = node['commands'];
    final points = node['points'];
    final path = Path();
    if (commands is List && commands.isNotEmpty) {
      for (final raw in commands.whereType<Map>()) {
        final command = raw.map((key, value) => MapEntry('$key', value));
        switch (command['op']?.toString()) {
          case 'moveTo':
            final p = _project(_commandPoint(command, vars), size);
            path.moveTo(p.offset.dx, p.offset.dy);
            break;
          case 'lineTo':
            final p = _project(_commandPoint(command, vars), size);
            path.lineTo(p.offset.dx, p.offset.dy);
            break;
          case 'quadTo':
            final c = _project(_commandPoint(command, vars, suffix: '1'), size);
            final p = _project(_commandPoint(command, vars), size);
            path.quadraticBezierTo(
              c.offset.dx,
              c.offset.dy,
              p.offset.dx,
              p.offset.dy,
            );
            break;
          case 'close':
            path.close();
            break;
        }
      }
      return path;
    }
    if (points is List && points.length >= 3) {
      final projected = points.whereType<Map>().map((raw) {
        return _project(
          _commandPoint(raw.map((key, value) => MapEntry('$key', value)), vars),
          size,
        );
      }).toList();
      if (projected.length < 3) return null;
      path.moveTo(projected.first.offset.dx, projected.first.offset.dy);
      for (final p in projected.skip(1)) {
        path.lineTo(p.offset.dx, p.offset.dy);
      }
      path.close();
      return path;
    }
    return null;
  }

  _ScenePoint _commandPoint(
    Map<String, dynamic> raw,
    Map<String, double> vars, {
    String suffix = '',
  }) {
    return _point(
      _num(raw['x$suffix'], vars),
      _num(raw['y$suffix'], vars),
      _num(raw['z$suffix'], vars),
    );
  }

  _ScenePoint _point(
    double x,
    double y,
    double z, {
    Map<String, dynamic>? origin,
    Map<String, double>? vars,
  }) {
    if (origin == null || vars == null) return _ScenePoint(x, y, z);
    return _ScenePoint(
      x + _num(origin['x'], vars),
      y + _num(origin['y'], vars),
      z + _num(origin['z'], vars),
    );
  }

  _ProjectedPoint _project(_ScenePoint point, Size size) {
    var x = point.x;
    var y = point.y;
    var z = point.z;
    final sinX = math.sin(rotationX);
    final cosX = math.cos(rotationX);
    final y1 = y * cosX - z * sinX;
    final z1 = y * sinX + z * cosX;
    y = y1;
    z = z1;

    final sinY = math.sin(rotationY);
    final cosY = math.cos(rotationY);
    final x1 = x * cosY + z * sinY;
    final z2 = -x * sinY + z * cosY;
    x = x1;
    z = z2;

    final sinZ = math.sin(rotationZ);
    final cosZ = math.cos(rotationZ);
    final x2 = x * cosZ - y * sinZ;
    final y2 = x * sinZ + y * cosZ;
    x = x2;
    y = y2;

    final distance = math.max(1.0, perspective - z);
    final scale = perspective <= 0 ? 1.0 : perspective / distance;
    return _ProjectedPoint(
      Offset(
        size.width / 2 + x * zoom * scale,
        size.height / 2 + y * zoom * scale,
      ),
      z,
      scale,
    );
  }

  Paint _paint(Map<String, dynamic> node, Map<String, double> vars) {
    final alpha = _num(
      node['alpha'] ?? node['opacity'],
      vars,
      1,
    ).clamp(0.0, 1.0);
    final paint = Paint()
      ..isAntiAlias = true
      ..color = (_parseColor(node['color']?.toString()) ?? Colors.white)
          .withValues(alpha: alpha);
    final blur = _num(node['blurRadius'], vars);
    if (blur > 0) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    }
    return paint;
  }

  BoxFit _boxFit(String? value) {
    return switch (value) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      'fitWidth' => BoxFit.fitWidth,
      'fitHeight' => BoxFit.fitHeight,
      'none' => BoxFit.none,
      'scaleDown' => BoxFit.scaleDown,
      _ => BoxFit.contain,
    };
  }

  void _applyLocals(Map<String, dynamic> source, Map<String, double> vars) {
    for (final entry in source.entries) {
      vars[entry.key] = _num(entry.value, vars);
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
      case 'abs':
        return at(0).abs();
      case 'floor':
        return at(0).floorToDouble();
      case 'min':
        if (values.isEmpty) return 0;
        return values.map((item) => _num(item, vars)).reduce(math.min);
      case 'max':
        if (values.isEmpty) return 0;
        return values.map((item) => _num(item, vars)).reduce(math.max);
      case 'clamp':
        return at(0).clamp(at(1), at(2)).toDouble();
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

  @override
  bool shouldRepaint(covariant _ProjectedScenePainter oldDelegate) => true;
}

class _AnimatedCanvas extends StatefulWidget {
  final List<Map<String, dynamic>> layers;
  final Color? background;
  final double? width;
  final double? height;
  final Map<String, double> variables;
  final double speed;
  final int durationMs;
  final bool interactive;

  const _AnimatedCanvas({
    required this.layers,
    required this.background,
    required this.width,
    required this.height,
    required this.variables,
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
        final width =
            widget.width ??
            (constraints.hasBoundedWidth
                ? constraints.maxWidth
                : constraints.hasBoundedHeight
                ? constraints.maxHeight
                : 300.0);
        final height =
            widget.height ??
            (constraints.hasBoundedHeight
                ? constraints.maxHeight
                : constraints.hasBoundedWidth
                ? constraints.maxWidth
                : 300.0);
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
                  variables: widget.variables,
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
  final Map<String, double> variables;
  final double time;
  final double progress;
  final Offset? touch;
  final double pulse;

  _AnimatedCanvasPainter({
    required this.layers,
    required this.background,
    required this.variables,
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
        case 'linear_gradient':
          _drawLinearGradient(canvas, size, layer, vars);
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
  }..addAll(variables);

  void _drawRepeated(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> baseVars,
    void Function(Canvas, Size, Map<String, dynamic>, Map<String, double>) draw,
  ) {
    final count = _num(layer['count'], baseVars).round().clamp(0, 12000);
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
      case 'rect':
        final width = _num(layer['width'], vars, radius * 2);
        final height = _num(layer['height'], vars, radius * 2);
        final borderRadius = _num(layer['borderRadius'], vars);
        final rect = Rect.fromCenter(
          center: Offset(x, y),
          width: width,
          height: height,
        );
        if (borderRadius > 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(borderRadius)),
            paint,
          );
        } else {
          canvas.drawRect(rect, paint);
        }
        break;
      case 'oval':
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(x, y),
            width: _num(layer['width'], vars, radius * 2),
            height: _num(layer['height'], vars, radius * 2),
          ),
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

  void _drawLinearGradient(
    Canvas canvas,
    Size size,
    Map<String, dynamic> layer,
    Map<String, double> vars,
  ) {
    _applyLocals(layer, vars);
    final rect = Rect.fromLTWH(
      _num(layer['x'], vars),
      _num(layer['y'], vars),
      _num(layer['width'], vars, size.width),
      _num(layer['height'], vars, size.height),
    );
    final rawColors = layer['colors'];
    if (rawColors is! List || rawColors.length < 2) return;
    final colors = rawColors.map((raw) {
      if (raw is Map) {
        return _color(raw.map((key, value) => MapEntry('$key', value)), vars);
      }
      return _parseColor(raw?.toString()) ?? Colors.transparent;
    }).toList();
    final stops = (layer['stops'] as List<dynamic>?)
        ?.map((raw) => _num(raw, vars).clamp(0.0, 1.0).toDouble())
        .toList();
    final begin =
        _parseAlignment(layer['begin']?.toString()) ?? Alignment.topCenter;
    final end =
        _parseAlignment(layer['end']?.toString()) ?? Alignment.bottomCenter;
    canvas.drawRect(
      rect,
      Paint()
        ..isAntiAlias = true
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: colors,
          stops: stops != null && stops.length == colors.length ? stops : null,
        ).createShader(rect),
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
    final blur = _num(layer['blurRadius'], vars);
    if (blur > 0) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    }
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
      case 'atan2':
        return math.atan2(at(0), at(1));
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
      case 'bitxor':
        return at(0).toInt() ^ at(1).toInt();
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

TileMode _tileMode(String? value) {
  return switch (value) {
    'clamp' => TileMode.clamp,
    'mirror' => TileMode.mirror,
    'decal' => TileMode.decal,
    _ => TileMode.repeated,
  };
}

StrokeCap _strokeCap(String? value) {
  return switch (value) {
    'square' => StrokeCap.square,
    'butt' => StrokeCap.butt,
    _ => StrokeCap.round,
  };
}

Alignment? _parseAlignment(String? value) {
  return switch (value) {
    'center' => Alignment.center,
    'topLeft' => Alignment.topLeft,
    'topCenter' => Alignment.topCenter,
    'topRight' => Alignment.topRight,
    'bottomLeft' => Alignment.bottomLeft,
    'bottomCenter' => Alignment.bottomCenter,
    'bottomRight' => Alignment.bottomRight,
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
