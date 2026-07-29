import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';
import 'package:flutter_test/flutter_test.dart';

ComputeVmProgram _program({
  required Map<String, dynamic> functions,
  Map<String, int> buffers = const <String, int>{},
  Map<String, int> i32 = const <String, int>{},
  Map<String, dynamic> init = const <String, dynamic>{},
  Map<String, ComputeVmHostFunction> hosts =
      const <String, ComputeVmHostFunction>{},
  ComputeVmLimits limits = const ComputeVmLimits(),
}) {
  return ComputeVmProgram.compile(
    <String, dynamic>{
      'version': 2,
      'buffers': buffers,
      'i32': i32,
      'init': init,
      'functions': functions,
    },
    hosts: hosts,
    limits: limits,
  );
}

Matcher _compileErrorContaining(String text) {
  return isA<ComputeVmCompileException>().having(
    (error) => error.message,
    'message',
    contains(text),
  );
}

void main() {
  group('signed int32 semantics', () {
    test('normalizes literals, arguments, intermediates, and word writes', () {
      final program = _program(
        i32: const <String, int>{'words': 4},
        init: const <String, dynamic>{
          'words': <int>[0x80000000, -0x80000001],
        },
        functions: <String, dynamic>{
          'run': <String, dynamic>{
            'params': <String>[],
            'body': <dynamic>[
              <dynamic>[
                'seti32',
                'words',
                2,
                <dynamic>['+', 0x7fffffff, 1],
              ],
              <dynamic>[
                'seti32',
                'words',
                3,
                <dynamic>[
                  '/',
                  <dynamic>['+', 0x7fffffff, 1],
                  2,
                ],
              ],
              <dynamic>[
                'ret',
                <dynamic>['i32', 'words', 3],
              ],
            ],
          },
          'identity': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['var', 'value'],
              ],
            ],
          },
        },
      );

      expect(program.words('words'), <int>[-0x80000000, 0x7fffffff, 0, 0]);
      expect(program.call('run'), -0x40000000);
      expect(program.words('words'), <int>[
        -0x80000000,
        0x7fffffff,
        -0x80000000,
        -0x40000000,
      ]);
      expect(program.call('identity', args: <int>[0x100000001]), 1);
    });

    test('division truncates toward zero and zero divisors return zero', () {
      final program = _program(
        functions: <String, dynamic>{
          'divNegative': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['/', -7, 3],
              ],
            ],
          },
          'divZero': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['/', 123, 0],
              ],
            ],
          },
          'modNegative': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['%', -7, 3],
              ],
            ],
          },
          'modZero': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['%', 123, 0],
              ],
            ],
          },
        },
      );

      expect(program.call('divNegative'), -2);
      expect(program.call('divZero'), 0);
      expect(program.call('modNegative'), 2);
      expect(program.call('modZero'), 0);
    });

    test('masks shift counts and performs logical right shift', () {
      final program = _program(
        functions: <String, dynamic>{
          'left31': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['<<', 1, 31],
              ],
            ],
          },
          'left32': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['<<', 7, 32],
              ],
            ],
          },
          'leftNegativeCount': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['<<', 1, -1],
              ],
            ],
          },
          'logicalRight': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['>>', -1, 1],
              ],
            ],
          },
        },
      );

      expect(program.call('left31'), -0x80000000);
      expect(program.call('left32'), 7);
      expect(program.call('leftNegativeCount'), -0x80000000);
      expect(program.call('logicalRight'), 0x7fffffff);
    });

    test('multiplies full-width operands using low-int32 semantics', () {
      final program = _program(
        functions: <String, dynamic>{
          'positiveOperands': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['*', 0x76543210, 0x76543210],
              ],
            ],
          },
          'mixedSigns': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['*', -123456789, 987654321],
              ],
            ],
          },
        },
      );

      expect(program.call('positiveOperands'), -1538637568);
      expect(program.call('mixedSigns'), 67153019);
    });
  });

  group('cross-platform safe integer inputs', () {
    const maxSafeInteger = 9007199254740991;
    const aboveMaxSafeInteger = 9007199254740992;
    const belowMinSafeInteger = -9007199254740992;

    test('rejects unsafe literals and initializers at compile time', () {
      expect(
        () => _program(
          functions: <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['ret', aboveMaxSafeInteger],
              ],
            },
          },
        ),
        throwsA(_compileErrorContaining('safe integer')),
      );
      expect(
        () => _program(
          i32: const <String, int>{'words': 1},
          init: const <String, dynamic>{
            'words': <int>[belowMinSafeInteger],
          },
          functions: <String, dynamic>{
            'f': <String, dynamic>{'body': <dynamic>[]},
          },
        ),
        throwsA(_compileErrorContaining('safe integer')),
      );

      final boundary = _program(
        i32: const <String, int>{'words': 1},
        init: const <String, dynamic>{
          'words': <int>[maxSafeInteger],
        },
        functions: <String, dynamic>{
          'literal': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>['ret', maxSafeInteger],
            ],
          },
        },
      );
      expect(boundary.words('words').single, -1);
      expect(boundary.call('literal'), -1);
    });

    test('rejects unsafe entry arguments and host return values', () {
      final program = _program(
        functions: <String, dynamic>{
          'identity': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['var', 'value'],
              ],
            ],
          },
          'hostValue': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['host', 'wide', <dynamic>[]],
              ],
            ],
          },
        },
        hosts: <String, ComputeVmHostFunction>{
          'wide': (arguments) => aboveMaxSafeInteger,
        },
      );

      expect(
        () => program.call('identity', args: const <int>[aboveMaxSafeInteger]),
        throwsA(
          isA<ComputeVmRuntimeException>().having(
            (error) => error.message,
            'message',
            contains('safe integer range'),
          ),
        ),
      );
      expect(
        () => program.call('identity', args: const <int>[belowMinSafeInteger]),
        throwsA(isA<ComputeVmRuntimeException>()),
      );
      expect(
        () => program.call('hostValue'),
        throwsA(
          isA<ComputeVmRuntimeException>().having(
            (error) => error.message,
            'message',
            contains('cross-platform safe range'),
          ),
        ),
      );
      expect(program.call('identity', args: const <int>[maxSafeInteger]), -1);
    });
  });

  group('typed buffer semantics', () {
    test('power-of-two bytes wrap while other buffers use checked access', () {
      final program = _program(
        buffers: const <String, int>{'wrapped': 4, 'checked': 3},
        i32: const <String, int>{'words': 2},
        init: const <String, dynamic>{
          'wrapped': <int>[10, 11, 12, 13],
          'checked': <int>[20, 21, 22],
          'words': <int>[30, 31],
        },
        functions: <String, dynamic>{
          'write': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>['setu8', 'wrapped', -1, 0x1ff],
              <dynamic>['setu8', 'wrapped', 4, 0x106],
              <dynamic>['setu8', 'checked', -1, 99],
              <dynamic>['setu8', 'checked', 3, 99],
              <dynamic>['seti32', 'words', -1, 99],
              <dynamic>['seti32', 'words', 2, 99],
              <dynamic>['ret', 0],
            ],
          },
          'wrappedNegative': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['u8', 'wrapped', -1],
              ],
            ],
          },
          'wrappedHigh': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['u8', 'wrapped', 4],
              ],
            ],
          },
          'checkedNegative': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['u8', 'checked', -1],
              ],
            ],
          },
          'checkedHigh': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['u8', 'checked', 3],
              ],
            ],
          },
          'wordHigh': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['i32', 'words', 2],
              ],
            ],
          },
        },
      );

      expect(program.call('write'), 0);
      expect(program.buffer('wrapped'), <int>[6, 11, 12, 255]);
      expect(program.buffer('checked'), <int>[20, 21, 22]);
      expect(program.words('words'), <int>[30, 31]);
      expect(program.call('wrappedNegative'), 255);
      expect(program.call('wrappedHigh'), 6);
      expect(program.call('checkedNegative'), 0);
      expect(program.call('checkedHigh'), 0);
      expect(program.call('wordHigh'), 0);
    });

    test('unknown public buffer lookups are descriptive runtime errors', () {
      final program = _program(
        functions: <String, dynamic>{
          'noop': <String, dynamic>{'body': <dynamic>[]},
        },
      );

      expect(
        () => program.buffer('missing'),
        throwsA(
          isA<ComputeVmRuntimeException>().having(
            (error) => error.message,
            'message',
            contains('unknown u8 buffer'),
          ),
        ),
      );
      expect(
        () => program.words('missing'),
        throwsA(
          isA<ComputeVmRuntimeException>().having(
            (error) => error.message,
            'message',
            contains('unknown i32 buffer'),
          ),
        ),
      );
    });

    test('rejects a name shared by u8 and i32 buffers', () {
      expect(
        () => _program(
          buffers: const <String, int>{'shared': 1},
          i32: const <String, int>{'shared': 1},
          functions: <String, dynamic>{
            'noop': <String, dynamic>{'body': <dynamic>[]},
          },
        ),
        throwsA(_compileErrorContaining('must not share the name')),
      );
    });

    test('rejects initializers longer than either typed buffer', () {
      expect(
        () => _program(
          buffers: const <String, int>{'bytes': 1},
          init: const <String, dynamic>{
            'bytes': <int>[1, 2],
          },
          functions: <String, dynamic>{
            'noop': <String, dynamic>{'body': <dynamic>[]},
          },
        ),
        throwsA(_compileErrorContaining('initializer length 2')),
      );
      expect(
        () => _program(
          i32: const <String, int>{'words': 1},
          init: const <String, dynamic>{
            'words': <int>[1, 2],
          },
          functions: <String, dynamic>{
            'noop': <String, dynamic>{'body': <dynamic>[]},
          },
        ),
        throwsA(_compileErrorContaining('initializer length 2')),
      );
    });

    test('counts zero-length buffers toward maxBuffers', () {
      expect(
        () => _program(
          buffers: const <String, int>{'a': 0, 'b': 0},
          i32: const <String, int>{'c': 0},
          functions: <String, dynamic>{
            'noop': <String, dynamic>{'body': <dynamic>[]},
          },
          limits: const ComputeVmLimits(maxBuffers: 2),
        ),
        throwsA(_compileErrorContaining('2 typed buffers')),
      );

      final atLimit = _program(
        buffers: const <String, int>{'emptyBytes': 0},
        i32: const <String, int>{'emptyWords': 0},
        functions: <String, dynamic>{
          'read': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>['setu8', 'emptyBytes', 0, 9],
              <dynamic>['seti32', 'emptyWords', 0, 9],
              <dynamic>[
                'ret',
                <dynamic>[
                  '+',
                  <dynamic>['u8', 'emptyBytes', 0],
                  <dynamic>['i32', 'emptyWords', 0],
                ],
              ],
            ],
          },
        },
        limits: const ComputeVmLimits(maxBuffers: 2),
      );
      expect(atLimit.call('read'), 0);
    });
  });

  group('compile-time resource limits', () {
    test('enforces function, instruction, register, and buffer limits', () {
      expect(
        () => _program(
          functions: <String, dynamic>{
            'a': <String, dynamic>{'body': <dynamic>[]},
            'b': <String, dynamic>{'body': <dynamic>[]},
          },
          limits: const ComputeVmLimits(maxFunctions: 1),
        ),
        throwsA(_compileErrorContaining('functions')),
      );

      expect(
        () => _program(
          functions: <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['ret', 1],
              ],
            },
          },
          limits: const ComputeVmLimits(maxInstructions: 1),
        ),
        throwsA(_compileErrorContaining('instructions')),
      );

      expect(
        () => _program(
          functions: <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['+', 1, 2],
                ],
              ],
            },
          },
          limits: const ComputeVmLimits(maxRegistersPerFunction: 1),
        ),
        throwsA(_compileErrorContaining('registers')),
      );

      expect(
        () => _program(
          buffers: const <String, int>{'bytes': 4},
          functions: <String, dynamic>{
            'f': <String, dynamic>{'body': <dynamic>[]},
          },
          limits: const ComputeVmLimits(maxU8Bytes: 3),
        ),
        throwsA(_compileErrorContaining('byte buffers')),
      );

      expect(
        () => _program(
          i32: const <String, int>{'words': 4},
          functions: <String, dynamic>{
            'f': <String, dynamic>{'body': <dynamic>[]},
          },
          limits: const ComputeVmLimits(maxI32Words: 3),
        ),
        throwsA(_compileErrorContaining('word buffers')),
      );

      expect(
        () => _program(
          buffers: const <String, int>{'bytes': 4},
          i32: const <String, int>{'words': 1},
          functions: <String, dynamic>{
            'f': <String, dynamic>{'body': <dynamic>[]},
          },
          limits: const ComputeVmLimits(maxBufferBytes: 7),
        ),
        throwsA(_compileErrorContaining('typed buffers')),
      );

      expect(
        () => _program(
          buffers: const <String, int>{'bytes': 2},
          init: const <String, dynamic>{
            'bytes': <int>[1, 2],
          },
          functions: <String, dynamic>{
            'f': <String, dynamic>{'body': <dynamic>[]},
          },
          limits: const ComputeVmLimits(maxInitializerElements: 1),
        ),
        throwsA(_compileErrorContaining('initializers')),
      );
    });

    test('enforces AST, name, and switch-table limits', () {
      final oneReturn = <String, dynamic>{
        'f': <String, dynamic>{
          'body': <dynamic>[
            <dynamic>['ret', 1],
          ],
        },
      };

      expect(
        () => _program(
          functions: oneReturn,
          limits: const ComputeVmLimits(maxAstNodes: 3),
        ),
        throwsA(_compileErrorContaining('AST nodes')),
      );
      expect(
        () => _program(
          functions: oneReturn,
          limits: const ComputeVmLimits(maxAstDepth: 2),
        ),
        throwsA(_compileErrorContaining('AST nesting')),
      );
      expect(
        () => _program(
          functions: <String, dynamic>{
            'long': <String, dynamic>{'body': <dynamic>[]},
          },
          limits: const ComputeVmLimits(maxNameLength: 3),
        ),
        throwsA(_compileErrorContaining('keys must be non-empty strings')),
      );
      expect(
        () => _program(
          functions: <String, dynamic>{
            'f': <String, dynamic>{
              'params': <String>['selector'],
              'body': <dynamic>[
                <dynamic>[
                  'switch',
                  <dynamic>['var', 'selector'],
                  <dynamic>[
                    <dynamic>[0, <dynamic>[]],
                    <dynamic>[1, <dynamic>[]],
                    <dynamic>[2, <dynamic>[]],
                    <dynamic>[3, <dynamic>[]],
                  ],
                ],
              ],
            },
          },
          limits: const ComputeVmLimits(maxSwitchTableEntries: 3),
        ),
        throwsA(_compileErrorContaining('switch table entries')),
      );
    });

    test('caps constant, call, host, and switch side tables', () {
      expect(
        () => _program(
          functions: <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['+', 1, 2],
                ],
              ],
            },
          },
          limits: const ComputeVmLimits(maxConstants: 1),
        ),
        throwsA(_compileErrorContaining('unique constants')),
      );
      expect(
        () => _program(
          functions: <String, dynamic>{
            'callee': <String, dynamic>{'body': <dynamic>[]},
            'caller': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['call', 'callee'],
              ],
            },
          },
          limits: const ComputeVmLimits(maxCallSites: 0),
        ),
        throwsA(_compileErrorContaining('call sites')),
      );
      expect(
        () => _program(
          functions: <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['host', 'noop'],
              ],
            },
          },
          hosts: <String, ComputeVmHostFunction>{'noop': (arguments) => 0},
          limits: const ComputeVmLimits(maxHostSites: 0),
        ),
        throwsA(_compileErrorContaining('host sites')),
      );
      expect(
        () => _program(
          functions: <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['switch', 0, <dynamic>[]],
              ],
            },
          },
          limits: const ComputeVmLimits(maxSwitchSites: 0),
        ),
        throwsA(_compileErrorContaining('switch sites')),
      );
    });
  });

  group('runtime limits and budget', () {
    test('enforces one shared maximum call depth', () {
      final program = _program(
        functions: <String, dynamic>{
          'recurse': <String, dynamic>{
            'params': <String>['n'],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>[
                  'call',
                  'recurse',
                  <dynamic>[
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'n'],
                      1,
                    ],
                  ],
                ],
              ],
            ],
          },
        },
        limits: const ComputeVmLimits(maxCallDepth: 3),
      );

      expect(
        () => program.call('recurse', args: <int>[0], budget: 100),
        throwsA(
          isA<ComputeVmRuntimeException>().having(
            (error) => error.message,
            'message',
            contains('maximum call depth 3 exceeded'),
          ),
        ),
      );
    });

    test('enforces cumulative register words across recursive frames', () {
      final recursiveFunctions = <String, dynamic>{
        'recurse': <String, dynamic>{
          'params': <String>['n'],
          'body': <dynamic>[
            <dynamic>[
              'if',
              <dynamic>[
                '<=',
                <dynamic>['var', 'n'],
                0,
              ],
              <dynamic>[
                <dynamic>['ret', 0],
              ],
            ],
            <dynamic>[
              'ret',
              <dynamic>[
                'call',
                'recurse',
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
        },
      };
      final prototype = _program(functions: recursiveFunctions);
      final frameWords = prototype.functionInfo('recurse')!.registerCount;
      final program = _program(
        functions: recursiveFunctions,
        limits: ComputeVmLimits(
          maxCallDepth: 100,
          maxStackWords: frameWords * 2 - 1,
        ),
      );

      expect(program.call('recurse', args: const <int>[0], budget: 100), 0);
      expect(
        () => program.call('recurse', args: const <int>[10], budget: 100),
        throwsA(
          isA<ComputeVmRuntimeException>().having(
            (error) => error.message,
            'message',
            contains('maximum stack size'),
          ),
        ),
      );
    });

    test('rejects caller budgets above the configured maximum', () {
      final program = _program(
        functions: <String, dynamic>{
          'run': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>['ret', 7],
            ],
          },
        },
        limits: const ComputeVmLimits(maxBudget: 4),
      );

      expect(program.call('run', budget: 4), 7);
      expect(
        () => program.call('run', budget: 5),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('configured maximum 4'),
          ),
        ),
      );
    });

    test(
      'reports exact budget exhaustion location and shares nested budget',
      () {
        final program = _program(
          functions: <String, dynamic>{
            'leaf': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['ret', 7],
              ],
            },
            'outer': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['call', 'leaf', <dynamic>[]],
                ],
              ],
            },
          },
        );

        expect(
          () => program.call('outer', budget: 2),
          throwsA(
            isA<ComputeVmBudgetExceeded>()
                .having((error) => error.budget, 'budget', 2)
                .having(
                  (error) => error.executedInstructions,
                  'executedInstructions',
                  2,
                )
                .having((error) => error.function, 'function', 'leaf')
                .having((error) => error.instruction, 'instruction', 1),
          ),
        );
        expect(
          () => program.call('outer', budget: 0),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('host instructions consume budget', () {
      var calls = 0;
      final program = _program(
        functions: <String, dynamic>{
          'run': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['host', 'tick', <dynamic>[]],
              ],
            ],
          },
        },
        hosts: <String, ComputeVmHostFunction>{
          'tick': (arguments) {
            calls++;
            return 9;
          },
        },
      );

      expect(
        () => program.call('run', budget: 1),
        throwsA(isA<ComputeVmBudgetExceeded>()),
      );
      expect(calls, 1);
      expect(program.call('run', budget: 2), 9);
      expect(calls, 2);
    });
  });

  group('host ABI', () {
    test('evaluates arguments left-to-right and normalizes host results', () {
      final events = <int>[];
      final program = _program(
        functions: <String, dynamic>{
          'ordered': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>[
                  'host',
                  'combine',
                  <dynamic>[
                    <dynamic>[
                      'host',
                      'mark',
                      <dynamic>[1],
                    ],
                    <dynamic>[
                      'host',
                      'mark',
                      <dynamic>[2],
                    ],
                  ],
                ],
              ],
            ],
          },
          'wideResult': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['host', 'wide', <dynamic>[]],
              ],
            ],
          },
          'andShortCircuit': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>[
                  'and',
                  0,
                  <dynamic>[
                    'host',
                    'mark',
                    <dynamic>[9],
                  ],
                ],
              ],
            ],
          },
          'orShortCircuit': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>[
                  'or',
                  1,
                  <dynamic>[
                    'host',
                    'mark',
                    <dynamic>[9],
                  ],
                ],
              ],
            ],
          },
        },
        hosts: <String, ComputeVmHostFunction>{
          'mark': (arguments) {
            events.add(arguments.single);
            return arguments.single;
          },
          'combine': (arguments) {
            events.add(100);
            return arguments[0] * 10 + arguments[1];
          },
          'wide': (arguments) => 0x100000001,
        },
      );

      expect(program.call('ordered'), 12);
      expect(events, <int>[1, 2, 100]);
      expect(program.call('wideResult'), 1);
      events.clear();
      expect(program.call('andShortCircuit'), 0);
      expect(program.call('orShortCircuit'), 1);
      expect(events, isEmpty);
    });
  });

  group('nested control-flow targets', () {
    test('break exits only the innermost loop through nested blocks', () {
      final program = _program(
        functions: <String, dynamic>{
          'run': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>['set', 'outer', 0],
              <dynamic>['set', 'total', 0],
              <dynamic>[
                'repeat',
                3,
                <dynamic>[
                  <dynamic>['set', 'inner', 0],
                  <dynamic>[
                    'while',
                    <dynamic>[
                      '<',
                      <dynamic>['var', 'inner'],
                      5,
                    ],
                    <dynamic>[
                      <dynamic>[
                        'set',
                        'inner',
                        <dynamic>[
                          '+',
                          <dynamic>['var', 'inner'],
                          1,
                        ],
                      ],
                      <dynamic>[
                        'if',
                        <dynamic>[
                          '==',
                          <dynamic>['var', 'inner'],
                          1,
                        ],
                        <dynamic>[
                          <dynamic>[
                            'block',
                            <dynamic>[
                              <dynamic>['break'],
                            ],
                          ],
                        ],
                      ],
                      <dynamic>[
                        'set',
                        'total',
                        <dynamic>[
                          '+',
                          <dynamic>['var', 'total'],
                          1000,
                        ],
                      ],
                    ],
                  ],
                  <dynamic>[
                    'set',
                    'total',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'total'],
                      <dynamic>['var', 'inner'],
                    ],
                  ],
                  <dynamic>[
                    'set',
                    'outer',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'outer'],
                      1,
                    ],
                  ],
                ],
              ],
              <dynamic>[
                'ret',
                <dynamic>[
                  '+',
                  <dynamic>[
                    '*',
                    <dynamic>['var', 'total'],
                    10,
                  ],
                  <dynamic>['var', 'outer'],
                ],
              ],
            ],
          },
        },
      );

      // Each inner while contributes one; all three outer iterations continue.
      expect(program.call('run'), 33);
    });

    test('continue advances only the innermost loop', () {
      final program = _program(
        functions: <String, dynamic>{
          'run': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>['set', 'outer', 0],
              <dynamic>['set', 'total', 0],
              <dynamic>[
                'repeat',
                3,
                <dynamic>[
                  <dynamic>['set', 'inner', 0],
                  <dynamic>[
                    'repeat',
                    4,
                    <dynamic>[
                      <dynamic>[
                        'set',
                        'inner',
                        <dynamic>[
                          '+',
                          <dynamic>['var', 'inner'],
                          1,
                        ],
                      ],
                      <dynamic>[
                        'if',
                        <dynamic>[
                          '>=',
                          <dynamic>['var', 'inner'],
                          0,
                        ],
                        <dynamic>[
                          <dynamic>[
                            'block',
                            <dynamic>[
                              <dynamic>['continue'],
                            ],
                          ],
                        ],
                      ],
                      <dynamic>[
                        'set',
                        'total',
                        <dynamic>[
                          '+',
                          <dynamic>['var', 'total'],
                          1000,
                        ],
                      ],
                    ],
                  ],
                  <dynamic>[
                    'set',
                    'total',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'total'],
                      <dynamic>['var', 'inner'],
                    ],
                  ],
                  <dynamic>[
                    'set',
                    'outer',
                    <dynamic>[
                      '+',
                      <dynamic>['var', 'outer'],
                      1,
                    ],
                  ],
                ],
              ],
              <dynamic>[
                'ret',
                <dynamic>[
                  '+',
                  <dynamic>[
                    '*',
                    <dynamic>['var', 'total'],
                    10,
                  ],
                  <dynamic>['var', 'outer'],
                ],
              ],
            ],
          },
        },
      );

      // The inner repeat reaches four every time, then the outer body resumes.
      expect(program.call('run'), 123);
    });

    test(
      'repeat skips zero and negative counts and counts continues exactly',
      () {
        final program = _program(
          functions: <String, dynamic>{
            'run': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['set', 'hits', 0],
                <dynamic>[
                  'repeat',
                  0,
                  <dynamic>[
                    <dynamic>[
                      'set',
                      'hits',
                      <dynamic>[
                        '+',
                        <dynamic>['var', 'hits'],
                        100,
                      ],
                    ],
                  ],
                ],
                <dynamic>[
                  'repeat',
                  -7,
                  <dynamic>[
                    <dynamic>[
                      'set',
                      'hits',
                      <dynamic>[
                        '+',
                        <dynamic>['var', 'hits'],
                        100,
                      ],
                    ],
                  ],
                ],
                <dynamic>[
                  'repeat',
                  3,
                  <dynamic>[
                    <dynamic>[
                      'set',
                      'hits',
                      <dynamic>[
                        '+',
                        <dynamic>['var', 'hits'],
                        1,
                      ],
                    ],
                    <dynamic>['continue'],
                    <dynamic>[
                      'set',
                      'hits',
                      <dynamic>[
                        '+',
                        <dynamic>['var', 'hits'],
                        100,
                      ],
                    ],
                  ],
                ],
                <dynamic>[
                  'ret',
                  <dynamic>['var', 'hits'],
                ],
              ],
            },
          },
        );

        expect(program.call('run'), 3);
      },
    );
  });

  group('invalid modules and calls', () {
    test('rejects malformed or unsupported AST at compile time', () {
      final invalidSpecifications = <Map<String, dynamic>>[
        <String, dynamic>{'version': 1, 'functions': <String, dynamic>{}},
        <String, dynamic>{'version': 2},
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['unknownStatement'],
              ],
            },
          },
        },
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['unknownExpression'],
                ],
              ],
            },
          },
        },
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['break'],
              ],
            },
          },
        },
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'f': <String, dynamic>{
              'params': <String>['x', 'x'],
              'body': <dynamic>[],
            },
          },
        },
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['host', 'missing', <dynamic>[]],
                ],
              ],
            },
          },
        },
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'f': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['setu8', 'missing', 0, 1],
              ],
            },
          },
        },
      ];

      for (final specification in invalidSpecifications) {
        expect(
          () => ComputeVmProgram.compile(specification),
          throwsA(isA<ComputeVmCompileException>()),
          reason: '$specification',
        );
      }
    });

    test('rejects unknown entry functions and argument count mismatches', () {
      final program = _program(
        functions: <String, dynamic>{
          'identity': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['var', 'value'],
              ],
            ],
          },
        },
      );

      expect(
        () => program.call('missing'),
        throwsA(isA<ComputeVmRuntimeException>()),
      );
      expect(
        () => program.call('identity'),
        throwsA(isA<ComputeVmRuntimeException>()),
      );
    });
  });
}
