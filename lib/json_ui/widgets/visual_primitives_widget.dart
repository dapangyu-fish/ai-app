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
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, -1),
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
