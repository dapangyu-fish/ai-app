import 'dart:convert';

import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('compiled JSONLogic compatibility', () {
    late JsonInterpreter interpreter;

    setUp(() {
      interpreter = JsonInterpreter();
    });

    tearDown(() {
      interpreter.dispose();
    });

    test('matches the legacy engine for standard operators', () {
      final cases = <Map<String, dynamic>>[
        <String, dynamic>{'var': 'global.score'},
        <String, dynamic>{
          'var': <dynamic>['global.absent', 17],
        },
        <String, dynamic>{
          'var': <dynamic>[
            <String, dynamic>{
              'cat': <dynamic>['global.', 'dynamicKey'],
            },
            'fallback',
          ],
        },
        <String, dynamic>{
          'if': <dynamic>[
            <String, dynamic>{
              '>': <dynamic>[3, 2],
            },
            'yes',
            'no',
          ],
        },
        <String, dynamic>{
          'and': <dynamic>[
            1,
            <String, dynamic>{'var': 'global.label'},
            0,
            'unreached',
          ],
        },
        <String, dynamic>{
          'or': <dynamic>[
            '',
            0,
            <String, dynamic>{'var': 'global.label'},
          ],
        },
        <String, dynamic>{
          '==': <dynamic>[true, 1],
        },
        <String, dynamic>{
          '!=': <dynamic>[
            <dynamic>[1, 2],
            '[1,2]',
          ],
        },
        <String, dynamic>{
          '===': <dynamic>[1, 1.0],
        },
        <String, dynamic>{
          '!==': <dynamic>[null],
        },
        <String, dynamic>{
          '+': <dynamic>[1, '2.5', 3],
        },
        <String, dynamic>{
          '-': <dynamic>[10, 3, 1000],
        },
        <String, dynamic>{
          '-': <dynamic>[5],
        },
        <String, dynamic>{
          '*': <dynamic>[2, 3, '4'],
        },
        <String, dynamic>{
          '/': <dynamic>[9, 2],
        },
        <String, dynamic>{
          '%': <dynamic>[9, 4],
        },
        <String, dynamic>{
          '<': <dynamic>[1, 2, 3],
        },
        <String, dynamic>{
          '<=': <dynamic>[1, 1, 2],
        },
        <String, dynamic>{
          '>': <dynamic>[3, 2, 1],
        },
        <String, dynamic>{
          '>=': <dynamic>[3, 3, 1],
        },
        <String, dynamic>{
          'min': <dynamic>[8, -2, 4],
        },
        <String, dynamic>{
          'max': <dynamic>[8, -2, 4],
        },
        <String, dynamic>{
          'missing': <dynamic>['global.score', 'global.absent'],
        },
        <String, dynamic>{
          'missing_some': <dynamic>[
            2,
            <dynamic>['global.score', 'global.absent', 'global.label'],
          ],
        },
        <String, dynamic>{
          'cat': <dynamic>[
            'a',
            null,
            <dynamic>[1, 2],
          ],
        },
        <String, dynamic>{
          'substr': <dynamic>['abcdef', -4, 2],
        },
        <String, dynamic>{
          'in': <dynamic>['bc', 'abcd'],
        },
        <String, dynamic>{
          'merge': <dynamic>[
            <dynamic>[1, 2],
            3,
            <dynamic>[4],
          ],
        },
        <String, dynamic>{
          'map': <dynamic>[
            <dynamic>[1, 2, 3],
            <String, dynamic>{
              '*': <dynamic>[
                <String, dynamic>{'var': ''},
                2,
              ],
            },
          ],
        },
        <String, dynamic>{
          'filter': <dynamic>[
            <dynamic>[1, 2, 3],
            <String, dynamic>{
              '>': <dynamic>[
                <String, dynamic>{'var': ''},
                1,
              ],
            },
          ],
        },
        <String, dynamic>{
          'reduce': <dynamic>[
            <dynamic>[1, 2, 3],
            <String, dynamic>{
              '+': <dynamic>[
                <String, dynamic>{'var': 'current'},
                <String, dynamic>{'var': 'accumulator'},
              ],
            },
            0,
          ],
        },
        <String, dynamic>{
          'all': <dynamic>[
            <dynamic>[1, 2, 3],
            <String, dynamic>{
              '>': <dynamic>[
                <String, dynamic>{'var': ''},
                0,
              ],
            },
          ],
        },
        <String, dynamic>{
          'some': <dynamic>[
            <dynamic>[0, 0, 1],
            <String, dynamic>{'var': ''},
          ],
        },
        <String, dynamic>{
          'none': <dynamic>[
            <dynamic>[0, 0],
            <String, dynamic>{'var': ''},
          ],
        },
        <String, dynamic>{
          'if': <dynamic>[
            true,
            <String, dynamic>{'!': false, '!!': 1},
            false,
          ],
        },
      ];

      for (var index = 0; index < cases.length; index++) {
        final rule = cases[index];
        _loadWithSourceOwnedRule(interpreter, rule);
        final planned = interpreter.evaluateExpression(rule);
        final legacy = interpreter.evaluateExpression(_jsonCopy(rule));
        expect(planned, legacy, reason: 'standard case $index: $rule');
      }
    });

    test('matches the legacy engine for custom operators', () {
      final cases = <Map<String, dynamic>>[
        <String, dynamic>{'str_len': ' abc '},
        <String, dynamic>{'str_upper': 'Abc'},
        <String, dynamic>{'str_lower': 'AbC'},
        <String, dynamic>{'str_trim': ' abc '},
        <String, dynamic>{
          'str_contains': <dynamic>['abcdef', 'cd'],
        },
        <String, dynamic>{
          'str_replace': <dynamic>['a-b-a', 'a', 'x'],
        },
        <String, dynamic>{
          'str_replace_first': <dynamic>['a-b-a', 'a', 'x'],
        },
        <String, dynamic>{
          'str_split': <dynamic>['a,b,c', ','],
        },
        <String, dynamic>{
          'str_join': <dynamic>[
            <dynamic>['a', null, 3],
            '-',
          ],
        },
        <String, dynamic>{
          'length': <dynamic>[1, 2, 3],
        },
        <String, dynamic>{
          'at': <dynamic>[
            <dynamic>['a', 'b'],
            1,
          ],
        },
        <String, dynamic>{
          'slice': <dynamic>[
            <dynamic>[1, 2, 3, 4],
            1,
            3,
          ],
        },
        <String, dynamic>{
          'sort': <dynamic>[3, 1, 2],
        },
        <String, dynamic>{
          'reverse': <dynamic>[1, 2, 3],
        },
        <String, dynamic>{'to_string': 12},
        <String, dynamic>{'to_int': '12'},
        <String, dynamic>{'to_double': '12.5'},
        <String, dynamic>{'abs': -9},
        <String, dynamic>{'sin': 0.5},
        <String, dynamic>{'cos': 0.5},
        <String, dynamic>{'tan': 0.5},
        <String, dynamic>{
          'atan2': <dynamic>[1, 2],
        },
        <String, dynamic>{'sqrt': -4},
        <String, dynamic>{
          'pow': <dynamic>[2, 8],
        },
        <String, dynamic>{
          'clamp': <dynamic>[12, 0, 10],
        },
        <String, dynamic>{
          'lerp': <dynamic>[10, 20, 0.25],
        },
        <String, dynamic>{'seed': 42},
        <String, dynamic>{
          'pi': <dynamic>[
            <String, dynamic>{'var': 'global.absent'},
          ],
        },
      ];

      for (var index = 0; index < cases.length; index++) {
        final rule = cases[index];
        _loadWithSourceOwnedRule(interpreter, rule);
        final planned = interpreter.evaluateExpression(rule);
        final legacy = interpreter.evaluateExpression(_jsonCopy(rule));
        expect(planned, legacy, reason: 'custom case $index: $rule');
      }
    });

    test('pre-resolves templates and returns fresh literal containers', () {
      final selected = <dynamic>[
        '{{ global.score }}',
        <String, dynamic>{'label': '{{ global.label }}'},
      ];
      final rule = <String, dynamic>{
        'if': <dynamic>[true, selected, <dynamic>[]],
      };
      _loadWithSourceOwnedRule(interpreter, rule);

      final planned = interpreter.evaluateExpression(rule) as List<dynamic>;
      final legacy =
          interpreter.evaluateExpression(_jsonCopy(rule)) as List<dynamic>;

      expect(planned, legacy);
      expect(planned, <dynamic>[
        '7',
        <String, dynamic>{'label': 'ready'},
      ]);
      expect(identical(planned, selected), isFalse);
      (planned[1] as Map<String, dynamic>)['label'] = 'changed';
      expect(
        (selected[1] as Map<String, dynamic>)['label'],
        '{{ global.label }}',
      );
    });

    test('source-owned rules preserve locals, defaults, and lazy or', () {
      final rule = <String, dynamic>{
        'or': <dynamic>[
          <String, dynamic>{
            'var': <dynamic>['props.missing', '{{ global.label }}'],
          },
          <String, dynamic>{'var': 'props.value'},
        ],
      };
      _loadWithSourceOwnedRule(interpreter, rule);
      final locals = <String, dynamic>{
        'props': <String, dynamic>{'value': 'from locals'},
      };

      final planned = interpreter.evaluateJsonLogicWithLocals(rule, locals);
      final legacy = interpreter.evaluateJsonLogicWithLocals(
        _jsonCopy(rule),
        locals,
      );

      expect(planned, legacy);
      expect(planned, 'ready');
    });
  });
}

void _loadWithSourceOwnedRule(
  JsonInterpreter interpreter,
  Map<String, dynamic> rule,
) {
  interpreter.loadConfig(<String, dynamic>{
    'dsl': '4.0',
    'meta': <String, dynamic>{'name': 'expression-plan-test'},
    'global': <String, dynamic>{
      'variables': <String, dynamic>{
        'score': 7,
        'label': 'ready',
        'dynamicKey': 'label',
      },
    },
    'ui': <String, dynamic>{
      'screens': <dynamic>[
        <String, dynamic>{
          'id': 'home',
          'content': <String, dynamic>{'children': <dynamic>[]},
        },
      ],
    },
    '_testRule': rule,
  });
}

Map<String, dynamic> _jsonCopy(Map<String, dynamic> value) {
  return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}
