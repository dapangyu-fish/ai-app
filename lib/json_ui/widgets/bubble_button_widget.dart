import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonBubbleButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return _BubbleButton(
      color: _parseColor(json['color']?.toString()) ?? Colors.blue,
      text: interpreter.resolveTemplate(json['text']?.toString() ?? ''),
      arrowLocation: _parseArrowLocation(json['arrowLocation']?.toString()),
      bubbleWidth: (json['bubbleWidth'] as num?)?.toDouble() ?? 120,
      bubbleHeight: (json['bubbleHeight'] as num?)?.toDouble() ?? 60,
      minWidth: (json['minWidth'] as num?)?.toDouble(),
      height: (json['height'] as num?)?.toDouble(),
    );
  }
}

class _BubbleButton extends StatefulWidget {
  final Color color;
  final String text;
  final ArrowLocation arrowLocation;
  final double bubbleWidth;
  final double bubbleHeight;
  final double? minWidth;
  final double? height;

  const _BubbleButton({
    required this.color,
    required this.text,
    required this.arrowLocation,
    required this.bubbleWidth,
    required this.bubbleHeight,
    this.minWidth,
    this.height,
  });

  @override
  State<_BubbleButton> createState() => _BubbleButtonState();
}

class _BubbleButtonState extends State<_BubbleButton> {
  final GlobalKey _buttonKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return MaterialButton(
      key: _buttonKey,
      color: widget.color,
      minWidth: widget.minWidth,
      height: widget.height,
      onPressed: _showBubble,
    );
  }

  void _showBubble() {
    final renderObject = _buttonKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final origin = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;

    double x;
    double y;
    switch (widget.arrowLocation) {
      case ArrowLocation.top:
        x = origin.dx + size.width / 2;
        y = origin.dy + size.height;
        break;
      case ArrowLocation.right:
        x = origin.dx - widget.bubbleWidth;
        y = origin.dy + size.height / 2;
        break;
      case ArrowLocation.left:
        x = origin.dx + size.width;
        y = origin.dy + size.height / 2;
        break;
      case ArrowLocation.bottom:
        x = origin.dx + size.width / 2;
        y = origin.dy - widget.bubbleHeight;
        break;
    }

    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => _BubbleDialog(
        text: widget.text,
        height: widget.bubbleHeight,
        width: widget.bubbleWidth,
        arrowLocation: widget.arrowLocation,
        x: x,
        y: y,
      ),
    );
  }
}

class _BubbleDialog extends StatelessWidget {
  final String text;
  final ArrowLocation arrowLocation;
  final double height;
  final double width;
  final double x;
  final double y;

  const _BubbleDialog({
    required this.text,
    required this.arrowLocation,
    required this.height,
    required this.width,
    required this.x,
    required this.y,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: InkWell(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          alignment: Alignment.centerLeft,
          child: _BubbleTipWidget(
            arrowLocation: arrowLocation,
            width: width,
            height: height,
            radius: 4,
            x: x,
            y: y,
            text: text,
            onDismiss: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}

class _BubbleTipWidget extends StatelessWidget {
  final double height;
  final double width;
  final double radius;
  final String text;
  final double x;
  final double y;
  final ArrowLocation arrowLocation;
  final VoidCallback? onDismiss;

  const _BubbleTipWidget({
    required this.height,
    required this.width,
    required this.radius,
    required this.text,
    required this.x,
    required this.y,
    required this.arrowLocation,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    const arrowHeight = 10.0;
    const arrowWidth = 10.0;
    final screenSize = MediaQuery.sizeOf(context);

    var left = x;
    var top = y;
    if (arrowLocation == ArrowLocation.bottom ||
        arrowLocation == ArrowLocation.top) {
      left = x - width / 2;
    } else {
      top = y - height / 2;
    }

    final widthOut = width + left > screenSize.width || left < 0;
    final heightOut = height + top > screenSize.height || top < 0;

    if (left < 0) {
      left = 0;
    } else if (widthOut) {
      left = screenSize.width - width;
    }
    if (top < 0) {
      top = 0;
    } else if (heightOut) {
      top = screenSize.height - height;
    }

    final arrowCenter =
        (arrowLocation == ArrowLocation.bottom ||
            arrowLocation == ArrowLocation.top)
        ? !widthOut
        : !heightOut;

    var arrowPosition =
        (arrowLocation == ArrowLocation.bottom ||
            arrowLocation == ArrowLocation.top)
        ? (x - left - arrowWidth / 2)
        : (y - top - arrowHeight / 2);
    if (arrowLocation == ArrowLocation.bottom ||
        arrowLocation == ArrowLocation.top) {
      if (arrowPosition < radius + 2) {
        arrowPosition = radius + 4;
      } else if (arrowPosition > width - radius - 2) {
        arrowPosition = width - radius - 4;
      }
    } else {
      if (arrowPosition < radius + 2) {
        arrowPosition = radius + 4;
      } else if (arrowPosition > height - radius - 2) {
        arrowPosition = height - radius - 4;
      }
    }

    final margin = arrowLocation == ArrowLocation.top
        ? const EdgeInsets.only(top: arrowHeight, right: 5, left: 5)
        : EdgeInsets.zero;

    final alignment =
        arrowLocation == ArrowLocation.top ||
            arrowLocation == ArrowLocation.bottom
        ? Alignment.center
        : Alignment.centerLeft;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanEnd: (_) => onDismiss?.call(),
      child: Container(
        alignment: Alignment.centerLeft,
        width: width,
        height: height,
        margin: EdgeInsets.only(left: left, top: top),
        child: Stack(
          children: [
            CustomPaint(
              size: Size(width, height),
              painter: _BubblePainter(
                angle: radius,
                arrowHeight: arrowHeight,
                arrowWidth: arrowWidth,
                arrowPosition: arrowPosition,
                arrowLocation: arrowLocation,
                arrowCenter: arrowCenter,
              ),
            ),
            Align(
              alignment: alignment,
              child: Container(
                margin: margin,
                width: width,
                height: height - arrowHeight,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(left: 20),
                      height: height,
                      child: Icon(
                        Icons.notifications,
                        size: height - 30,
                        color: Theme.of(context).primaryColorDark,
                      ),
                    ),
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.only(left: 5, right: 5),
                        child: Text(
                          text,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BubblePainter extends CustomPainter {
  final double angle;
  final double arrowWidth;
  final double arrowHeight;
  final double arrowPosition;
  final ArrowLocation arrowLocation;
  final bool arrowCenter;

  const _BubblePainter({
    required this.angle,
    required this.arrowWidth,
    required this.arrowHeight,
    required this.arrowPosition,
    required this.arrowLocation,
    required this.arrowCenter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final path = Path();
    final paint = Paint()..color = Colors.white;
    switch (arrowLocation) {
      case ArrowLocation.left:
        _left(rect, path);
        break;
      case ArrowLocation.right:
        _right(rect, path);
        break;
      case ArrowLocation.top:
        _top(rect, path);
        break;
      case ArrowLocation.bottom:
        _bottom(rect, path);
        break;
    }
    canvas.drawPath(path, paint);
  }

  void _left(Rect rect, Path path) {
    final position = arrowCenter
        ? (rect.bottom - rect.top) / 2 - arrowHeight / 2
        : arrowPosition;
    path
      ..moveTo(rect.left + arrowWidth, arrowHeight + position)
      ..lineTo(rect.left, position + arrowHeight / 2)
      ..lineTo(rect.left + arrowWidth, position)
      ..lineTo(rect.left + arrowWidth, rect.top + angle)
      ..addRRect(
        RRect.fromLTRBR(
          rect.left + arrowHeight,
          rect.top,
          rect.right,
          rect.bottom,
          Radius.circular(angle),
        ),
      )
      ..close();
  }

  void _top(Rect rect, Path path) {
    final position = arrowCenter
        ? (rect.right - rect.left) / 2 - arrowWidth / 2
        : arrowPosition;
    path
      ..moveTo(rect.left + math.min(position, angle), rect.top + arrowHeight)
      ..lineTo(rect.left + position, rect.top + arrowHeight)
      ..lineTo(rect.left + arrowWidth / 2 + position, rect.top)
      ..lineTo(rect.left + arrowWidth + position, rect.top + arrowHeight)
      ..addRRect(
        RRect.fromLTRBR(
          rect.left,
          rect.top + arrowHeight,
          rect.right,
          rect.bottom,
          Radius.circular(angle),
        ),
      )
      ..close();
  }

  void _right(Rect rect, Path path) {
    final position = arrowCenter
        ? (rect.bottom - rect.top) / 2 - arrowWidth / 2
        : arrowPosition;
    path
      ..moveTo(rect.right - arrowWidth, position)
      ..lineTo(rect.right, position + arrowHeight / 2)
      ..lineTo(rect.right - arrowWidth, position + arrowHeight)
      ..moveTo(rect.left + angle, rect.top)
      ..addRRect(
        RRect.fromLTRBR(
          rect.left,
          rect.top,
          rect.right - arrowHeight,
          rect.bottom,
          Radius.circular(angle),
        ),
      )
      ..close();
  }

  void _bottom(Rect rect, Path path) {
    final position = arrowCenter
        ? (rect.right - rect.left) / 2 - arrowWidth / 2
        : arrowPosition;
    path
      ..moveTo(rect.left + arrowWidth + position, rect.bottom - arrowHeight)
      ..lineTo(rect.left + position + arrowWidth / 2, rect.bottom)
      ..lineTo(rect.left + position, rect.bottom - arrowHeight)
      ..addRRect(
        RRect.fromLTRBR(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom - arrowHeight,
          Radius.circular(angle),
        ),
      )
      ..close();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

enum ArrowLocation { left, right, top, bottom }

ArrowLocation _parseArrowLocation(String? value) {
  return switch (value?.toLowerCase()) {
    'left' => ArrowLocation.left,
    'right' => ArrowLocation.right,
    'top' => ArrowLocation.top,
    _ => ArrowLocation.bottom,
  };
}

Color? _parseColor(String? value) {
  if (value == null || !value.startsWith('#')) return null;
  final hex = value.substring(1);
  if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
  if (hex.length == 8) return Color(int.parse(hex, radix: 16));
  return null;
}
