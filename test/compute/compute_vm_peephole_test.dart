import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';
import 'package:flutter_test/flutter_test.dart';

ComputeVmProgram _compile(
  Map<String, dynamic> specification, {
  bool optimize = true,
}) {
  return ComputeVmProgram.compile(specification, optimize: optimize);
}

Map<String, dynamic> _mixedSpecification() {
  return <String, dynamic>{
    'version': 2,
    'buffers': <String, dynamic>{'bytes': 4},
    'i32': <String, dynamic>{'words': 4},
    'init': <String, dynamic>{
      'bytes': <int>[10, 11, 12, 13],
      'words': <int>[20, 21, 22, 23],
    },
    'functions': <String, dynamic>{
      'run': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>['set', 'x', 7],
          <dynamic>[
            'set',
            'y',
            <dynamic>['var', 'x'],
          ],
          <dynamic>[
            'set',
            'byteValue',
            <dynamic>['u8', 'bytes', 1],
          ],
          <dynamic>[
            'set',
            'wordValue',
            <dynamic>['i32', 'words', 1],
          ],
          <dynamic>[
            'set',
            'sum1',
            <dynamic>[
              '+',
              <dynamic>['var', 'byteValue'],
              5,
            ],
          ],
          <dynamic>[
            'set',
            'sum2',
            <dynamic>[
              '+',
              <dynamic>['u8', 'bytes', 0],
              <dynamic>['var', 'wordValue'],
            ],
          ],
          <dynamic>['setu8', 'bytes', 2, 0x1ff],
          <dynamic>['seti32', 'words', 2, -1],
          <dynamic>[
            'if',
            <dynamic>[
              '<',
              <dynamic>['var', 'sum2'],
              100,
            ],
            <dynamic>[
              <dynamic>['setu8', 'bytes', 3, 33],
            ],
            <dynamic>[
              <dynamic>['setu8', 'bytes', 3, 44],
            ],
          ],
          <dynamic>[
            'ret',
            <dynamic>[
              '+',
              <dynamic>['var', 'sum1'],
              <dynamic>['var', 'sum2'],
            ],
          ],
        ],
      },
    },
  };
}

final class _ExecutionOutcome {
  const _ExecutionOutcome({
    required this.result,
    required this.error,
    required this.bytes,
    required this.words,
  });

  final int? result;
  final ComputeVmBudgetExceeded? error;
  final List<int> bytes;
  final List<int> words;
}

_ExecutionOutcome _execute(ComputeVmProgram program, int budget) {
  int? result;
  ComputeVmBudgetExceeded? error;
  try {
    result = program.call('run', budget: budget);
  } on ComputeVmBudgetExceeded catch (caught) {
    error = caught;
  }
  return _ExecutionOutcome(
    result: result,
    error: error,
    bytes: List<int>.of(program.buffer('bytes')),
    words: List<int>.of(program.words('words')),
  );
}

void _expectSameOutcome(
  _ExecutionOutcome optimized,
  _ExecutionOutcome scalar, {
  required int budget,
}) {
  expect(optimized.result, scalar.result, reason: 'result at budget $budget');
  expect(
    optimized.error?.budget,
    scalar.error?.budget,
    reason: 'reported budget at budget $budget',
  );
  expect(
    optimized.error?.executedInstructions,
    scalar.error?.executedInstructions,
    reason: 'executed instructions at budget $budget',
  );
  expect(
    optimized.error?.function,
    scalar.error?.function,
    reason: 'failure function at budget $budget',
  );
  expect(
    optimized.error?.instruction,
    scalar.error?.instruction,
    reason: 'logical failure pc at budget $budget',
  );
  expect(optimized.bytes, scalar.bytes, reason: 'u8 state at budget $budget');
  expect(optimized.words, scalar.words, reason: 'i32 state at budget $budget');
}

Map<String, dynamic> _basicSuperinstructionSpecification() {
  return <String, dynamic>{
    'version': 2,
    'buffers': <String, dynamic>{'bytes': 4},
    'i32': <String, dynamic>{'words': 4},
    'init': <String, dynamic>{
      'bytes': <int>[10, 11, 12, 13],
      'words': <int>[20, 21, 22, 23],
    },
    'functions': <String, dynamic>{
      'constantMove': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>['set', 'value', 7],
          <dynamic>['set', 'other', 8],
          <dynamic>[
            'ret',
            <dynamic>['var', 'value'],
          ],
        ],
      },
      'moveMove': <String, dynamic>{
        'params': <String>['source'],
        'body': <dynamic>[
          <dynamic>[
            'set',
            'value',
            <dynamic>['var', 'source'],
          ],
          <dynamic>[
            'set',
            'other',
            <dynamic>['var', 'source'],
          ],
          <dynamic>[
            'ret',
            <dynamic>['var', 'value'],
          ],
        ],
      },
      'loadU8Immediate': <String, dynamic>{
        'params': <String>['delta'],
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '+',
              <dynamic>['u8', 'bytes', 0],
              <dynamic>['var', 'delta'],
            ],
          ],
        ],
      },
      'loadI32Immediate': <String, dynamic>{
        'params': <String>['delta'],
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '+',
              <dynamic>['i32', 'words', 0],
              <dynamic>['var', 'delta'],
            ],
          ],
        ],
      },
      'loadU8ImmediateMove': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'set',
            'value',
            <dynamic>['u8', 'bytes', 1],
          ],
          <dynamic>[
            'ret',
            <dynamic>['var', 'value'],
          ],
        ],
      },
      'loadI32ImmediateMove': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'set',
            'value',
            <dynamic>['i32', 'words', 1],
          ],
          <dynamic>[
            'ret',
            <dynamic>['var', 'value'],
          ],
        ],
      },
      'binaryImmediateRight': <String, dynamic>{
        'params': <String>['left'],
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '+',
              <dynamic>[
                '+',
                <dynamic>['var', 'left'],
                5,
              ],
              6,
            ],
          ],
        ],
      },
      'binaryRegisterRight': <String, dynamic>{
        'params': <String>['left', 'right', 'third'],
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '+',
              <dynamic>[
                '+',
                <dynamic>['var', 'left'],
                <dynamic>['var', 'right'],
              ],
              <dynamic>['var', 'third'],
            ],
          ],
        ],
      },
      'returnImmediate': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>['ret', 42],
        ],
      },
      'storeU8ImmediateBoth': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>['setu8', 'bytes', -1, 0x1ff],
          <dynamic>['ret', 0],
        ],
      },
      'storeI32ImmediateBoth': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>['seti32', 'words', 2, 0xffffffff],
          <dynamic>['ret', 0],
        ],
      },
      'u8RmwImmediate': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'setu8',
            'bytes',
            1,
            <dynamic>[
              '+',
              <dynamic>['u8', 'bytes', 1],
              250,
            ],
          ],
          <dynamic>['ret', 0],
        ],
      },
      'i32RmwImmediate': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'seti32',
            'words',
            1,
            <dynamic>[
              '+',
              <dynamic>['i32', 'words', 1],
              5,
            ],
          ],
          <dynamic>['ret', 0],
        ],
      },
      'loadU8ImmediateBinaryImmediate': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '+',
              <dynamic>['u8', 'bytes', 0],
              5,
            ],
          ],
        ],
      },
      'loadI32ImmediateBinaryImmediate': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '+',
              <dynamic>['i32', 'words', 0],
              5,
            ],
          ],
        ],
      },
      'loadI32ImmediateCompareJumpZero': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'if',
            <dynamic>[
              '<',
              <dynamic>['i32', 'words', 0],
              100,
            ],
            <dynamic>[
              <dynamic>['ret', 1],
            ],
          ],
          <dynamic>['ret', 0],
        ],
      },
      'binaryImmediatePair': <String, dynamic>{
        'params': <String>['value'],
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '&',
              <dynamic>[
                '>>',
                <dynamic>['var', 'value'],
                1,
              ],
              7,
            ],
          ],
        ],
      },
      'binaryImmediateDistinctPair': <String, dynamic>{
        'params': <String>['value'],
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              '>>',
              <dynamic>[
                '&',
                <dynamic>['var', 'value'],
                0x3fff,
              ],
              12,
            ],
          ],
        ],
      },
      'constantJumpZero': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>[
            'if',
            0,
            <dynamic>[
              <dynamic>['ret', 1],
            ],
            <dynamic>[
              <dynamic>['ret', 2],
            ],
          ],
        ],
      },
      'normalizeAndJump': <String, dynamic>{
        'params': <String>['value'],
        'body': <dynamic>[
          <dynamic>[
            'ret',
            <dynamic>[
              'and',
              1,
              <dynamic>['var', 'value'],
            ],
          ],
        ],
      },
    },
  };
}

Map<String, dynamic> _wideSwitchSpecification({
  required int assignmentsPerArm,
}) {
  final cases = <dynamic>[
    for (var key = 0; key < 256; key++)
      <dynamic>[
        key,
        <dynamic>[
          for (var assignment = 0; assignment < assignmentsPerArm; assignment++)
            <dynamic>['set', 'slot$assignment', key + assignment],
          <dynamic>['ret', key],
        ],
      ],
  ];
  return <String, dynamic>{
    'version': 2,
    'functions': <String, dynamic>{
      'run': <String, dynamic>{
        'params': <String>['selector'],
        'body': <dynamic>[
          <dynamic>[
            'switch',
            <dynamic>['var', 'selector'],
            cases,
            <dynamic>[
              <dynamic>['ret', -1],
            ],
          ],
        ],
      },
    },
  };
}

void main() {
  group('Compute VM peepholes', () {
    test(
      'optimized execution is scalar-equivalent at every budget boundary',
      () {
        final probe = _compile(_mixedSpecification());
        final optimizedInfo = probe.functionInfo('run')!;
        expect(optimizedInfo.usesFusedBytecode, isTrue);
        expect(optimizedInfo.staticDispatchSavings, greaterThan(0));

        final scalarProbe = _compile(_mixedSpecification(), optimize: false);
        expect(scalarProbe.usesFusedBytecode, isFalse);
        expect(scalarProbe.functionInfo('run')!.staticDispatchSavings, 0);

        for (
          var budget = 1;
          budget <= optimizedInfo.instructionCount + 2;
          budget++
        ) {
          final optimized = _compile(_mixedSpecification());
          final scalar = _compile(_mixedSpecification(), optimize: false);
          _expectSameOutcome(
            _execute(optimized, budget),
            _execute(scalar, budget),
            budget: budget,
          );
        }
      },
    );

    test('applies generic copy, immediate, and constant IR rewrites', () {
      final specification = <String, dynamic>{
        'version': 2,
        'buffers': <String, dynamic>{'bytes': 1},
        'i32': <String, dynamic>{'words': 1},
        'functions': <String, dynamic>{
          'run': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>['set', 'seed', 0],
              <dynamic>[
                'ret',
                <dynamic>[
                  '+',
                  <dynamic>['var', 'value'],
                  7,
                ],
              ],
            ],
          },
          'fold': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['+', 0x7fffffff, 1],
              ],
            ],
          },
          'lowDensity': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>['var', 'value'],
              ],
            ],
          },
        },
      };
      final optimized = _compile(specification);
      final scalar = _compile(specification, optimize: false);

      final optimizedRun = optimized.functionInfo('run')!;
      final scalarRun = scalar.functionInfo('run')!;
      expect(optimizedRun.usesFusedBytecode, isTrue);
      expect(
        optimizedRun.physicalInstructionCount,
        lessThan(scalarRun.physicalInstructionCount),
      );
      expect(optimized.call('run', args: <int>[35]), 42);
      expect(scalar.call('run', args: <int>[35]), 42);

      expect(optimized.functionInfo('fold')!.usesFusedBytecode, isTrue);
      expect(optimized.call('fold'), -0x80000000);
      expect(scalar.call('fold'), -0x80000000);

      final lowDensity = optimized.functionInfo('lowDensity')!;
      expect(lowDensity.usesFusedBytecode, isFalse);
      expect(lowDensity.physicalInstructionCount, lowDensity.instructionCount);
    });

    test('covers every basic superinstruction with public VM behavior', () {
      final optimized = _compile(_basicSuperinstructionSpecification());
      final scalar = _compile(
        _basicSuperinstructionSpecification(),
        optimize: false,
      );
      const names = <String>[
        'constantMove',
        'moveMove',
        'loadU8Immediate',
        'loadI32Immediate',
        'loadU8ImmediateMove',
        'loadI32ImmediateMove',
        'binaryImmediateRight',
        'binaryRegisterRight',
        'returnImmediate',
        'storeU8ImmediateBoth',
        'storeI32ImmediateBoth',
        'u8RmwImmediate',
        'i32RmwImmediate',
        'loadU8ImmediateBinaryImmediate',
        'loadI32ImmediateBinaryImmediate',
        'loadI32ImmediateCompareJumpZero',
        'binaryImmediatePair',
        'binaryImmediateDistinctPair',
        'constantJumpZero',
        'normalizeAndJump',
      ];
      for (final name in names) {
        final info = optimized.functionInfo(name)!;
        expect(info.usesFusedBytecode, isTrue, reason: name);
        expect(info.staticDispatchSavings, greaterThan(0), reason: name);
        expect(scalar.functionInfo(name)!.usesFusedBytecode, isFalse);
      }

      const invocations = <({String name, List<int> arguments, int expected})>[
        (name: 'constantMove', arguments: <int>[], expected: 7),
        (name: 'moveMove', arguments: <int>[9], expected: 9),
        (name: 'loadU8Immediate', arguments: <int>[3], expected: 13),
        (name: 'loadI32Immediate', arguments: <int>[4], expected: 24),
        (name: 'loadU8ImmediateMove', arguments: <int>[], expected: 11),
        (name: 'loadI32ImmediateMove', arguments: <int>[], expected: 21),
        (name: 'binaryImmediateRight', arguments: <int>[7], expected: 18),
        (name: 'binaryRegisterRight', arguments: <int>[7, 8, 9], expected: 24),
        (name: 'returnImmediate', arguments: <int>[], expected: 42),
        (name: 'storeU8ImmediateBoth', arguments: <int>[], expected: 0),
        (name: 'storeI32ImmediateBoth', arguments: <int>[], expected: 0),
        (name: 'u8RmwImmediate', arguments: <int>[], expected: 0),
        (name: 'i32RmwImmediate', arguments: <int>[], expected: 0),
        (
          name: 'loadU8ImmediateBinaryImmediate',
          arguments: <int>[],
          expected: 15,
        ),
        (
          name: 'loadI32ImmediateBinaryImmediate',
          arguments: <int>[],
          expected: 25,
        ),
        (
          name: 'loadI32ImmediateCompareJumpZero',
          arguments: <int>[],
          expected: 1,
        ),
        (name: 'binaryImmediatePair', arguments: <int>[30], expected: 7),
        (
          name: 'binaryImmediateDistinctPair',
          arguments: <int>[0x1234],
          expected: 1,
        ),
        (name: 'constantJumpZero', arguments: <int>[], expected: 2),
        (name: 'normalizeAndJump', arguments: <int>[7], expected: 1),
      ];
      for (final invocation in invocations) {
        expect(
          optimized.call(invocation.name, args: invocation.arguments),
          invocation.expected,
          reason: invocation.name,
        );
        expect(
          scalar.call(invocation.name, args: invocation.arguments),
          invocation.expected,
          reason: '${invocation.name} scalar',
        );
      }
      expect(optimized.buffer('bytes')[3], 255);
      expect(scalar.buffer('bytes')[3], 255);
      expect(optimized.words('words')[2], -1);
      expect(scalar.words('words')[2], -1);
      expect(optimized.buffer('bytes')[1], 5);
      expect(scalar.buffer('bytes')[1], 5);
      expect(optimized.words('words')[1], 26);
      expect(scalar.words('words')[1], 26);
    });

    test('read-modify-write macros preserve every budget boundary', () {
      final specification = <String, dynamic>{
        'version': 2,
        'buffers': <String, dynamic>{'bytes': 1},
        'i32': <String, dynamic>{'words': 4},
        'init': <String, dynamic>{
          'bytes': <int>[0],
          'words': <int>[20, 21, 22, 23],
        },
        'functions': <String, dynamic>{
          'run': <String, dynamic>{
            'body': <dynamic>[
              <dynamic>[
                'seti32',
                'words',
                1,
                <dynamic>[
                  '+',
                  <dynamic>['i32', 'words', 1],
                  5,
                ],
              ],
              <dynamic>['ret', 0],
            ],
          },
        },
      };
      final probe = _compile(specification);
      expect(probe.functionInfo('run')!.staticDispatchSavings, greaterThan(0));
      for (var budget = 1; budget <= 10; budget++) {
        final optimized = _compile(specification);
        final scalar = _compile(specification, optimize: false);
        _expectSameOutcome(
          _execute(optimized, budget),
          _execute(scalar, budget),
          budget: budget,
        );
      }
    });

    test('post-fusion compaction remaps macro branch targets', () {
      final specification = <String, dynamic>{
        'version': 2,
        'functions': <String, dynamic>{
          'constantTarget': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'if',
                <dynamic>[
                  '<',
                  <dynamic>['var', 'value'],
                  0,
                ],
                <dynamic>[
                  <dynamic>['set', 'prefix', 10],
                ],
                <dynamic>[
                  <dynamic>['set', 'prefix', 20],
                ],
              ],
              <dynamic>[
                'if',
                0,
                <dynamic>[
                  <dynamic>['set', 'suffix', 100],
                ],
                <dynamic>[
                  <dynamic>['set', 'suffix', 200],
                ],
              ],
              <dynamic>[
                'ret',
                <dynamic>[
                  '+',
                  <dynamic>['var', 'prefix'],
                  <dynamic>['var', 'suffix'],
                ],
              ],
            ],
          },
          'normalizeTarget': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'if',
                <dynamic>[
                  '<',
                  <dynamic>['var', 'value'],
                  0,
                ],
                <dynamic>[
                  <dynamic>['set', 'prefix', 10],
                ],
                <dynamic>[
                  <dynamic>['set', 'prefix', 20],
                ],
              ],
              <dynamic>[
                'set',
                'normalized',
                <dynamic>[
                  'and',
                  1,
                  <dynamic>['var', 'value'],
                ],
              ],
              <dynamic>[
                'ret',
                <dynamic>[
                  '+',
                  <dynamic>['var', 'prefix'],
                  <dynamic>['var', 'normalized'],
                ],
              ],
            ],
          },
        },
      };
      final optimized = _compile(specification);
      final scalar = _compile(specification, optimize: false);

      for (final name in const <String>['constantTarget', 'normalizeTarget']) {
        expect(
          optimized.functionInfo(name)!.usesFusedBytecode,
          isTrue,
          reason: name,
        );
      }
      for (final value in const <int>[-1, 0, 7]) {
        expect(
          optimized.call('constantTarget', args: <int>[value]),
          scalar.call('constantTarget', args: <int>[value]),
          reason: 'constantTarget($value)',
        );
        expect(
          optimized.call('normalizeTarget', args: <int>[value]),
          scalar.call('normalizeTarget', args: <int>[value]),
          reason: 'normalizeTarget($value)',
        );
      }
    });

    test('fused binary results match scalar int32 edge semantics', () {
      const cases =
          <({String name, String opcode, int left, int right, int expected})>[
            (
              name: 'add_overflow',
              opcode: '+',
              left: 0x7fffffff,
              right: 1,
              expected: -0x80000000,
            ),
            (
              name: 'subtract_overflow',
              opcode: '-',
              left: -0x80000000,
              right: 1,
              expected: 0x7fffffff,
            ),
            (
              name: 'multiply_overflow',
              opcode: '*',
              left: 0x40000000,
              right: 4,
              expected: 0,
            ),
            (
              name: 'divide_int_min_by_minus_one',
              opcode: '/',
              left: -0x80000000,
              right: -1,
              expected: -0x80000000,
            ),
            (
              name: 'divide_by_zero',
              opcode: '/',
              left: -123,
              right: 0,
              expected: 0,
            ),
            (
              name: 'modulo_int_min_by_minus_one',
              opcode: '%',
              left: -0x80000000,
              right: -1,
              expected: 0,
            ),
            (
              name: 'modulo_by_zero',
              opcode: '%',
              left: -123,
              right: 0,
              expected: 0,
            ),
            (
              name: 'negative_modulo',
              opcode: '%',
              left: -7,
              right: 3,
              expected: 2,
            ),
            (
              name: 'bit_and',
              opcode: '&',
              left: -1,
              right: 0x0f,
              expected: 0x0f,
            ),
            (
              name: 'bit_or',
              opcode: '|',
              left: 0x1200,
              right: 0x34,
              expected: 0x1234,
            ),
            (
              name: 'bit_xor',
              opcode: '^',
              left: -1,
              right: 0x0f,
              expected: -0x10,
            ),
            (
              name: 'shift_left_32',
              opcode: '<<',
              left: 1,
              right: 32,
              expected: 1,
            ),
            (
              name: 'shift_left_minus_one',
              opcode: '<<',
              left: 1,
              right: -1,
              expected: -0x80000000,
            ),
            (
              name: 'logical_shift_right_minus_one',
              opcode: '>>',
              left: -1,
              right: 1,
              expected: 0x7fffffff,
            ),
            (
              name: 'shift_right_32',
              opcode: '>>',
              left: -1,
              right: 32,
              expected: -1,
            ),
            (
              name: 'shift_right_minus_one',
              opcode: '>>',
              left: -1,
              right: -1,
              expected: 1,
            ),
            (name: 'equal', opcode: '==', left: -5, right: -5, expected: 1),
            (name: 'not_equal', opcode: '!=', left: -5, right: 5, expected: 1),
            (name: 'less', opcode: '<', left: -1, right: 1, expected: 1),
            (
              name: 'less_equal',
              opcode: '<=',
              left: -5,
              right: -5,
              expected: 1,
            ),
            (name: 'greater', opcode: '>', left: 2, right: -3, expected: 1),
            (
              name: 'greater_equal',
              opcode: '>=',
              left: 5,
              right: 5,
              expected: 1,
            ),
            (
              name: 'minimum',
              opcode: 'min',
              left: -0x80000000,
              right: 0x7fffffff,
              expected: -0x80000000,
            ),
            (
              name: 'maximum',
              opcode: 'max',
              left: -0x80000000,
              right: 0x7fffffff,
              expected: 0x7fffffff,
            ),
          ];
      final functions = <String, dynamic>{};
      for (final binaryCase in cases) {
        functions[binaryCase.name] = <String, dynamic>{
          'params': <String>['left', 'right'],
          'body': <dynamic>[
            <dynamic>['set', 'padding', 0],
            <dynamic>[
              'ret',
              <dynamic>[
                binaryCase.opcode,
                <dynamic>['var', 'left'],
                <dynamic>['var', 'right'],
              ],
            ],
          ],
        };
      }
      final specification = <String, dynamic>{
        'version': 2,
        'functions': functions,
      };
      final optimized = _compile(specification);
      final scalar = _compile(specification, optimize: false);

      for (final binaryCase in cases) {
        expect(
          optimized.functionInfo(binaryCase.name)!.usesFusedBytecode,
          isTrue,
          reason: binaryCase.name,
        );
        expect(
          scalar.functionInfo(binaryCase.name)!.usesFusedBytecode,
          isFalse,
          reason: '${binaryCase.name} scalar',
        );
      }

      for (final binaryCase in cases) {
        final arguments = <int>[binaryCase.left, binaryCase.right];
        final optimizedResult = optimized.call(
          binaryCase.name,
          args: arguments,
        );
        final scalarResult = scalar.call(binaryCase.name, args: arguments);
        expect(optimizedResult, binaryCase.expected, reason: binaryCase.name);
        expect(
          scalarResult,
          binaryCase.expected,
          reason: '${binaryCase.name} scalar expected',
        );
        expect(
          optimizedResult,
          scalarResult,
          reason: '${binaryCase.name} optimized/scalar',
        );
      }
    });

    test('two-step arithmetic fusion normalizes its intermediate to int32', () {
      final specification = <String, dynamic>{
        'version': 2,
        'functions': <String, dynamic>{
          'inPlace': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'ret',
                <dynamic>[
                  '<',
                  <dynamic>[
                    '+',
                    <dynamic>['var', 'value'],
                    1,
                  ],
                  0,
                ],
              ],
            ],
          },
          'distinct': <String, dynamic>{
            'params': <String>['value'],
            'body': <dynamic>[
              <dynamic>[
                'set',
                'intermediate',
                <dynamic>[
                  '+',
                  <dynamic>['var', 'value'],
                  1,
                ],
              ],
              <dynamic>[
                'ret',
                <dynamic>[
                  '<',
                  <dynamic>['var', 'intermediate'],
                  0,
                ],
              ],
            ],
          },
        },
      };
      final optimized = _compile(specification);
      final scalar = _compile(specification, optimize: false);

      for (final name in const <String>['inPlace', 'distinct']) {
        expect(
          optimized.functionInfo(name)!.usesFusedBytecode,
          isTrue,
          reason: name,
        );
        expect(
          optimized.call(name, args: const <int>[0x7fffffff]),
          1,
          reason: name,
        );
        expect(
          optimized.call(name, args: const <int>[0x7fffffff]),
          scalar.call(name, args: const <int>[0x7fffffff]),
          reason: '$name optimized/scalar',
        );
      }
    });

    test('three comparison fusion modes cover all signed comparisons', () {
      const comparisons =
          <({String name, String opcode, int trueLeft, int falseLeft})>[
            (name: 'equal', opcode: '==', trueLeft: -5, falseLeft: -6),
            (name: 'notEqual', opcode: '!=', trueLeft: -6, falseLeft: -5),
            (name: 'less', opcode: '<', trueLeft: -6, falseLeft: -5),
            (name: 'lessEqual', opcode: '<=', trueLeft: -5, falseLeft: -4),
            (name: 'greater', opcode: '>', trueLeft: -4, falseLeft: -5),
            (name: 'greaterEqual', opcode: '>=', trueLeft: -5, falseLeft: -6),
          ];
      final functions = <String, dynamic>{};
      for (final comparison in comparisons) {
        functions['immediate_${comparison.name}'] = <String, dynamic>{
          'params': <String>['left'],
          'body': <dynamic>[
            <dynamic>[
              'if',
              <dynamic>[
                comparison.opcode,
                <dynamic>['var', 'left'],
                -5,
              ],
              <dynamic>[
                <dynamic>['ret', 1],
              ],
              <dynamic>[
                <dynamic>['ret', 0],
              ],
            ],
          ],
        };
        functions['moved_${comparison.name}'] = <String, dynamic>{
          'params': <String>['left', 'right'],
          'body': <dynamic>[
            <dynamic>[
              'if',
              <dynamic>[
                comparison.opcode,
                <dynamic>['var', 'left'],
                <dynamic>['var', 'right'],
              ],
              <dynamic>[
                <dynamic>['ret', 1],
              ],
              <dynamic>[
                <dynamic>['ret', 0],
              ],
            ],
          ],
        };
        functions['register_${comparison.name}'] = <String, dynamic>{
          'params': <String>['left'],
          'body': <dynamic>[
            <dynamic>[
              'if',
              <dynamic>[
                comparison.opcode,
                <dynamic>['var', 'left'],
                <dynamic>['i32', 'rhs', 0],
              ],
              <dynamic>[
                <dynamic>['ret', 1],
              ],
              <dynamic>[
                <dynamic>['ret', 0],
              ],
            ],
          ],
        };
      }
      final specification = <String, dynamic>{
        'version': 2,
        'i32': <String, dynamic>{'rhs': 1},
        'init': <String, dynamic>{
          'rhs': <int>[-5],
        },
        'functions': functions,
      };
      final optimized = _compile(specification);
      final scalar = _compile(specification, optimize: false);

      for (final comparison in comparisons) {
        for (final mode in const <String>['immediate', 'moved', 'register']) {
          final name = '${mode}_${comparison.name}';
          final info = optimized.functionInfo(name)!;
          expect(info.usesFusedBytecode, isTrue, reason: name);
          expect(
            info.staticDispatchSavings,
            greaterThanOrEqualTo(4),
            reason: '$name must include comparison-branch fusion',
          );
          expect(scalar.functionInfo(name)!.usesFusedBytecode, isFalse);

          final trueArguments = mode == 'moved'
              ? <int>[comparison.trueLeft, -5]
              : <int>[comparison.trueLeft];
          final falseArguments = mode == 'moved'
              ? <int>[comparison.falseLeft, -5]
              : <int>[comparison.falseLeft];
          expect(
            optimized.call(name, args: trueArguments),
            1,
            reason: '$name true',
          );
          expect(
            optimized.call(name, args: falseArguments),
            0,
            reason: '$name false',
          );
          expect(scalar.call(name, args: trueArguments), 1);
          expect(scalar.call(name, args: falseArguments), 0);
        }
      }
    });

    test(
      'an unrelated cold fused helper leaves a scalar entry on scalar mode',
      () {
        final program = _compile(<String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'scalarEntry': <String, dynamic>{
              'params': <String>['value'],
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>[
                    'not',
                    <dynamic>['var', 'value'],
                  ],
                ],
              ],
            },
            'coldFusedHelper': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['ret', 7],
              ],
            },
          },
        });

        expect(program.usesFusedBytecode, isTrue);
        final scalarInfo = program.functionInfo('scalarEntry')!;
        expect(scalarInfo.usesFusedBytecode, isFalse);
        expect(scalarInfo.requiresFusedRunner, isFalse);
        expect(
          program.functionInfo('coldFusedHelper')!.usesFusedBytecode,
          isTrue,
        );
        expect(program.call('scalarEntry', args: <int>[0]), 1);
        expect(program.call('scalarEntry', args: <int>[9]), 0);
      },
    );

    test('low-density fusion stays on the scalar runner', () {
      var hostCalls = 0;
      final program = ComputeVmProgram.compile(
        <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'run': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['host', 'tick', <dynamic>[]],
                <dynamic>['nop'],
                <dynamic>['host', 'tick', <dynamic>[]],
                <dynamic>['host', 'tick', <dynamic>[]],
                <dynamic>['nop'],
                <dynamic>['host', 'tick', <dynamic>[]],
                <dynamic>['ret', 42],
              ],
            },
          },
        },
        hosts: <String, ComputeVmHostFunction>{
          'tick': (arguments) {
            hostCalls++;
            return 0;
          },
        },
      );

      final info = program.functionInfo('run')!;
      expect(info.staticDispatchSavings, 0);
      expect(info.usesFusedBytecode, isFalse);
      expect(info.requiresFusedRunner, isFalse);
      expect(program.usesFusedBytecode, isFalse);
      expect(program.call('run'), 42);
      expect(hostCalls, 4);
    });

    test('wide switches require savings proportional to alternative count', () {
      final light = _compile(_wideSwitchSpecification(assignmentsPerArm: 0));
      final lightInfo = light.functionInfo('run')!;
      expect(lightInfo.staticDispatchSavings, 0);
      expect(lightInfo.usesFusedBytecode, isFalse);
      expect(lightInfo.physicalInstructionCount, lightInfo.instructionCount);
      expect(light.call('run', args: const <int>[0]), 0);
      expect(light.call('run', args: const <int>[255]), 255);
      expect(light.call('run', args: const <int>[256]), -1);

      final highSavings = _compile(
        _wideSwitchSpecification(assignmentsPerArm: 18),
      );
      final highSavingsInfo = highSavings.functionInfo('run')!;
      expect(highSavingsInfo.usesFusedBytecode, isTrue);
      // 18 constant assignments plus the return produce 19 saved dispatches
      // per arm, plus one in the default arm: the NES-step-sized 4,865 case.
      expect(highSavingsInfo.staticDispatchSavings, greaterThanOrEqualTo(4865));
      expect(
        highSavingsInfo.physicalInstructionCount,
        lessThan(highSavingsInfo.instructionCount),
      );
      expect(highSavings.call('run', args: const <int>[0]), 0);
      expect(highSavings.call('run', args: const <int>[255]), 255);
      expect(highSavings.call('run', args: const <int>[256]), -1);
    });

    test(
      'fused-runner requirement propagates through the static call graph',
      () {
        final specification = <String, dynamic>{
          'version': 2,
          'functions': <String, dynamic>{
            'entry': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['call', 'middle', <dynamic>[]],
                ],
              ],
            },
            'middle': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>['call', 'leaf', <dynamic>[]],
                ],
              ],
            },
            'leaf': <String, dynamic>{
              'body': <dynamic>[
                <dynamic>['ret', 7],
              ],
            },
            'unrelatedScalar': <String, dynamic>{
              'params': <String>['value'],
              'body': <dynamic>[
                <dynamic>[
                  'ret',
                  <dynamic>[
                    'not',
                    <dynamic>['var', 'value'],
                  ],
                ],
              ],
            },
          },
        };
        final optimized = _compile(specification);
        final scalar = _compile(specification, optimize: false);

        expect(optimized.functionInfo('leaf')!.usesFusedBytecode, isTrue);
        expect(optimized.functionInfo('middle')!.usesFusedBytecode, isFalse);
        expect(optimized.functionInfo('entry')!.usesFusedBytecode, isFalse);
        expect(optimized.functionInfo('leaf')!.requiresFusedRunner, isTrue);
        expect(optimized.functionInfo('middle')!.requiresFusedRunner, isTrue);
        expect(optimized.functionInfo('entry')!.requiresFusedRunner, isTrue);
        expect(
          optimized.functionInfo('unrelatedScalar')!.requiresFusedRunner,
          isFalse,
        );
        expect(optimized.call('entry'), 7);

        expect(scalar.usesFusedBytecode, isFalse);
        expect(scalar.functionInfo('leaf')!.requiresFusedRunner, isFalse);
        expect(scalar.functionInfo('middle')!.requiresFusedRunner, isFalse);
        expect(scalar.functionInfo('entry')!.requiresFusedRunner, isFalse);
        expect(scalar.call('entry'), 7);
      },
    );
  });
}
