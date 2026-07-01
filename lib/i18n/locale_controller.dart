// 框架级 locale 状态管理
// ──────────────────────────────────────────────────────────
// MaterialApp 通过 ValueListenableBuilder 监听 appLocale；
// 一变就刷整个 framework UI。
//
// 状态约定：
//   value == null  → 跟随系统（MaterialApp.locale = null 走 OS）
//   value != null  → 强制使用该 locale（持久化在 SharedPreferences）
//
// 单向同步规则（重要）：
//   - 框架 → app：在 interpreter.loadConfig 时一次性把 currentLocaleTag()
//                  写到 global.locale；之后两边各自独立。
//   - app → 框架：app 调 @set_locale 不会反向影响 appLocale。
//
// 持久化 key：app_locale，值是 BCP 47 tag（zh-CN / en-US），
// 或者 'system' 表示跟随系统。

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'framework_strings.dart';

/// 全局 locale notifier。MaterialApp.locale 直接监听它。
final ValueNotifier<Locale?> appLocale = ValueNotifier<Locale?>(null);

class LocaleController {
  static const String _prefsKey = 'app_locale';
  static const String _systemValue = 'system';

  /// 在 main() 启动早期调用，从 SharedPreferences 恢复用户的选择
  static Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw == _systemValue) {
        appLocale.value = null; // 跟随系统
        return;
      }
      final parsed = _parseTag(raw);
      if (parsed != null) {
        appLocale.value = parsed;
      }
    } catch (_) {
      // SharedPreferences 启动早期偶发失败时容忍；停在默认值（null = 跟随系统）
    }
  }

  /// 启动时优先用 URL 的 ?lang=xx（Web 内嵌场景：官网把当前语言透传进 iframe，
  /// 如 https://myapp-web.dapangyu.work/?lang=de），命中且受支持则用它并持久化；
  /// 否则回退到 SharedPreferences 里保存的选择。Uri.base 在非 Web 上无 query，天然 no-op。
  static Future<void> loadFromUrlOrPrefs() async {
    try {
      final q = Uri.base.queryParameters['lang'];
      if (q != null && q.trim().isNotEmpty) {
        final parsed = _parseTag(q.trim());
        if (parsed != null && _isSupported(parsed)) {
          await setLocale(parsed);
          return;
        }
      }
    } catch (_) {
      // URL 解析异常时忽略，走 prefs
    }
    await loadFromPrefs();
  }

  static bool _isSupported(Locale l) {
    for (final s in T.supportedLocales) {
      if (s.languageCode.toLowerCase() == l.languageCode.toLowerCase()) return true;
    }
    return false;
  }

  /// 切换 locale 并持久化。传 null 表示跟随系统。
  static Future<void> setLocale(Locale? locale) async {
    appLocale.value = locale;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (locale == null) {
        await prefs.setString(_prefsKey, _systemValue);
      } else {
        await prefs.setString(_prefsKey, locale.toLanguageTag());
      }
    } catch (_) {
      // 持久化失败不影响内存状态
    }
  }

  /// 取当前生效的 locale 字符串（BCP 47），用于 interpreter 初始化。
  /// appLocale 为 null 时返回系统 locale 的 tag。
  static String currentLocaleTag() {
    final v = appLocale.value;
    if (v != null) return v.toLanguageTag();
    // 跟随系统：从 PlatformDispatcher 读
    final sys = WidgetsBinding.instance.platformDispatcher.locale;
    return sys.toLanguageTag();
  }

  /// 取当前生效的、且**框架支持**的 locale。
  /// 如果系统语言不在 supportedLocales 里，回退到第一个 supported（zh-CN）。
  /// 用在 MaterialApp.localeResolutionCallback 等需要确定 locale 的位置。
  static Locale resolveSupportedLocale() {
    final tag = currentLocaleTag();
    for (final l in T.supportedLocales) {
      if (tag.toLowerCase().startsWith(l.languageCode.toLowerCase())) {
        return l;
      }
    }
    return T.supportedLocales.first;
  }

  static Locale? _parseTag(String tag) {
    final parts = tag.replaceAll('_', '-').split('-');
    if (parts.isEmpty || parts[0].isEmpty) return null;
    if (parts.length == 1) return Locale(parts[0]);
    return Locale(parts[0], parts[1]);
  }
}
