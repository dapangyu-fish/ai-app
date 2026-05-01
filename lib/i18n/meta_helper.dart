// JSON-APP meta 字段解析帮手
// ──────────────────────────────────────────────────────────
// 处理 meta.displayName 的多语言支持。
//
// 规则：
//   1) meta.displayName 是字符串：直接用，所有 locale 一致
//   2) meta.displayName 是 Map<String, String>：按当前 locale 取，
//      取不到 → 取 defaultLocale → 取第一个 → 取 meta.name → 取 fallback
//   3) meta.displayName 为空：用 meta.name，再 fallback
//
// 例子：
//   "meta": {
//     "name": "todo-app",
//     "displayName": "待办清单"
//   }
//
//   "meta": {
//     "name": "todo-app",
//     "displayName": {
//       "zh": "待办清单",
//       "en": "Todo List",
//       "default": "Todo"
//     }
//   }

import 'package:flutter/widgets.dart';
import 'locale_controller.dart' show LocaleController, appLocale;

/// 解析 meta.displayName 为字符串。
/// [meta] 是 JSON-APP 的 meta 对象（可为空）
/// [fallback] 兜底（meta 都拿不到时用）
String resolveDisplayName(
  Map<String, dynamic>? meta, {
  String fallback = 'JSON App',
  Locale? locale,
}) {
  if (meta == null) return fallback;

  final displayName = meta['displayName'];
  final localeTag =
      (locale ?? appLocale.value)?.toLanguageTag() ??
          LocaleController.currentLocaleTag();
  final lang = _languageOf(localeTag);

  if (displayName is String && displayName.isNotEmpty) {
    return displayName;
  }

  if (displayName is Map) {
    // 优先精确 tag（zh-CN），再退到语言（zh），再退到 default / first
    final exact = displayName[localeTag];
    if (exact is String && exact.isNotEmpty) return exact;
    final byLang = displayName[lang];
    if (byLang is String && byLang.isNotEmpty) return byLang;
    final byDefault = displayName['default'];
    if (byDefault is String && byDefault.isNotEmpty) return byDefault;
    // 取第一个非空字符串
    for (final v in displayName.values) {
      if (v is String && v.isNotEmpty) return v;
    }
  }

  // 没 displayName，回退到 name
  final name = meta['name'];
  if (name is String && name.isNotEmpty) return name;

  return fallback;
}

String _languageOf(String tag) {
  final dash = tag.indexOf(RegExp(r'[-_]'));
  if (dash < 0) return tag;
  return tag.substring(0, dash);
}
