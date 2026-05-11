// 通用语言切换器组件
// ──────────────────────────────────────────────────────────
// 两种用法：
//   1) IconButton 形式（默认）：放在 AppBar / 自由位置，点击弹 bottom sheet
//        LanguageSwitcher()
//   2) ListTile 形式（设置页用）：
//        LanguageSwitcher.tile()
//
// 选项：中文 / English / 跟随系统

import 'package:flutter/material.dart';
import 'framework_strings.dart';
import 'locale_controller.dart';

class LanguageSwitcher extends StatelessWidget {
  /// IconButton 模式（默认）
  const LanguageSwitcher({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurface;
    return IconButton(
      icon: Icon(Icons.language, color: tint),
      tooltip: T.of(context).language,
      onPressed: () => showLanguagePicker(context),
    );
  }

  /// ListTile 模式（设置页用），自带当前选中态。
  static Widget tile(BuildContext context) {
    return ValueListenableBuilder<Locale?>(
      valueListenable: appLocale,
      builder: (context, locale, _) {
        final t = T.of(context);
        final subtitle = locale == null
            ? t.settingsLanguageSystem
            : switch (locale.languageCode) {
                'en' => t.settingsLanguageEn,
                'de' => t.settingsLanguageDe,
                'es' => t.settingsLanguageEs,
                _ => t.settingsLanguageZh,
              };
        return ListTile(
          leading: const Icon(Icons.language),
          title: Text(t.settingsLanguage),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLanguagePicker(context),
        );
      },
    );
  }
}

/// 弹起 bottom sheet 让用户选 locale。可在任意位置调用。
Future<void> showLanguagePicker(BuildContext context) async {
  final t = T.of(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) {
      return SafeArea(
        child: ValueListenableBuilder<Locale?>(
          valueListenable: appLocale,
          builder: (sheetCtx, current, _) {
            Widget tile(Locale? value, String label) {
              final selected = current != null &&
                  value != null &&
                  current.languageCode == value.languageCode;
              final isSystem = value == null && current == null;
              return ListTile(
                leading: Icon(
                  selected || isSystem
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: (selected || isSystem)
                      ? Theme.of(sheetCtx).colorScheme.primary
                      : null,
                ),
                title: Text(label),
                onTap: () async {
                  await LocaleController.setLocale(value);
                  if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                },
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      t.settingsLanguage,
                      style: Theme.of(sheetCtx).textTheme.titleMedium,
                    ),
                  ),
                ),
                tile(const Locale('zh', 'CN'), t.settingsLanguageZh),
                tile(const Locale('en', 'US'), t.settingsLanguageEn),
                tile(const Locale('de', 'DE'), t.settingsLanguageDe),
                tile(const Locale('es', 'ES'), t.settingsLanguageEs),
                tile(null, t.settingsLanguageSystem),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      );
    },
  );
}
