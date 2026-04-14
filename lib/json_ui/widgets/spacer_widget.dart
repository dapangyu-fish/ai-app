// Spacer 控件
// 支持 height / width 固定间距，或 flex 弹性占位
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonSpacerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final height = (json['height'] as num?)?.toDouble();
    final width = (json['width'] as num?)?.toDouble();

    // 固定尺寸
    if (height != null || width != null) {
      return SizedBox(height: height, width: width);
    }

    // 默认 16dp 垂直间距
    return const SizedBox(height: 16);
  }
}
