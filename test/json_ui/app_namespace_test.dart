import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/json_ui/interpreter.dart';
import 'package:myapp/config/app_config.dart';

/// The framework exposes a read-only `app` namespace so JSON-APPs can read the
/// current platform addresses (and build URLs explicitly) instead of relying on
/// the http client silently prepending the backend, or hardcoding a domain.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  JsonInterpreter newInterp() => JsonInterpreter()
    ..loadConfig(<String, dynamic>{
      'dsl': '3.3',
      'appid': '00000000-0000-4000-8000-000000000000',
      'meta': <String, dynamic>{
        'name': 'app_ns_test',
        'version': '1.0.0',
        'type': 'app',
      },
      'global': <String, dynamic>{'variables': <String, dynamic>{}},
      'ui': <String, dynamic>{'screens': <dynamic>[]},
    });

  test('getVariable resolves app.* from AppConfig', () {
    final interp = newInterp();
    expect(interp.getVariable('app.backendUrl'), AppConfig.backendUrl);
    expect(interp.getVariable('app.supabaseUrl'), AppConfig.supabaseUrl);
    expect(interp.getVariable('app.registryUrl'), AppConfig.registryUrl);
    expect(interp.getVariable('app.minioUrl'), AppConfig.minioUrl);
    expect(interp.getVariable('app.imApiUrl'), AppConfig.imApiUrl);
    // unknown key is graceful (null), not a crash
    expect(interp.getVariable('app.nope'), isNull);
  });

  test('templates interpolate {{ app.backendUrl }}', () {
    final interp = newInterp();
    expect(interp.resolveTemplate('{{ app.backendUrl }}'), AppConfig.backendUrl);
    // this is exactly how lib_faas builds a full invoke URL
    expect(
      interp.resolveTemplate('{{ app.backendUrl }}/api/faas/invoke/svc-x/ping'),
      '${AppConfig.backendUrl}/api/faas/invoke/svc-x/ping',
    );
  });
}
