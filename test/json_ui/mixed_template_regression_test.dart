import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/json_ui/interpreter.dart';

/// Regression for the resolveExpression bug: a mixed/multi template that STARTS
/// with `{{` and ENDS with `}}` (e.g. lib_faas's invoke URL) used to be matched
/// whole by the `^\{\{(.+?)\}\}$` single-expression regex → garbage var path →
/// null. The fix tightens it to `[^{}]+?` so such templates fall through to
/// per-occurrence interpolation, while a true single `{{ x }}` still returns the
/// raw (non-stringified) value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  JsonInterpreter mk() => JsonInterpreter()
    ..loadConfig(<String, dynamic>{
      'dsl': '3.3',
      'appid': '00000000-0000-4000-8000-000000000000',
      'meta': <String, dynamic>{'name': 't', 'version': '1.0.0', 'type': 'app'},
      'global': <String, dynamic>{
        'variables': <String, dynamic>{
          'a': 'X',
          'b': 'Y',
          'svc': 'svc-77be07ffad7b',
          'obj': <String, dynamic>{'k': 1},
          'list': <dynamic>[1, 2],
        }
      },
      'ui': <String, dynamic>{'screens': <dynamic>[]},
    });

  test('mixed template that ENDS with }} interpolates (was null)', () {
    final i = mk();
    expect(i.resolveExpression('{{ global.a }} {{ global.b }}'), 'X Y');
    // exact lib_faas shape: starts with {{ … ends with }}
    expect(
      i.resolveExpression('{{ global.a }}/api/faas/invoke/{{ global.svc }}{{ global.b }}'),
      'X/api/faas/invoke/svc-77be07ffad7bY',
    );
    // mixed but ends with text still worked before; must still work
    expect(
      i.resolveExpression('{{ global.svc }}/ping'),
      'svc-77be07ffad7b/ping',
    );
  });

  test('single {{ x }} still returns the RAW value (not stringified)', () {
    final i = mk();
    expect(i.resolveExpression('{{ global.list }}'), <dynamic>[1, 2]);
    expect(i.resolveExpression('{{ global.obj }}'), <String, dynamic>{'k': 1});
    expect(i.resolveExpression('{{ global.a }}'), 'X');
    // missing var → null (unchanged)
    expect(i.resolveExpression('{{ global.missing }}'), isNull);
  });
}
