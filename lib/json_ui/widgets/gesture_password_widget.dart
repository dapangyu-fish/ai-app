import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

class JsonGesturePasswordWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final onDone =
        resolveActionAtBuildTime(json['onDone'], interpreter)
            as Map<String, dynamic>?;
    return _GesturePasswordBoard(
      width: _resolveDouble(interpreter, json['width']) ?? 300,
      height: _resolveDouble(interpreter, json['height']) ?? 300,
      frameRadius: _resolveDouble(interpreter, json['frameRadius']) ?? 40,
      pointRadius: _resolveDouble(interpreter, json['pointRadius']) ?? 10,
      pathWidth: _resolveDouble(interpreter, json['pathWidth']) ?? 5,
      color: _parseColor(json['color']?.toString()) ?? Colors.grey,
      highlightColor:
          _parseColor(json['highlightColor']?.toString()) ?? Colors.blue,
      pathColor: _parseColor(json['pathColor']?.toString()) ?? Colors.blue,
      onDone: onDone,
      interpreter: interpreter,
    );
  }
}

class _GesturePasswordBoard extends StatefulWidget {
  final double width;
  final double height;
  final double frameRadius;
  final double pointRadius;
  final double pathWidth;
  final Color color;
  final Color highlightColor;
  final Color pathColor;
  final Map<String, dynamic>? onDone;
  final JsonInterpreter interpreter;

  const _GesturePasswordBoard({
    required this.width,
    required this.height,
    required this.frameRadius,
    required this.pointRadius,
    required this.pathWidth,
    required this.color,
    required this.highlightColor,
    required this.pathColor,
    required this.onDone,
    required this.interpreter,
  });

  @override
  State<_GesturePasswordBoard> createState() => _GesturePasswordBoardState();
}

class _GesturePasswordBoardState extends State<_GesturePasswordBoard> {
  final List<int> _selected = [];
  Offset? _movePoint;
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanDown: (details) => _addPoint(details.localPosition, start: true),
        onPanUpdate: (details) {
          if (!_started) return;
          setState(() {
            _movePoint = details.localPosition;
            _selectAt(details.localPosition);
          });
        },
        onPanEnd: (_) => _finish(context),
        onPanCancel: () => _finish(context),
        child: CustomPaint(
          painter: _GesturePasswordPainter(
            centers: _centers(widget.width),
            selected: _selected,
            movePoint: _movePoint,
            frameRadius: widget.frameRadius,
            pointRadius: widget.pointRadius,
            pathWidth: widget.pathWidth,
            color: widget.color,
            highlightColor: widget.highlightColor,
            pathColor: widget.pathColor,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  List<Offset> _centers(double width) {
    final pointWidth = width / 3;
    return [
      for (var row = 1; row <= 3; row++)
        for (var col = 1; col <= 3; col++)
          Offset(
            (col - 1) * pointWidth + pointWidth / 2,
            (row - 1) * pointWidth + pointWidth / 2,
          ),
    ];
  }

  void _addPoint(Offset offset, {required bool start}) {
    setState(() {
      final index = _selectAt(offset);
      if (start && index != null) {
        _started = true;
        _movePoint = offset;
      }
    });
  }

  int? _selectAt(Offset offset) {
    final centers = _centers(widget.width);
    for (var i = 0; i < centers.length; i++) {
      if (_selected.contains(i)) continue;
      if (_distance(offset, centers[i]) <= widget.frameRadius) {
        _selected.add(i);
        return i;
      }
    }
    return null;
  }

  Future<void> _finish(BuildContext context) async {
    if (!_started) return;
    final result = List<int>.from(_selected);
    setState(() {
      _started = false;
      _movePoint = null;
      _selected.clear();
    });
    final action = widget.onDone;
    if (action == null) return;
    await widget.interpreter.executeActionWithEvent(action, context, {
      'password': result.join(),
      'points': result,
    });
  }

  double _distance(Offset a, Offset b) {
    final dx = a.dx - b.dx;
    final dy = a.dy - b.dy;
    return math.sqrt(dx * dx + dy * dy);
  }
}

class _GesturePasswordPainter extends CustomPainter {
  final List<Offset> centers;
  final List<int> selected;
  final Offset? movePoint;
  final double frameRadius;
  final double pointRadius;
  final double pathWidth;
  final Color color;
  final Color highlightColor;
  final Color pathColor;

  const _GesturePasswordPainter({
    required this.centers,
    required this.selected,
    required this.movePoint,
    required this.frameRadius,
    required this.pointRadius,
    required this.pathWidth,
    required this.color,
    required this.highlightColor,
    required this.pathColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = pathWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..color = pathColor;
    final selectedCenters = selected.map((index) => centers[index]).toList();
    for (var i = 0; i < selectedCenters.length - 1; i++) {
      canvas.drawLine(selectedCenters[i], selectedCenters[i + 1], linePaint);
    }
    if (selectedCenters.isNotEmpty && movePoint != null) {
      canvas.drawLine(selectedCenters.last, movePoint!, linePaint);
    }

    for (var i = 0; i < centers.length; i++) {
      final isSelected = selected.contains(i);
      final dotColor = isSelected ? highlightColor : color;
      final framePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..isAntiAlias = true
        ..color = dotColor;
      final pointPaint = Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = true
        ..color = dotColor;
      canvas.drawCircle(centers[i], frameRadius, framePaint);
      canvas.drawCircle(centers[i], pointRadius, pointPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GesturePasswordPainter oldDelegate) => true;
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
