import 'dart:ui';

import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonGsyRotatingCircleWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return const Center(child: _RotatingCircleDemo());
  }
}

class _RotatingCircleDemo extends StatefulWidget {
  const _RotatingCircleDemo();

  @override
  State<_RotatingCircleDemo> createState() => _RotatingCircleDemoState();
}

class _RotatingCircleDemoState extends State<_RotatingCircleDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();
  late final Animation<double> _radius = Tween<double>(
    begin: 0,
    end: 200,
  ).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Container(
        height: 200,
        width: 200,
        color: Colors.greenAccent,
        child: CustomPaint(foregroundPainter: _CirclePainter(_radius)),
      ),
    );
  }
}

class _CirclePainter extends CustomPainter {
  final Animation<double> animation;
  final Paint _paint = Paint();

  _CirclePainter(this.animation) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    _paint
      ..color = Colors.redAccent
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(const Offset(100, 100), animation.value * 1.5, _paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class JsonGsyCircularRevealWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    return _CircularReveal(
      collapsed: interpreter.resolveExpression(json['collapsed']) == true,
      duration: Duration(
        milliseconds: (json['durationMs'] as num?)?.toInt() ?? 500,
      ),
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class _CircularReveal extends StatelessWidget {
  final bool collapsed;
  final Duration duration;
  final Widget child;

  const _CircularReveal({
    required this.collapsed,
    required this.duration,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: collapsed ? 1 : 0),
      duration: duration,
      curve: Curves.easeInSine,
      builder: (context, value, _) {
        return ClipPath(
          clipper: _RevealClipper(
            value: value,
            minRadius: 0,
            maxRadius: 250,
            offset: Offset(
              MediaQuery.sizeOf(context).width / 2,
              MediaQuery.sizeOf(context).height / 2,
            ),
          ),
          child: child,
        );
      },
    );
  }
}

class _RevealClipper extends CustomClipper<Path> {
  final double value;
  final double minRadius;
  final double maxRadius;
  final Offset offset;

  const _RevealClipper({
    required this.value,
    required this.minRadius,
    required this.maxRadius,
    required this.offset,
  });

  @override
  Path getClip(Size size) {
    final path = Path();
    final radius = lerpDouble(maxRadius, minRadius, value)!;
    path.addOval(Rect.fromCircle(radius: radius, center: offset));
    return path;
  }

  @override
  bool shouldReclip(covariant _RevealClipper oldClipper) {
    return oldClipper.value != value ||
        oldClipper.offset != offset ||
        oldClipper.minRadius != minRadius ||
        oldClipper.maxRadius != maxRadius;
  }
}
