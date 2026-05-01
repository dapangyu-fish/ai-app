// Spacer 控件
// 支持：
//   - height / width 固定间距（适合 Column / Row 间隔）
//   - flex 弹性占位（仅在 Flex 父容器内有效）
//   - 不写任何字段时默认 flex=1（弹性，跟 Flutter Spacer 一致）
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
    final flex = (json['flex'] as num?)?.toInt();

    // 显式 flex
    if (flex != null) return Spacer(flex: flex);

    // 显式尺寸
    if (height != null || width != null) {
      return SizedBox(height: height, width: width);
    }

    // 默认弹性（在 Row/Column 内顶开两端；非 Flex 内会抛错——属于使用错误）
    return const Spacer();
  }
}
