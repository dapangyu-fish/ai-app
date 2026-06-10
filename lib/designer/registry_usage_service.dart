import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_service.dart';
import '../config/app_config.dart';

class RegistryUsageService {
  RegistryUsageService._();

  static const String _guestInstallClientKey = 'registry_install_client_id';

  static Future<void> recordRun(
    String packageName, {
    String source = 'run',
  }) async {
    final name = packageName.trim();
    if (name.isEmpty) return;

    try {
      final token = AuthService.token;
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final body = <String, Object?>{
        'source': source,
        'runtime': kIsWeb ? 'web' : 'client',
        'client_user_id': await _guestInstallClientId(),
      };
      await http
          .post(
            _packageInstallUri(name),
            headers: headers,
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Usage counters must never block running a JSON app.
    }
  }

  static Uri _packageInstallUri(String packageName) {
    final encodedName = packageName
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return Uri.parse('${AppConfig.registryUrl}/packages/$encodedName/install');
  }

  static Future<String> _guestInstallClientId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_guestInstallClientKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final id =
        'guest:${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    await prefs.setString(_guestInstallClientKey, id);
    return id;
  }
}
