// Align 控件
// 支持: alignment (topLeft / topCenter / topRight / centerLeft / center /
//       centerRight / bottomLeft / bottomCenter / bottomRight),
//       widthFactor, heightFactor, child
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonAlignWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final alignment = _parseAlignment(json['alignment']?.toString());
    final widthFactor = (json['widthFactor'] as num?)?.toDouble();
    final heightFactor = (json['heightFactor'] as num?)?.toDouble();

    final childJson = json['child'];
    Widget child;
    if (childJson is Map<String, dynamic>) {
      child = interpreter.buildWidget(context, childJson);
    } else {
      child = const SizedBox.shrink();
    }

    return Align(
      alignment: alignment,
      widthFactor: widthFactor,
      heightFactor: heightFactor,
      child: child,
    );
  }

  Alignment _parseAlignment(String? s) {
    switch (s) {
      case 'topLeft':
        return Alignment.topLeft;
      case 'topCenter':
        return Alignment.topCenter;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomRight':
        return Alignment.bottomRight;
      case 'center':
      default:
        return Alignment.center;
    }
  }
}
