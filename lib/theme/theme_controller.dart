import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Framework-wide theme mode state.
///
/// `ThemeMode.system` follows the OS. Explicit light/dark choices are persisted
/// and applied by MaterialApp at startup.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

class ThemeController {
  static const String _prefsKey = 'app_theme_mode';
  static const String _systemValue = 'system';

  static Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      appThemeMode.value = parseMode(prefs.getString(_prefsKey));
    } catch (_) {
      appThemeMode.value = ThemeMode.system;
    }
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    appThemeMode.value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, modeTag(mode));
    } catch (_) {
      // In-memory state already changed; persistence failure should not block UI.
    }
  }

  static ThemeMode parseMode(String? value) {
    switch (value?.toLowerCase()) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case _systemValue:
      default:
        return ThemeMode.system;
    }
  }

  static String modeTag(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => _systemValue,
    };
  }
}
