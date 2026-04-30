// Wrap 控件
// 支持: children, spacing (横向), runSpacing (纵向), alignment, runAlignment,
//       direction (horizontal/vertical)
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonWrapWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = json['children'] as List<dynamic>? ?? [];
    final spacing = (json['spacing'] as num?)?.toDouble() ?? 8;
    final runSpacing = (json['runSpacing'] as num?)?.toDouble() ?? 8;
    final direction = json['direction']?.toString() == 'vertical'
        ? Axis.vertical
        : Axis.horizontal;

    final alignment = _parseWrapAlignment(json['alignment']?.toString());
    final runAlignment = _parseWrapAlignment(json['runAlignment']?.toString());
    final crossAlignment =
        _parseWrapCrossAlignment(json['crossAlignment']?.toString());

    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((c) => interpreter.buildWidget(context, c))
        .toList();

    return Wrap(
      direction: direction,
      spacing: spacing,
      runSpacing: runSpacing,
      alignment: alignment,
      runAlignment: runAlignment,
      crossAxisAlignment: crossAlignment,
      children: childWidgets,
    );
  }

  WrapAlignment _parseWrapAlignment(String? s) {
    switch (s) {
      case 'center':
        return WrapAlignment.center;
      case 'end':
        return WrapAlignment.end;
      case 'spaceBetween':
        return WrapAlignment.spaceBetween;
      case 'spaceAround':
        return WrapAlignment.spaceAround;
      case 'spaceEvenly':
        return WrapAlignment.spaceEvenly;
      default:
        return WrapAlignment.start;
    }
  }

  WrapCrossAlignment _parseWrapCrossAlignment(String? s) {
    switch (s) {
      case 'center':
        return WrapCrossAlignment.center;
      case 'end':
        return WrapCrossAlignment.end;
      default:
        return WrapCrossAlignment.start;
    }
  }
}
