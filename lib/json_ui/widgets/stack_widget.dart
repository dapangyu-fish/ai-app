// Stack 控件
// 支持: children, alignment (子项默认对齐), fit (loose/expand, 默认 loose),
//       clipBehavior (none/hardEdge/antiAlias)
// 子项可通过 position.type=absolute 配合 top/left/bottom/right 精确定位
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonStackWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = json['children'] as List<dynamic>? ?? [];
    final alignment = _parseAlignment(json['alignment']?.toString());
    final fit = json['fit']?.toString() == 'expand'
        ? StackFit.expand
        : StackFit.loose;
    final clipBehavior = _parseClipBehavior(json['clipBehavior']?.toString());

    final childWidgets = children
        .whereType<Map<String, dynamic>>()
        .map((c) => interpreter.buildWidget(context, c))
        .toList();

    return Stack(
      alignment: alignment,
      fit: fit,
      clipBehavior: clipBehavior,
      children: childWidgets,
    );
  }

  AlignmentDirectional _parseAlignment(String? s) {
    switch (s) {
      case 'topStart':
        return AlignmentDirectional.topStart;
      case 'topCenter':
        return AlignmentDirectional.topCenter;
      case 'topEnd':
        return AlignmentDirectional.topEnd;
      case 'centerStart':
        return AlignmentDirectional.centerStart;
      case 'centerEnd':
        return AlignmentDirectional.centerEnd;
      case 'bottomStart':
        return AlignmentDirectional.bottomStart;
      case 'bottomCenter':
        return AlignmentDirectional.bottomCenter;
      case 'bottomEnd':
        return AlignmentDirectional.bottomEnd;
      case 'center':
        return AlignmentDirectional.center;
      case 'topStart':
      default:
        return AlignmentDirectional.topStart;
    }
  }

  Clip _parseClipBehavior(String? s) {
    switch (s) {
      case 'none':
        return Clip.none;
      case 'antiAlias':
        return Clip.antiAlias;
      case 'antiAliasWithSaveLayer':
        return Clip.antiAliasWithSaveLayer;
      case 'hardEdge':
      default:
        return Clip.hardEdge;
    }
  }
}
