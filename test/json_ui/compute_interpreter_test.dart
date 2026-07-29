import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> appConfig({
    String dsl = '4.0',
    int initialByte = 7,
    int returnBias = 0,
    List<dynamic> steps = const <dynamic>[],
  }) {
    return <String, dynamic>{
      'dsl': dsl,
      'appid': '00000000-0000-4000-8000-000000000004',
      'meta': <String, dynamic>{
        'name': 'compute-test',
        'version': '1.0.0',
        'type': 'app',
      },
      'global': <String, dynamic>{'variables': <String, dynamic>{}},
      'compute': <String, dynamic>{
        'engine': <String, dynamic>{
          'abi': 2,
          'backend': 'vm',
          'semantics': 'i32-v2',
          'defaultBudget': 100000,
          'maxBudget': 200000,
        },
        'program': <String, dynamic>{
          'version': 2,
          'buffers': <String, dynamic>{'bytes': 8},
          'i32': <String, dynamic>{'words': 4},
          'init': <String, dynamic>{
            'bytes': <int>[initialByte],
            'words': <int>[11],
          },
          'functions': <String, dynamic>{
            'sum': <String, dynamic>{
              'params': <String>['n'],
              'body': <dynamic>[
                <dynamic>['set', 'index', 0],
                <dynamic>['set', 'total', returnBias],
                <dynamic>[
                  'while',
                  <dynamic>[
                    '<',
                    <dynamic>['var', 'index'],
                    <dynamic>['var', 'n'],
                  ],
                  <dynamic>[
                    <dynamic>[
                      'set',
                      'total',
                      <dynamic>[
                        '+',
                        <dynamic>['var', 'total'],
                        <dynamic>['var', 'index'],
                      ],
                    ],
                    <dynamic>[
                      'set',
                      'index',
                      <dynamic>[
                        '+',
                        <dynamic>['var', 'index'],
                        1,
                      ],
                    ],
                  ],
                ],
                <dynamic>[
                  'ret',
                  <dynamic>['var', 'total'],
                ],
              ],
            },
            'incrementByte': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'setu8',
                  'bytes',
                  0,
                  <dynamic>[
                    '+',
                    <dynamic>['u8', 'bytes', 0],
                    1,
                  ],
                ],
                <dynamic>[
                  'ret',
                  <dynamic>['u8', 'bytes', 0],
                ],
              ],
            },
          },
        },
      },
      'steps': steps,
      'ui': <String, dynamic>{
        'screens': <dynamic>[
          <String, dynamic>{
            'id': 'home',
            'title': 'Compute',
            'children': <dynamic>[],
          },
        ],
      },
    };
  }

  test('routes generic compute actions before dependency dispatch', () async {
    final interpreter = JsonInterpreter()
      ..loadConfig(
        appConfig(
          steps: <dynamic>[
            <String, dynamic>{
              'call': '@compute.call',
              'args': <String, dynamic>{
                'function': 'sum',
                'args': <dynamic>[6],
              },
              'assign': 'global.sum',
            },
            <String, dynamic>{
              'call': '@compute.write',
              'args': <String, dynamic>{
                'kind': 'u8',
                'buffer': 'bytes',
                'offset': 1,
                'values': <dynamic>[255, 256, -1],
              },
            },
            <String, dynamic>{
              'call': '@compute.read',
              'args': <String, dynamic>{
                'kind': 'u8',
                'buffer': 'bytes',
                'offset': 0,
                'length': 4,
              },
              'assign': 'global.bytes',
            },
            <String, dynamic>{
              'call': '@compute.load',
              'args': <String, dynamic>{
                'buffer': 'bytes',
                'offset': 4,
                'base64': 'BQY=',
              },
            },
            <String, dynamic>{
              'call': '@compute.read',
              'args': <String, dynamic>{
                'kind': 'u8',
                'buffer': 'bytes',
                'offset': 4,
                'length': 2,
              },
              'assign': 'global.loaded',
            },
            <String, dynamic>{'call': '@compute.reset'},
            <String, dynamic>{
              'call': '@compute.read',
              'args': <String, dynamic>{
                'kind': 'u8',
                'buffer': 'bytes',
                'offset': 0,
                'length': 6,
              },
              'assign': 'global.resetBytes',
            },
          ],
        ),
      );

    expect(interpreter.hasCompute, isTrue);
    await interpreter.executeSteps();

    expect(interpreter.getVariable('global.sum'), 15);
    expect(interpreter.getVariable('global.bytes'), <int>[7, 255, 0, 255]);
    expect(interpreter.getVariable('global.loaded'), <int>[5, 6]);
    expect(interpreter.getVariable('global.resetBytes'), <int>[
      7,
      0,
      0,
      0,
      0,
      0,
    ]);
  });

  test(
    'reset restores initial buffers and nested apps restore parent VM',
    () async {
      final interpreter = JsonInterpreter()..loadConfig(appConfig());
      final parentSteps = <dynamic>[
        <String, dynamic>{
          'call': '@compute.call',
          'args': <String, dynamic>{'function': 'incrementByte'},
          'assign': 'global.parentValue',
        },
      ];

      interpreter.loadConfig(appConfig(steps: parentSteps));
      await interpreter.executeSteps();
      expect(interpreter.getVariable('global.parentValue'), 8);

      interpreter.pushState();
      interpreter.loadConfig(
        appConfig(
          initialByte: 50,
          returnBias: 100,
          steps: <dynamic>[
            <String, dynamic>{
              'call': '@compute.call',
              'args': <String, dynamic>{'function': 'incrementByte'},
              'assign': 'global.childValue',
            },
          ],
        ),
      );
      await interpreter.executeSteps();
      expect(interpreter.getVariable('global.childValue'), 51);

      interpreter.popState();
      expect(interpreter.getVariable('global.parentValue'), 8);
      await interpreter.executeSteps();
      expect(interpreter.getVariable('global.parentValue'), 9);
    },
  );

  test('plain DSL 3 apps remain compatible but compute requires DSL 4', () {
    final plain = appConfig(dsl: '3.3')..remove('compute');
    final interpreter = JsonInterpreter()..loadConfig(plain);
    expect(interpreter.hasCompute, isFalse);

    expect(
      () => JsonInterpreter().loadConfig(appConfig(dsl: '3.3')),
      throwsA(isA<ComputeVmCompileException>()),
    );
  });

  test('DSL 3 compute namespace remains available to dependencies', () async {
    final plain = appConfig(
      dsl: '3.3',
      steps: <dynamic>[
        <String, dynamic>{
          'call': '@compute.legacyFunction',
          'args': <String, dynamic>{},
        },
      ],
    )..remove('compute');
    final interpreter = JsonInterpreter()..loadConfig(plain);

    // There is no loaded module in this unit test, so the legacy dependency
    // route returns null. The important compatibility guarantee is that DSL 3
    // does not enter the DSL 4 built-in route and throw "requires compute".
    await expectLater(interpreter.executeSteps(), completes);
  });

  test('rejects unsupported ABI and unsafe per-call budgets', () async {
    final invalidAbi = appConfig();
    ((invalidAbi['compute'] as Map<String, dynamic>)['engine']
            as Map<String, dynamic>)['abi'] =
        3;
    expect(
      () => JsonInterpreter().loadConfig(invalidAbi),
      throwsA(isA<ComputeVmCompileException>()),
    );

    final interpreter = JsonInterpreter()
      ..loadConfig(
        appConfig(
          steps: <dynamic>[
            <String, dynamic>{
              'call': '@compute.call',
              'args': <String, dynamic>{
                'function': 'sum',
                'args': <dynamic>[2],
                'budget': 200001,
              },
            },
          ],
        ),
      );
    expect(interpreter.executeSteps, throwsA(isA<ComputeVmRuntimeException>()));
  });

  test('buffer writes validate atomically before mutating state', () {
    final interpreter = JsonInterpreter()..loadConfig(appConfig());
    final session = interpreter.computeSession!;

    expect(
      () => session.execute('write', <String, dynamic>{
        'kind': 'u8',
        'buffer': 'bytes',
        'values': <dynamic>[99, 'not-an-integer'],
      }),
      throwsA(isA<ComputeVmRuntimeException>()),
    );
    expect(
      session.execute('read', <String, dynamic>{
        'kind': 'u8',
        'buffer': 'bytes',
        'index': 0,
      }),
      7,
    );
  });

  test('reset uses the program snapshot captured at load time', () {
    final config = appConfig(initialByte: 7);
    final interpreter = JsonInterpreter()..loadConfig(config);
    final session = interpreter.computeSession!;

    final compute = config['compute'] as Map<String, dynamic>;
    final program = compute['program'] as Map<String, dynamic>;
    final init = program['init'] as Map<String, dynamic>;
    (init['bytes'] as List<dynamic>)[0] = 99;
    final functions = program['functions'] as Map<String, dynamic>;
    (functions['incrementByte'] as Map<String, dynamic>)['body'] = <dynamic>[
      <dynamic>['ret', 1234],
    ];

    session.execute('write', <String, dynamic>{
      'kind': 'u8',
      'buffer': 'bytes',
      'index': 0,
      'value': 42,
    });
    expect(session.execute('reset', const <String, dynamic>{}), isTrue);
    expect(
      session.execute('read', <String, dynamic>{
        'kind': 'u8',
        'buffer': 'bytes',
        'index': 0,
      }),
      7,
    );
    expect(
      session.execute('call', <String, dynamic>{'function': 'incrementByte'}),
      8,
    );
  });
}
