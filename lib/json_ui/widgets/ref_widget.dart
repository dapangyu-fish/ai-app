// Ref 控件
// 引用依赖模块中的 widget template，传入 props 渲染
// 用法: { "type": "ref", "from": "depName", "widget": "templateName", "props": {...} }
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';
import '../../i18n/framework_strings.dart';

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
      return _errorWidget(context, T.of(context).widgetRefMissingFromOrName);
    }

    // 从依赖加载器查找模板
    final template = interpreter.depLoader.findTemplate(from, widgetName);
    if (template == null) {
      return _errorWidget(
        context,
        T.fmt(T.of(context).widgetRefNotFoundWith, {
          'ref': '$from.$widgetName',
        }),
      );
    }

    // 获取模板的 root 节点
    final root = template['root'] as Map<String, dynamic>?;
    if (root == null) {
      return _errorWidget(
        context,
        T.fmt(T.of(context).widgetRefMissingRootWith, {
          'ref': '$from.$widgetName',
        }),
      );
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

    final mergedProps = _applyPropDefaults(
      template,
      resolvedProps,
      interpreter,
    );

    // 将 props 注入到模板中（递归替换 {{ props.xxx }}，并支持只引用
    // props 的 jsonlogic 默认值表达式）。
    final resolved = _injectProps(root, mergedProps, interpreter);

    // 用解释器构建最终 widget
    if (resolved is Map<String, dynamic>) {
      return interpreter.buildWidget(context, resolved);
    }

    return const SizedBox.shrink();
  }

  Map<String, dynamic> _applyPropDefaults(
    Map<String, dynamic> template,
    Map<String, dynamic> props,
    JsonInterpreter interpreter,
  ) {
    final defaults = _extractPropDefaults(template);
    if (defaults.isEmpty) return props;

    final merged = Map<String, dynamic>.from(props);
    for (final entry in defaults.entries) {
      if (merged.containsKey(entry.key) && merged[entry.key] != null) {
        continue;
      }
      merged[entry.key] = _injectProps(entry.value, merged, interpreter);
    }
    return merged;
  }

  Map<String, dynamic> _extractPropDefaults(Map<String, dynamic> template) {
    final defaults = <String, dynamic>{};

    final propSpec = template['props'];
    if (propSpec is Map<String, dynamic>) {
      for (final entry in propSpec.entries) {
        final spec = entry.value;
        if (spec is Map<String, dynamic> && spec.containsKey('default')) {
          defaults[entry.key] = spec['default'];
        }
      }
    }

    for (final key in const ['defaults', 'defaultProps', 'propsDefaults']) {
      final value = template[key];
      if (value is Map<String, dynamic>) {
        defaults.addAll(value);
      }
    }
    return defaults;
  }

  /// 递归将 {{ props.xxx }} 替换为实际 props 值。
  ///
  /// Map 形式的 jsonlogic 只在完全由 props 驱动时求值；event/loop/global
  /// 仍留给运行时解释器，避免在 build 阶段提前解析。
  dynamic _injectProps(
    dynamic node,
    Map<String, dynamic> props,
    JsonInterpreter interpreter,
  ) {
    if (node is String) {
      // 完整匹配 {{ props.xxx }}。`[^{}]` 而非 `.+?`：避免「{{ props.a }}/{{ props.b }}」
      // 这种混合模板被整体误匹配 → 落到下面的逐个插值。（同 interpreter.resolveExpression）
      final exactMatch = RegExp(
        r'^\{\{\s*props\.([^{}]+?)\s*\}\}$',
      ).firstMatch(node);
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
      if (interpreter.looksLikeJsonLogic(node) && _onlyReferencesProps(node)) {
        return interpreter.evaluateJsonLogicWithLocals(node, {'props': props});
      }
      return node.map(
        (k, v) => MapEntry(k, _injectProps(v, props, interpreter)),
      );
    }

    if (node is List) {
      return node.map((e) => _injectProps(e, props, interpreter)).toList();
    }

    return node;
  }

  bool _onlyReferencesProps(dynamic node) {
    bool walk(dynamic value) {
      if (value is Map<String, dynamic>) {
        if (value.length == 1 && value.containsKey('var')) {
          final ref = value['var'];
          if (ref is String) return ref.startsWith('props.');
          if (ref is List && ref.isNotEmpty && ref.first is String) {
            if (!(ref.first as String).startsWith('props.')) return false;
            for (var i = 1; i < ref.length; i += 1) {
              if (!walk(ref[i])) return false;
            }
            return true;
          }
          return false;
        }
        for (final entry in value.entries) {
          if (!walk(entry.value)) return false;
        }
        return true;
      }
      if (value is List) {
        for (final item in value) {
          if (!walk(item)) return false;
        }
      }
      return true;
    }

    return walk(node);
  }

  Widget _errorWidget(BuildContext context, String message) {
    return Container(
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.3),
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
