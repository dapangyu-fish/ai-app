import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ComputeVmProgram', () {
    test('executes structured control flow and typed buffer access', () {
      final program = ComputeVmProgram.compile(<String, dynamic>{
        'version': 2,
        'buffers': <String, dynamic>{'bytes': 8, 'odd': 3},
        'i32': <String, dynamic>{'words': 4},
        'init': <String, dynamic>{
          'bytes': <int>[9, 8],
          'words': <int>[7],
        },
        'functions': <String, dynamic>{
          'exercise': <String, dynamic>{
            'params': <String>['limit', 'mode'],
            'body': <dynamic>[
              <dynamic>['set', 'sum', 0],
              <dynamic>['set', 'i', 0],
              <dynamic>[
                'while',
                <dynamic>[
                  '<',
                  <dynamic>['var', 'i'],
                  <dynamic>['var', 'limit'],
                ],
                <dynamic>[
                  <dynamic>[
                    'set',
                    'i',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'i'],
                      1,
                    ],
                  ],
                  <dynamic>[
                    'if',
                    <dynamic>[
                      '==',
                      <dynamic>['var', 'i'],
                      2,
                    ],
                    <dynamic>[
                      <dynamic>['continue'],
                    ],
                  ],
                  <dynamic>[
                    'if',
                    <dynamic>[
                      '==',
                      <dynamic>['var', 'i'],
                      6,
                    ],
                    <dynamic>[
                      <dynamic>['break'],
                    ],
                  ],
                  <dynamic>[
                    'set',
                    'sum',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'sum'],
                      <dynamic>['var', 'i'],
                    ],
                  ],
                ],
              ],
              <dynamic>[
                'repeat',
                2,
                <dynamic>[
                  <dynamic>[
                    'set',
                    'sum',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'sum'],
                      10,
                    ],
                  ],
                ],
              ],
              <dynamic>[
                'switch',
                <dynamic>['var', 'mode'],
                <dynamic>[
                  <dynamic>[
                    1,
                    <dynamic>[
                      <dynamic>[
                        'set',
                        'sum',
                        <dynamic>[
                          '+',
                          <dynamic>['var', 'sum'],
                          100,
                        ],
                      ],
                      <dynamic>['break'],
                    ],
                  ],
                  <dynamic>[
                    2,
                    <dynamic>[
                      <dynamic>[
                        'set',
                        'sum',
                        <dynamic>[
                          '+',
                          <dynamic>['var', 'sum'],
                          200,
                        ],
                      ],
                    ],
                  ],
                ],
                <dynamic>[
                  <dynamic>[
                    'set',
                    'sum',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'sum'],
                      300,
                    ],
                  ],
                ],
              ],
              <dynamic>[
                'block',
                <dynamic>[
                  <dynamic>[
                    'setu8',
                    'bytes',
                    -1,
                    <dynamic>['var', 'sum'],
                  ],
                  <dynamic>['setu8', 'odd', 9, 55],
                  <dynamic>[
                    'seti32',
                    'words',
                    1,
                    <dynamic>['var', 'sum'],
                  ],
                ],
              ],
              <dynamic>[
                'ret',
                <dynamic>['var', 'sum'],
              ],
            ],
          },
          'readWrapped': <String, dynamic>{
            'params': <String>[],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['u8', 'bytes', 15],
              ],
            ],
          },
          'readOutOfRange': <String, dynamic>{
            'params': <String>[],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['u8', 'odd', -1],
              ],
            ],
          },
          'firstAssignment': <String, dynamic>{
            'params': <String>[],
            'body': <dynamic>[
              <dynamic>['set', 'onlyAssigned', 9],
              <dynamic>['ret', 1],
            ],
          },
        },
      });

      expect(program.hasFunction('exercise'), isTrue);
      expect(program.hasFunction('missing'), isFalse);
      expect(program.buffer('bytes').sublist(0, 2), <int>[9, 8]);
      expect(program.words('words')[0], 7);
      expect(program.call('exercise', args: <int>[10, 1]), 133);
      expect(program.buffer('bytes')[7], 133);
      expect(program.words('words')[1], 133);
      expect(program.buffer('odd'), <int>[0, 0, 0]);
      expect(program.call('readWrapped'), 133);
      expect(program.call('readOutOfRange'), 0);
      expect(program.call('firstAssignment'), 1);

      final info = program.functionInfo('exercise');
      expect(info, isNotNull);
      expect(info!.parameterCount, 2);
      expect(info.localCount, 4);
      expect(info.instructionCount, greaterThan(20));
      expect(info.basicBlockCount, greaterThan(5));
    });

    test('uses deterministic int32 arithmetic and lazy boolean operators', () {
      var forbiddenCalls = 0;
      final program = ComputeVmProgram.compile(
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'overflow': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['+', 2147483647, 1],
                ],
              ],
            },
            'logicalShift': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['>>', -1, 1],
                ],
              ],
            },
            'zeroDivision': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>[
                    '+',
                    <dynamic>['/', 9, 0],
                    <dynamic>['%', 9, 0],
                  ],
                ],
              ],
            },
            'lazy': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>[
                    '+',
                    <dynamic>[
                      'and',
                      0,
                      <dynamic>['host', 'forbidden'],
                    ],
                    <dynamic>[
                      'or',
                      1,
                      <dynamic>['host', 'forbidden'],
                    ],
                  ],
                ],
              ],
            },
            'conditional': <String, dynamic>{
              'params': <String>['condition'],
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>[
                    '?:',
                    <dynamic>['var', 'condition'],
                    41,
                    42,
                  ],
                ],
              ],
            },
          },
        },
        hosts: <String, ComputeVmHostFunction>{
          'forbidden': (List<int> arguments) {
            forbiddenCalls++;
            return 1;
          },
        },
      );

      expect(program.call('overflow'), -2147483648);
      expect(program.call('logicalShift'), 2147483647);
      expect(program.call('zeroDivision'), 0);
      expect(program.call('lazy'), 1);
      expect(forbiddenCalls, 0);
      expect(program.call('conditional', args: <int>[0]), 42);
      expect(program.call('conditional', args: <int>[5]), 41);
    });

    test('supports recursive calls and ordered host calls', () {
      final recorded = <int>[];
      final program = ComputeVmProgram.compile(
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'factorial': <String, dynamic>{
              'params': <String>['n'],
              'body': <dynamic>[
                <dynamic>[
                  'if',
                  <dynamic>[
                    '<=',
                    <dynamic>['var', 'n'],
                    1,
                  ],
                  <dynamic>[
                    <dynamic>['ret', 1],
                  ],
                ],
                <dynamic>[
                  'ret',
                  <dynamic>[
                    '*',
                    <dynamic>['var', 'n'],
                    <dynamic>[
                      'call',
                      'factorial',
                      <dynamic>[
                        <dynamic>[
                          '-',
                          <dynamic>['var', 'n'],
                          1,
                        ],
                      ],
                    ],
                  ],
                ],
              ],
            },
            'hostOrder': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>[
                    'host',
                    'combine',
                    <dynamic>[
                      <dynamic>[
                        'host',
                        'record',
                        <dynamic>[4],
                      ],
                      <dynamic>[
                        'host',
                        'record',
                        <dynamic>[5],
                      ],
                    ],
                  ],
                ],
              ],
            },
          },
        },
        hosts: <String, ComputeVmHostFunction>{
          'record': (List<int> arguments) {
            recorded.add(arguments.single);
            return arguments.single;
          },
          'combine': (List<int> arguments) {
            return arguments[0] * 10 + arguments[1];
          },
        },
      );

      expect(program.call('factorial', args: <int>[6]), 720);
      expect(program.call('hostOrder'), 45);
      expect(recorded, <int>[4, 5]);
    });

    test('dispatches dense, sparse, nested, and 256-case switches', () {
      final denseCases = <dynamic>[
        for (var key = 10; key <= 14; key++)
          <dynamic>[
            key,
            <dynamic>[
              <dynamic>['ret', key * 10],
            ],
          ],
      ];
      final sparseCases = <dynamic>[
        <dynamic>[
          1000000,
          <dynamic>[
            <dynamic>['ret', 30],
          ],
        ],
        <dynamic>[
          -1000,
          <dynamic>[
            <dynamic>['ret', 10],
          ],
        ],
        <dynamic>[
          7,
          <dynamic>[
            <dynamic>['ret', 20],
          ],
        ],
      ];
      final largeCases = <dynamic>[
        for (var key = 0; key < 256; key++)
          <dynamic>[
            key,
            <dynamic>[
              <dynamic>['ret', key + 1000],
            ],
          ],
      ];
      final program = ComputeVmProgram.compile(<String, dynamic>{
        'version': 2,
        'functions': <String, dynamic>{
          'dense': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'switch',
                <dynamic>['var', 'value'],
                denseCases,
                <dynamic>[
                  <dynamic>['ret', -1],
                ],
              ],
            ],
          },
          'sparse': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'switch',
                <dynamic>['var', 'value'],
                sparseCases,
                <dynamic>[
                  <dynamic>['ret', -1],
                ],
              ],
            ],
          },
          'large': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'switch',
                <dynamic>['var', 'value'],
                largeCases,
                <dynamic>[
                  <dynamic>['ret', -1],
                ],
              ],
            ],
          },
          'nested': <String, dynamic>{
            'params': <String>['outer', 'inner'],
            'body': <dynamic>[
              <dynamic>[
                'switch',
                <dynamic>['var', 'outer'],
                <dynamic>[
                  <dynamic>[
                    1,
                    <dynamic>[
                      <dynamic>[
                        'switch',
                        <dynamic>['var', 'inner'],
                        <dynamic>[
                          <dynamic>[
                            10,
                            <dynamic>[
                              <dynamic>['ret', 110],
                            ],
                          ],
                          <dynamic>[
                            20,
                            <dynamic>[
                              <dynamic>['ret', 120],
                            ],
                          ],
                        ],
                        <dynamic>[
                          <dynamic>['ret', 119],
                        ],
                      ],
                    ],
                  ],
                  <dynamic>[
                    2,
                    <dynamic>[
                      <dynamic>['ret', 200],
                    ],
                  ],
                ],
                <dynamic>[
                  <dynamic>['ret', 999],
                ],
              ],
            ],
          },
        },
      });

      expect(program.call('dense', args: <int>[10]), 100);
      expect(program.call('dense', args: <int>[14]), 140);
      expect(program.call('dense', args: <int>[9]), -1);
      expect(program.call('sparse', args: <int>[-1000]), 10);
      expect(program.call('sparse', args: <int>[7]), 20);
      expect(program.call('sparse', args: <int>[1000000]), 30);
      expect(program.call('sparse', args: <int>[8]), -1);
      expect(program.call('large', args: <int>[0]), 1000);
      expect(program.call('large', args: <int>[255]), 1255);
      expect(program.call('large', args: <int>[256]), -1);
      expect(program.call('nested', args: <int>[1, 10]), 110);
      expect(program.call('nested', args: <int>[1, 20]), 120);
      expect(program.call('nested', args: <int>[1, 11]), 119);
      expect(program.call('nested', args: <int>[2, 10]), 200);
      expect(program.call('nested', args: <int>[3, 10]), 999);

      final denseInfo = program.functionInfo('dense')!;
      expect(denseInfo.jumpTableSwitchCount, 1);
      expect(denseInfo.binarySearchSwitchCount, 0);
      final sparseInfo = program.functionInfo('sparse')!;
      expect(sparseInfo.jumpTableSwitchCount, 0);
      expect(sparseInfo.binarySearchSwitchCount, 1);
      final largeInfo = program.functionInfo('large')!;
      expect(largeInfo.jumpTableSwitchCount, 1);
      expect(largeInfo.basicBlockCount, greaterThan(256));
      final nestedInfo = program.functionInfo('nested')!;
      expect(nestedInfo.jumpTableSwitchCount, 1);
      expect(nestedInfo.binarySearchSwitchCount, 1);
    });

    test('shares a strict instruction budget across loops and calls', () {
      final program = ComputeVmProgram.compile(<String, dynamic>{
        'version': 2,
        'functions': <String, dynamic>{
          'spin': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'while',
                1,
                <dynamic>[
                  <dynamic>['nop'],
                ],
              ],
            ],
          },
        },
      });

      expect(
        () => program.call('spin', budget: 10),
        throwsA(
          isA<ComputeVmBudgetExceeded>()
              .having(
                (ComputeVmBudgetExceeded error) => error.budget,
                'budget',
                10,
              )
              .having(
                (ComputeVmBudgetExceeded error) => error.executedInstructions,
                'executedInstructions',
                10,
              ),
        ),
      );
    });

    test('rejects invalid programs before execution', () {
      expect(
        () => ComputeVmProgram.compile(<String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'bad': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['break'],
              ],
            },
          },
        }),
        throwsA(isA<ComputeVmCompileException>()),
      );
      expect(
        () => ComputeVmProgram.compile(<String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'bad': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['host', 'missing'],
                ],
              ],
            },
          },
        }),
        throwsA(isA<ComputeVmCompileException>()),
      );
    });

    test('requires numeric version 2 and declared locals', () {
      for (final invalidVersion in <dynamic>[null, 1, 2.5, '2', true]) {
        final specification = <String, dynamic>{
          if (invalidVersion != null) 'version': invalidVersion,
          'functions': <String, dynamic>{},
        };
        expect(
          () => ComputeVmProgram.compile(specification),
          throwsA(isA<ComputeVmCompileException>()),
          reason: 'version $invalidVersion must be rejected',
        );
      }

      expect(
        ComputeVmProgram.compile(<String, dynamic>{
          // Dart Web represents JSON 2 and 2.0 identically, so ABI matching is
          // defined by numeric value rather than a VM-specific runtime type.
          'version': 2.0,
          'functions': <String, dynamic>{},
        }),
        isA<ComputeVmProgram>(),
      );
      expect(
        () => ComputeVmProgram.compile(<String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'readUndeclared': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['var', 'missing'],
                ],
              ],
            },
          },
        }),
        throwsA(
          isA<ComputeVmCompileException>().having(
            (ComputeVmCompileException error) => error.message,
            'message',
            contains('unknown local'),
          ),
        ),
      );
    });
  });
}
