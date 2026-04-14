// 抽象基类：所有 JSON DSL 控件必须继承此类。
// 每个控件接收对应的 JSON 节点、解释器上下文，返回 Flutter Widget。
import 'package:flutter/material.dart';
import '../interpreter.dart';

abstract class JsonBaseWidget {
  /// 根据 JSON 配置构建 Flutter Widget
  ///
  /// [context] Flutter BuildContext
  /// [json] 当前控件的 JSON 配置节点
  /// [interpreter] JSON 解释器实例，提供变量读写、模板解析、action 执行等能力
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  );
}
