import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

class JsonSlideVerifyWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return _SlideVerifyControl(
      width: _resolveDouble(interpreter, json['width']) ?? 250,
      height: _resolveDouble(interpreter, json['height']) ?? 60,
      bind: json['bind']?.toString(),
      initialText: interpreter.resolveTemplate(
        json['initialText']?.toString() ?? '',
      ),
      successText: interpreter.resolveTemplate(
        json['successText']?.toString() ?? '',
      ),
      thumbImage: json['thumbImage']?.toString(),
      backgroundColor:
          _parseColor(json['backgroundColor']?.toString()) ?? Colors.grey,
      fillColor: _parseColor(json['fillColor']?.toString()) ?? Colors.blue,
      borderColor:
          _parseColor(json['borderColor']?.toString()) ?? Colors.blueAccent,
      initialTextColor:
          _parseColor(json['initialTextColor']?.toString()) ?? Colors.black12,
      successTextColor:
          _parseColor(json['successTextColor']?.toString()) ?? Colors.white,
      onSuccess:
          resolveActionAtBuildTime(json['onSuccess'], interpreter)
              as Map<String, dynamic>?,
      interpreter: interpreter,
    );
  }
}

class _SlideVerifyControl extends StatefulWidget {
  final double width;
  final double height;
  final String? bind;
  final String initialText;
  final String successText;
  final String? thumbImage;
  final Color backgroundColor;
  final Color fillColor;
  final Color borderColor;
  final Color initialTextColor;
  final Color successTextColor;
  final Map<String, dynamic>? onSuccess;
  final JsonInterpreter interpreter;

  const _SlideVerifyControl({
    required this.width,
    required this.height,
    required this.bind,
    required this.initialText,
    required this.successText,
    required this.thumbImage,
    required this.backgroundColor,
    required this.fillColor,
    required this.borderColor,
    required this.initialTextColor,
    required this.successTextColor,
    required this.onSuccess,
    required this.interpreter,
  });

  @override
  State<_SlideVerifyControl> createState() => _SlideVerifyControlState();
}

class _SlideVerifyControlState extends State<_SlideVerifyControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;
  double _initialGlobalX = 0;
  double _moveDistance = 0;
  bool _verified = false;
  bool _enabled = true;

  double get _sliderWidth => widget.height - 4;
  double get _maxDistance => widget.width - _sliderWidth;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut)
      ..addListener(() {
        setState(() {
          _moveDistance = _moveDistance - _moveDistance * _curve.value;
          if (_moveDistance <= 0) _moveDistance = 0;
        });
      });
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _enabled = true;
        _controller.reset();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _markSuccess(BuildContext context) {
    if (_verified) return;
    _verified = true;
    if (widget.bind != null) {
      widget.interpreter.setVariable(widget.bind!, true);
    }
    final action = widget.onSuccess;
    if (action != null) {
      widget.interpreter.executeAction(action, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: (details) {
        if (!_enabled) return;
        _initialGlobalX = details.globalPosition.dx;
      },
      onHorizontalDragUpdate: (details) {
        if (!_enabled) return;
        _moveDistance = details.globalPosition.dx - _initialGlobalX;
        if (_moveDistance < 0) _moveDistance = 0;
        if (_moveDistance > _maxDistance) {
          _moveDistance = _maxDistance;
          _enabled = false;
          _markSuccess(context);
        }
        setState(() {});
      },
      onHorizontalDragEnd: (_) {
        if (_enabled) {
          _enabled = false;
          _controller.forward();
        }
      },
      child: Container(
        width: widget.width,
        height: widget.height,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          border: Border.all(color: widget.borderColor),
          borderRadius: BorderRadius.circular(widget.height),
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
                color: widget.fillColor,
              ),
            ),
            Center(
              child: Text(
                _verified ? widget.successText : widget.initialText,
                style: TextStyle(
                  fontSize: 14,
                  color: _verified
                      ? widget.successTextColor
                      : widget.initialTextColor,
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
                  borderRadius: BorderRadius.circular(_sliderWidth),
                ),
                child: _buildThumb(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumb() {
    final image = widget.thumbImage;
    if (image == null || image.isEmpty) return const SizedBox.shrink();
    return Image.network(
      image,
      height: _sliderWidth,
      width: _sliderWidth,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}

class JsonCodeInputWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final length = (_resolveDouble(interpreter, json['length']) ?? 6).toInt();
    final bind = json['bind']?.toString();
    final focusId = json['focusId']?.toString();
    final style = json['style']?.toString() ?? 'rectangle';
    return _CodeInputControl(
      length: length.clamp(1, 12),
      focusNode: focusId == null || focusId.isEmpty
          ? null
          : interpreter.getFocusNode(focusId),
      controller: interpreter.getTextController(
        bind ?? '_code_input_${identityHashCode(json)}',
        bind == null ? '' : interpreter.getVariable(bind)?.toString() ?? '',
      ),
      keyboardType: json['keyboardType']?.toString() == 'number'
          ? TextInputType.number
          : TextInputType.text,
      digitsOnly: json['digitsOnly'] != false,
      style: style,
      horizontalPadding:
          _resolveDouble(interpreter, json['horizontalPadding']) ?? 16,
      innerInset: _resolveDouble(interpreter, json['innerInset']) ?? 10,
      borderColor:
          _parseColor(json['borderColor']?.toString()) ??
          Theme.of(context).primaryColor,
      textColor:
          _parseColor(json['textColor']?.toString()) ??
          Theme.of(context).primaryColor,
      bind: bind,
      onChanged:
          resolveActionAtBuildTime(json['onChanged'], interpreter)
              as Map<String, dynamic>?,
      onFilled:
          resolveActionAtBuildTime(json['onFilled'], interpreter)
              as Map<String, dynamic>?,
      interpreter: interpreter,
    );
  }
}

class _CodeInputControl extends StatefulWidget {
  final int length;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputType keyboardType;
  final bool digitsOnly;
  final String style;
  final double horizontalPadding;
  final double innerInset;
  final Color borderColor;
  final Color textColor;
  final String? bind;
  final Map<String, dynamic>? onChanged;
  final Map<String, dynamic>? onFilled;
  final JsonInterpreter interpreter;

  const _CodeInputControl({
    required this.length,
    required this.controller,
    required this.focusNode,
    required this.keyboardType,
    required this.digitsOnly,
    required this.style,
    required this.horizontalPadding,
    required this.innerInset,
    required this.borderColor,
    required this.textColor,
    required this.bind,
    required this.onChanged,
    required this.onFilled,
    required this.interpreter,
  });

  @override
  State<_CodeInputControl> createState() => _CodeInputControlState();
}

class _CodeInputControlState extends State<_CodeInputControl> {
  late final FocusNode _node;
  bool _filledSent = false;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode();
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final formatters = <TextInputFormatter>[
      LengthLimitingTextInputFormatter(widget.length),
      if (widget.keyboardType == TextInputType.number && widget.digitsOnly)
        FilteringTextInputFormatter.digitsOnly,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final codeWidth =
            (availableWidth - widget.horizontalPadding * 2) / widget.length;
        return Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 0,
              height: 0,
              child: EditableText(
                controller: widget.controller,
                focusNode: _node,
                inputFormatters: formatters,
                keyboardType: widget.keyboardType,
                backgroundCursorColor: Colors.black,
                cursorColor: Colors.black,
                style: const TextStyle(),
                onChanged: (value) => _handleChanged(context, value),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (MediaQuery.viewInsetsOf(context).bottom == 0) {
                  final scope = FocusScope.of(context);
                  scope.requestFocus(FocusNode());
                  Future.delayed(
                    Duration.zero,
                    () => scope.requestFocus(_node),
                  );
                } else {
                  FocusScope.of(context).requestFocus(_node);
                }
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(widget.length, (index) {
                  final text = widget.controller.text;
                  final char = index < text.length ? text[index] : '';
                  if (widget.style == 'pin') {
                    return _buildPinCell(index, char, codeWidth);
                  }
                  return _buildRectangleCell(char, codeWidth);
                }),
              ),
            ),
          ],
        );
      },
    );
  }

  void _handleChanged(BuildContext context, String value) {
    if (widget.bind != null) {
      widget.interpreter.setVariable(widget.bind!, value);
    }
    if (widget.onChanged != null) {
      widget.interpreter.executeAction(widget.onChanged!, context);
    }
    if (value.length == widget.length) {
      if (!_filledSent && widget.onFilled != null) {
        widget.interpreter.executeAction(widget.onFilled!, context);
      }
      _filledSent = true;
    } else {
      _filledSent = false;
    }
    setState(() {});
  }

  Widget _buildRectangleCell(String char, double fullSize) {
    final innerSize = (fullSize - widget.innerInset * 2).clamp(0, fullSize);
    return SizedBox(
      width: fullSize,
      height: fullSize,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 50),
          width: innerSize.toDouble(),
          height: innerSize.toDouble(),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: widget.borderColor, width: 1),
          ),
          child: Text(
            char,
            style: TextStyle(
              color: widget.textColor,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPinCell(int index, String char, double fullSize) {
    const radius = Radius.circular(4);
    final side = BorderSide(width: 0.5, color: widget.borderColor);
    final decoration = BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.only(
        topLeft: index == 0 ? radius : Radius.zero,
        bottomLeft: index == 0 ? radius : Radius.zero,
        topRight: index == widget.length - 1 ? radius : Radius.zero,
        bottomRight: index == widget.length - 1 ? radius : Radius.zero,
      ),
      border: Border(
        top: side,
        left: index == 1 ? BorderSide.none : side,
        right: index == widget.length - 1 ? side : BorderSide.none,
        bottom: side,
      ),
    );
    return SizedBox(
      width: fullSize,
      height: fullSize,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        alignment: Alignment.center,
        decoration: decoration,
        child: Text(
          '•',
          style: TextStyle(
            color: char.isEmpty ? Colors.transparent : widget.textColor,
            fontSize: char.isEmpty ? 0 : 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class JsonTextScaleScopeWidget extends JsonBaseWidget {
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
    final factor = _resolveDouble(interpreter, json['scale']) ?? 1;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(factor.clamp(0.1, 10.0).toDouble()),
      ),
      child: child,
    );
  }
}

class JsonGestureSettingsScopeWidget extends JsonBaseWidget {
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
    final touchSlop = _resolveDouble(interpreter, json['touchSlop']);
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(gestureSettings: DeviceGestureSettings(touchSlop: touchSlop)),
      child: child,
    );
  }
}

double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final resolved = interpreter.evaluateExpression(value);
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
