import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonSlideVerifyWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return _SlideVerify(
      width: (json['width'] as num?)?.toDouble() ?? 250,
      height: (json['height'] as num?)?.toDouble() ?? 60,
      sliderImage: json['sliderImage']?.toString(),
      successText: interpreter.resolveTemplate(
        json['successText']?.toString() ?? '验证成功',
      ),
      initText: interpreter.resolveTemplate(
        json['initText']?.toString() ?? '滑动验证',
      ),
      borderColor:
          _parseColor(json['borderColor']?.toString()) ?? Colors.blueAccent,
      bgColor: _parseColor(json['bgColor']?.toString()) ?? Colors.grey,
      moveColor: _parseColor(json['moveColor']?.toString()) ?? Colors.blue,
      interpreter: interpreter,
      onSuccess: json['onSuccess'] as Map<String, dynamic>?,
    );
  }
}

class _SlideVerify extends StatefulWidget {
  final double height;
  final double width;
  final Color borderColor;
  final Color bgColor;
  final Color moveColor;
  final String successText;
  final String? sliderImage;
  final String initText;
  final JsonInterpreter interpreter;
  final Map<String, dynamic>? onSuccess;

  const _SlideVerify({
    required this.height,
    required this.width,
    required this.borderColor,
    required this.bgColor,
    required this.moveColor,
    required this.successText,
    required this.initText,
    required this.interpreter,
    this.sliderImage,
    this.onSuccess,
  });

  @override
  State<_SlideVerify> createState() => _SlideVerifyState();
}

class _SlideVerifyState extends State<_SlideVerify>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  Animation<double>? _curve;
  double _initX = 0;
  double _moveDistance = 0;
  late double _sliderWidth;
  bool _verifySuccess = false;
  bool _enable = true;

  @override
  void initState() {
    super.initState();
    _sliderWidth = widget.height - 4;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut)
      ..addListener(() {
        setState(() {
          _moveDistance = _moveDistance - _moveDistance * _curve!.value;
          if (_moveDistance <= 0) _moveDistance = 0;
        });
      });
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _enable = true;
        _controller.reset();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: (details) {
        if (!_enable) return;
        _initX = details.globalPosition.dx;
      },
      onHorizontalDragUpdate: (details) {
        if (!_enable) return;
        _moveDistance = details.globalPosition.dx - _initX;
        if (_moveDistance < 0) _moveDistance = 0;
        if (_moveDistance > widget.width - _sliderWidth) {
          _moveDistance = widget.width - _sliderWidth;
          _enable = false;
          _verifySuccess = true;
          final action = widget.onSuccess;
          if (action != null) {
            widget.interpreter.executeAction(action, context);
          }
        }
        setState(() {});
      },
      onHorizontalDragEnd: (_) {
        if (_enable) {
          _enable = false;
          _controller.forward();
        }
      },
      child: Container(
        height: widget.height,
        width: widget.width,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: widget.bgColor,
          border: Border.all(color: widget.borderColor),
          borderRadius: BorderRadius.all(Radius.circular(widget.height)),
        ),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                height: widget.height - 2,
                width: _moveDistance < 1 ? 0 : _moveDistance + _sliderWidth / 2,
                color: widget.moveColor,
              ),
            ),
            Center(
              child: Text(
                _verifySuccess ? widget.successText : widget.initText,
                style: TextStyle(
                  fontSize: 14,
                  color: _verifySuccess ? Colors.white : Colors.black12,
                ),
              ),
            ),
            Positioned(
              top: 1,
              left: _moveDistance > _sliderWidth
                  ? _moveDistance - 2
                  : _moveDistance,
              child: Container(
                width: _sliderWidth,
                height: _sliderWidth,
                alignment: Alignment.center,
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.all(Radius.circular(_sliderWidth)),
                ),
                child: widget.sliderImage == null
                    ? null
                    : _buildImage(widget.sliderImage!, _sliderWidth),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(String src, double size) {
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return Image.network(src, height: size, width: size, fit: BoxFit.cover);
    }
    return Image.asset(src, height: size, width: size, fit: BoxFit.cover);
  }
}

Color? _parseColor(String? value) {
  if (value == null || !value.startsWith('#')) return null;
  final hex = value.substring(1);
  if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
  if (hex.length == 8) return Color(int.parse(hex, radix: 16));
  return null;
}
