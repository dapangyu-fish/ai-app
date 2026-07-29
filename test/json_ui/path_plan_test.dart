import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_application_1/json_ui/path_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PathPlanCache lookup', () {
    test('distinguishes numeric Map keys, List indexes, null, and missing', () {
      final cache = PathPlanCache();
      final root = <String, dynamic>{
        'map': <String, dynamic>{
          '0': <String, dynamic>{'value': 'map value'},
        },
        'list': <dynamic>[
          <String, dynamic>{'value': 'list value'},
        ],
        'presentNull': null,
      };

      expect(cache.lookup(root, 'map.0.value').value, 'map value');
      expect(cache.lookup(root, 'list.0.value').value, 'list value');

      final presentNull = cache.lookup(root, 'presentNull');
      expect(presentNull.found, isTrue);
      expect(presentNull.value, isNull);

      final missing = cache.lookup(root, 'missing');
      expect(missing.found, isFalse);
      expect(missing.value, isNull);
    });

    test('rejects negative, non-numeric, and out-of-range List indexes', () {
      final cache = PathPlanCache();
      final root = <String, dynamic>{
        'list': <dynamic>['only'],
      };

      expect(cache.lookup(root, 'list.-1').found, isFalse);
      expect(cache.lookup(root, 'list.nope').found, isFalse);
      expect(cache.lookup(root, 'list.1').found, isFalse);
    });

    test('preserves empty path segments', () {
      final cache = PathPlanCache();
      final root = <String, dynamic>{
        '': 'empty root key',
        'nested': <String, dynamic>{'': 'empty nested key'},
      };

      expect(cache.lookup(root, '').value, 'empty root key');
      expect(cache.lookup(root, 'nested.').value, 'empty nested key');
    });

    test('plans observe subsequent mutations instead of caching values', () {
      final cache = PathPlanCache();
      final root = <String, dynamic>{
        'state': <String, dynamic>{'value': 1},
      };

      expect(cache.lookup(root, 'state.value').value, 1);
      (root['state'] as Map<String, dynamic>)['value'] = 2;
      expect(cache.lookup(root, 'state.value').value, 2);
    });
  });

  group('PathPlanCache write', () {
    test('writes Map keys and in-range List indexes', () {
      final cache = PathPlanCache();
      final root = <String, dynamic>{
        'numericMap': <String, dynamic>{'0': 'before'},
        'list': <dynamic>[
          <String, dynamic>{'value': 'before'},
        ],
      };

      expect(cache.write(root, 'numericMap.0', 'map after'), isTrue);
      expect(cache.write(root, 'list.0.value', 'list after'), isTrue);
      expect(cache.write(root, 'created.deep.value', 7), isTrue);

      expect((root['numericMap'] as Map<String, dynamic>)['0'], 'map after');
      expect(
        ((root['list'] as List)[0] as Map<String, dynamic>)['value'],
        'list after',
      );
      expect(cache.lookup(root, 'created.deep.value').value, 7);
    });

    test('does not expand Lists or replace scalar/null intermediates', () {
      final cache = PathPlanCache();
      final root = <String, dynamic>{
        'list': <dynamic>['only'],
        'nullParent': null,
        'scalarParent': 3,
      };

      expect(cache.write(root, 'list.-1', 'ignored'), isFalse);
      expect(cache.write(root, 'list.nope', 'ignored'), isFalse);
      expect(cache.write(root, 'list.1', 'ignored'), isFalse);
      expect(cache.write(root, 'nullParent.child', 'ignored'), isFalse);
      expect(cache.write(root, 'scalarParent.child', 'ignored'), isFalse);

      expect(root['list'], <dynamic>['only']);
      expect(root['nullParent'], isNull);
      expect(root['scalarParent'], 3);
    });
  });

  group('PathPlanCache bounds', () {
    test('never grows past capacity and can be cleared', () {
      final cache = PathPlanCache(capacity: 2);
      final root = <String, dynamic>{'a': 1, 'b': 2, 'c': 3};

      cache.lookup(root, 'a');
      cache.lookup(root, 'b');
      cache.lookup(root, 'c');

      expect(cache.cachedPlanCount, 2);
      expect(cache.lookup(root, 'a').value, 1);
      expect(cache.cachedPlanCount, 2);

      cache.clear();
      expect(cache.cachedPlanCount, 0);
    });

    test('rejects a non-positive capacity', () {
      expect(() => PathPlanCache(capacity: 0), throwsArgumentError);
      expect(() => PathPlanCache(capacity: -1), throwsArgumentError);
    });
  });

  group('JsonInterpreter path semantics', () {
    late JsonInterpreter interpreter;

    setUp(() {
      interpreter = JsonInterpreter()
        ..loadConfig(<String, dynamic>{
          'dsl': '4.0',
          'global': <String, dynamic>{
            'variables': <String, dynamic>{
              'presentNull': null,
              'numericMap': <String, dynamic>{'0': 'map value'},
              'items': <dynamic>[
                <String, dynamic>{'name': 'first'},
                <String, dynamic>{'name': 'second'},
              ],
              'nullParent': null,
              'scalarParent': 3,
            },
            'computed': <String, dynamic>{
              'presentNull': 'must stay shadowed',
              'derived': 'computed value',
            },
          },
        });
    });

    tearDown(() {
      interpreter.dispose();
    });

    test('preserves prefixes, numeric containers, and null shadowing', () {
      expect(interpreter.getVariable('global.numericMap.0'), 'map value');
      expect(interpreter.getVariable('global.items.0.name'), 'first');
      expect(interpreter.getVariable(r'$.global.items.1.name'), 'second');
      expect(interpreter.getVariable('global.presentNull'), isNull);
      expect(interpreter.getVariable('presentNull'), isNull);
      expect(interpreter.getVariable('global.derived'), 'computed value');
      expect(interpreter.getVariable('global.items.-1.name'), isNull);
      expect(interpreter.getVariable('global.items.nope.name'), isNull);
      expect(interpreter.getVariable('global.items.2.name'), isNull);
    });

    test('preserves nested Map/List write and no-op behavior', () {
      interpreter.setVariable('global.numericMap.0', 'map after');
      interpreter.setVariable('global.items.1.name', 'second after');
      interpreter.setVariable('global.created.deep.value', 7);
      interpreter.setVariable('global.items.9.name', 'ignored');
      interpreter.setVariable('global.nullParent.child', 'ignored');
      interpreter.setVariable('global.scalarParent.child', 'ignored');

      expect(interpreter.getVariable('global.numericMap.0'), 'map after');
      expect(interpreter.getVariable('global.items.1.name'), 'second after');
      expect(interpreter.getVariable('global.created.deep.value'), 7);
      expect(interpreter.getVariable('global.items'), hasLength(2));
      expect(interpreter.getVariable('global.nullParent'), isNull);
      expect(interpreter.getVariable('global.scalarParent'), 3);
    });

    test('a new app observes only its new values after the cache was hot', () {
      expect(interpreter.getVariable('global.items.0.name'), 'first');

      interpreter.loadConfig(<String, dynamic>{
        'dsl': '4.0',
        'global': <String, dynamic>{
          'variables': <String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{'name': 'new app'},
            ],
          },
        },
      });

      expect(interpreter.getVariable('global.items.0.name'), 'new app');
    });
  });
}
