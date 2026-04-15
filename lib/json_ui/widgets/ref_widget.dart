// Ref 控件
// 引用依赖模块中的 widget template，传入 props 渲染
// 用法: { "type": "ref", "from": "depName", "widget": "templateName", "props": {...} }
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonRefWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final from = json['from'] as String?;
    final widgetName = json['widget'] as String?;
    final props = json['props'] as Map<String, dynamic>? ?? {};

    if (from == null || widgetName == null) {
      return _errorWidget(context, 'ref 控件需要 from 和 widget 字段');
    }

    // 从依赖加载器查找模板
    final template = interpreter.depLoader.findTemplate(from, widgetName);
    if (template == null) {
      return _errorWidget(context, '未找到: $from.$widgetName');
    }

    // 获取模板的 root 节点
    final root = template['root'] as Map<String, dynamic>?;
    if (root == null) {
      return _errorWidget(context, '$from.$widgetName 缺少 root 定义');
    }

    // 解析 props 中的模板表达式
    final resolvedProps = <String, dynamic>{};
    for (final entry in props.entries) {
      if (entry.value is String) {
        resolvedProps[entry.key] = interpreter.resolveExpression(entry.value);
      } else {
        resolvedProps[entry.key] = entry.value;
      }
    }

    // 将 props 注入到模板中（递归替换 {{ props.xxx }}）
    final resolved = _injectProps(root, resolvedProps);

    // 用解释器构建最终 widget
    if (resolved is Map<String, dynamic>) {
      return interpreter.buildWidget(context, resolved);
    }

    return const SizedBox.shrink();
  }

  /// 递归将 {{ props.xxx }} 替换为实际 props 值
  dynamic _injectProps(dynamic node, Map<String, dynamic> props) {
    if (node is String) {
      // 完整匹配 {{ props.xxx }}
      final exactMatch = RegExp(r'^\{\{\s*props\.(.+?)\s*\}\}$').firstMatch(node);
      if (exactMatch != null) {
        final key = exactMatch.group(1)!;
        return props[key] ?? node;
      }
      // 部分匹配 — 字符串插值
      return node.replaceAllMapped(
        RegExp(r'\{\{\s*props\.(.+?)\s*\}\}'),
        (match) => props[match.group(1)!]?.toString() ?? '',
      );
    }

    if (node is Map<String, dynamic>) {
      return node.map((k, v) => MapEntry(k, _injectProps(v, props)));
    }

    if (node is List) {
      return node.map((e) => _injectProps(e, props)).toList();
    }

    return node;
  }

  Widget _errorWidget(BuildContext context, String message) {
    return Container(
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'ref: $message',
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
      ),
    );
  }
}
