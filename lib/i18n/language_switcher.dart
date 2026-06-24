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
                'fr' => t.settingsLanguageFr,
                'pt' => t.settingsLanguagePt,
                'ca' => t.settingsLanguageCa,
                'hi' => t.settingsLanguageHi,
                'ko' => t.settingsLanguageKo,
                'ja' => t.settingsLanguageJa,
                'it' => t.settingsLanguageIt,
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
    isScrollControlled: true, // 11 种语言 + 系统，列表可能高于默认半屏；允许更高并滚动
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

            final tiles = <Widget>[
              tile(const Locale('zh', 'CN'), t.settingsLanguageZh),
              tile(const Locale('en', 'US'), t.settingsLanguageEn),
              tile(const Locale('de', 'DE'), t.settingsLanguageDe),
              tile(const Locale('es', 'ES'), t.settingsLanguageEs),
              tile(const Locale('fr', 'FR'), t.settingsLanguageFr),
              tile(const Locale('pt', 'PT'), t.settingsLanguagePt),
              tile(const Locale('ca', 'ES'), t.settingsLanguageCa),
              tile(const Locale('hi', 'IN'), t.settingsLanguageHi),
              tile(const Locale('ko', 'KR'), t.settingsLanguageKo),
              tile(const Locale('ja', 'JP'), t.settingsLanguageJa),
              tile(const Locale('it', 'IT'), t.settingsLanguageIt),
              tile(null, t.settingsLanguageSystem),
            ];
            return ConstrainedBox(
              // 上限 80% 屏高；超出时列表内部滚动（修复宽屏/横屏看不到下方项）
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetCtx).size.height * 0.8,
              ),
              child: Column(
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
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: tiles,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}
