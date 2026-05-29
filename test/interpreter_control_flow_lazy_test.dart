import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nested @for_each keeps inner loop templates lazy', () async {
    final interpreter = JsonInterpreter()
      ..loadConfig({
        'global': {
          'variables': {'last': null, 'pairs': <dynamic>[]},
        },
        'steps': [
          {
            'type': 'call',
            'call': '@for_each',
            'args': {
              'source': [1, 2],
              'body': [
                {
                  'type': 'call',
                  'call': '@for_each',
                  'args': {
                    'source': ['a', 'b'],
                    'body': [
                      {
                        'type': 'call',
                        'call': '@set',
                        'args': {
                          'var': 'global.last',
                          'value': '{{ loop.item }}',
                        },
                      },
                      {
                        'type': 'call',
                        'call': '@list_add',
                        'args': {
                          'var': 'global.pairs',
                          'item': '{{ loop.item }}',
                        },
                      },
                    ],
                  },
                },
              ],
            },
          },
        ],
      });

    await interpreter.executeSteps();

    expect(interpreter.getVariable('global.last'), 'b');
    expect(interpreter.getVariable('global.pairs'), ['a', 'b', 'a', 'b']);
  });
}
