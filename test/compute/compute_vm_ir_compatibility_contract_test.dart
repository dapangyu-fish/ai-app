import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ExecutionSnapshot {
  const _ExecutionSnapshot({
    required this.result,
    required this.error,
    required this.u8,
    required this.i32,
    required this.hostEvents,
  });

  final int? result;
  final ComputeVmBudgetExceeded? error;
  final Map<String, List<int>> u8;
  final Map<String, List<int>> i32;
  final List<int> hostEvents;
}

_ExecutionSnapshot _execute(
  Map<String, dynamic> specification, {
  required bool optimize,
  required String entry,
  required List<int> arguments,
  required int budget,
}) {
  final hostEvents = <int>[];
  final program = ComputeVmProgram.compile(
    specification,
    optimize: optimize,
    hosts: <String, ComputeVmHostFunction>{
      'mark': (hostArguments) {
        final event = hostArguments.isEmpty ? -1 : hostArguments.single;
        hostEvents.add(event);
        return event;
      },
    },
  );

  int? result;
  ComputeVmBudgetExceeded? error;
  try {
    result = program.call(entry, args: arguments, budget: budget);
  } on ComputeVmBudgetExceeded catch (caught) {
    error = caught;
  }

  return _ExecutionSnapshot(
    result: result,
    error: error,
    u8: <String, List<int>>{
      for (final entry in program.u8.entries)
        entry.key: List<int>.of(entry.value),
    },
    i32: <String, List<int>>{
      for (final entry in program.i32.entries)
        entry.key: List<int>.of(entry.value),
    },
    hostEvents: List<int>.of(hostEvents),
  );
}

void _expectSameSnapshot(
  _ExecutionSnapshot optimized,
  _ExecutionSnapshot scalar, {
  required String scenario,
  required int budget,
}) {
  final reason = '$scenario at budget $budget';
  expect(optimized.result, scalar.result, reason: 'result: $reason');
  expect(optimized.error?.budget, scalar.error?.budget, reason: reason);
  expect(
    optimized.error?.executedInstructions,
    scalar.error?.executedInstructions,
    reason: 'executed instruction count: $reason',
  );
  expect(
    optimized.error?.function,
    scalar.error?.function,
    reason: 'logical failure function: $reason',
  );
  expect(
    optimized.error?.instruction,
    scalar.error?.instruction,
    reason: 'logical failure pc: $reason',
  );
  expect(optimized.u8, equals(scalar.u8), reason: 'u8 side effects: $reason');
  expect(
    optimized.i32,
    equals(scalar.i32),
    reason: 'i32 side effects: $reason',
  );
  expect(
    optimized.hostEvents,
    equals(scalar.hostEvents),
    reason: 'host side effects: $reason',
  );
}

int _firstSuccessfulBudget(
  Map<String, dynamic> specification, {
  required String entry,
  required List<int> arguments,
}) {
  for (var budget = 1; budget <= 512; budget++) {
    final outcome = _execute(
      specification,
      optimize: false,
      entry: entry,
      arguments: arguments,
      budget: budget,
    );
    if (outcome.error == null) {
      return budget;
    }
  }
  fail('$entry did not complete within the contract-test budget limit');
}

void _expectBudgetParity(
  Map<String, dynamic> specification, {
  required String entry,
  List<int> arguments = const <int>[],
  String? scenario,
}) {
  final label = scenario ?? '$entry($arguments)';
  final successBudget = _firstSuccessfulBudget(
    specification,
    entry: entry,
    arguments: arguments,
  );
  for (var budget = 1; budget <= successBudget + 1; budget++) {
    _expectSameSnapshot(
      _execute(
        specification,
        optimize: true,
        entry: entry,
        arguments: arguments,
        budget: budget,
      ),
      _execute(
        specification,
        optimize: false,
        entry: entry,
        arguments: arguments,
        budget: budget,
      ),
      scenario: label,
      budget: budget,
    );
  }
}

Map<String, dynamic> _hostBoundarySpecification() {
  return <String, dynamic>{
    'version': 2,
    'buffers': <String, dynamic>{'bytes': 4},
    'functions': <String, dynamic>{
      'run': <String, dynamic>{
        'body': <dynamic>[
          <dynamic>['setu8', 'bytes', 0, 10],
          <dynamic>['host', 'mark', <dynamic>[]],
          <dynamic>['setu8', 'bytes', 1, 20],
          <dynamic>['ret', 9],
        ],
      },
    },
  };
}

Map<String, dynamic> _controlFlowSpecification() {
  final denseCases = <dynamic>[
    for (var key = 10; key <= 14; key++)
      <dynamic>[
        key,
        <dynamic>[
          <dynamic>['setu8', 'bytes', 8, key],
        ],
      ],
  ];
  final sparseCases = <dynamic>[
    <dynamic>[
      -1000,
      <dynamic>[
        <dynamic>[
          'host',
          'mark',
          <dynamic>[31],
        ],
      ],
    ],
    <dynamic>[
      7,
      <dynamic>[
        <dynamic>[
          'host',
          'mark',
          <dynamic>[32],
        ],
      ],
    ],
    <dynamic>[
      1000000,
      <dynamic>[
        <dynamic>[
          'host',
          'mark',
          <dynamic>[33],
        ],
      ],
    ],
  ];

  return <String, dynamic>{
    'version': 2,
    'buffers': <String, dynamic>{'bytes': 16},
    'i32': <String, dynamic>{'words': 4},
    'functions': <String, dynamic>{
      'run': <String, dynamic>{
        'params': <String>['mode', 'limit', 'gate'],
        'body': <dynamic>[
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
                'setu8',
                'bytes',
                <dynamic>['var', 'i'],
                <dynamic>[
                  '+',
                  <dynamic>['var', 'i'],
                  1,
                ],
              ],
              <dynamic>[
                'set',
                'i',
                <dynamic>[
                  '+',
                  <dynamic>['var', 'i'],
                  1,
                ],
              ],
            ],
          ],
          <dynamic>[
            'if',
            <dynamic>[
              'and',
              <dynamic>['var', 'gate'],
              <dynamic>[
                'host',
                'mark',
                <dynamic>[10],
              ],
            ],
            <dynamic>[
              <dynamic>['seti32', 'words', 0, 111],
            ],
            <dynamic>[
              <dynamic>['seti32', 'words', 0, 222],
            ],
          ],
          <dynamic>[
            'switch',
            <dynamic>['var', 'mode'],
            denseCases,
            <dynamic>[
              <dynamic>['setu8', 'bytes', 9, 90],
            ],
          ],
          <dynamic>[
            'switch',
            <dynamic>['var', 'mode'],
            sparseCases,
            <dynamic>[
              <dynamic>['nop'],
            ],
          ],
          <dynamic>[
            'if',
            <dynamic>[
              '==',
              <dynamic>['var', 'mode'],
              99,
            ],
            <dynamic>[
              <dynamic>['ret', 990],
            ],
          ],
          <dynamic>[
            'host',
            'mark',
            <dynamic>[20],
          ],
          <dynamic>[
            'ret',
            <dynamic>['i32', 'words', 0],
          ],
        ],
      },
    },
  };
}

Map<String, dynamic> _minimalLoopSpecification() {
  return <String, dynamic>{
    'version': 2,
    'functions': <String, dynamic>{
      'run': <String, dynamic>{
        'params': <String>['limit'],
        'body': <dynamic>[
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
            ],
          ],
          <dynamic>[
            'ret',
            <dynamic>['var', 'i'],
          ],
        ],
      },
    },
  };
}

Map<String, dynamic> _callAndBulkSpecification() {
  return <String, dynamic>{
    'version': 2,
    'buffers': <String, dynamic>{'bytes': 32, 'source': 16, 'lut': 256},
    'i32': <String, dynamic>{'words': 4},
    'init': <String, dynamic>{
      'source': List<int>.generate(16, (index) => index),
      'lut': List<int>.generate(256, (index) => 255 - index),
    },
    'functions': <String, dynamic>{
      'leaf': <String, dynamic>{
        'params': <String>['value'],
        'body': <dynamic>[
          <dynamic>['setu8', 'bytes', 0, 11],
          <dynamic>['setu8', 'bytes', 1, 12],
          <dynamic>['setu8', 'bytes', 2, 13],
          <dynamic>['setu8', 'bytes', 3, 14],
          <dynamic>[
            'host',
            'mark',
            <dynamic>[1],
          ],
          <dynamic>[
            'memset',
            'bytes',
            4,
            8,
            <dynamic>['var', 'value'],
          ],
          <dynamic>['memlut', 'bytes', 16, 'source', 0, 8, 'lut', 0],
          <dynamic>['planar8', 'bytes', 24, 0x91, 0x50, 0x0c, 0],
          <dynamic>['seti32', 'words', 0, 12345],
          <dynamic>[
            'ret',
            <dynamic>['var', 'value'],
          ],
        ],
      },
      'run': <String, dynamic>{
        'params': <String>['value'],
        'body': <dynamic>[
          <dynamic>['setu8', 'bytes', 1, 22],
          <dynamic>[
            'set',
            'result',
            <dynamic>[
              'call',
              'leaf',
              <dynamic>[
                <dynamic>['var', 'value'],
              ],
            ],
          ],
          <dynamic>[
            'host',
            'mark',
            <dynamic>[2],
          ],
          <dynamic>[
            'setu8',
            'bytes',
            2,
            <dynamic>['var', 'result'],
          ],
          <dynamic>[
            'ret',
            <dynamic>['var', 'result'],
          ],
        ],
      },
    },
  };
}

void main() {
  group('Compute VM IR compatibility contract', () {
    test(
      'preserves the legacy logical pc and side-effect boundary exactly',
      () {
        final specification = _hostBoundarySpecification();
        final scalar = ComputeVmProgram.compile(
          specification,
          optimize: false,
          hosts: <String, ComputeVmHostFunction>{'mark': (_) => 0},
        );
        final optimized = ComputeVmProgram.compile(
          specification,
          optimize: true,
          hosts: <String, ComputeVmHostFunction>{'mark': (_) => 0},
        );

        expect(scalar.functionInfo('run')!.instructionCount, 10);
        expect(optimized.functionInfo('run')!.instructionCount, 10);
        expect(optimized.functionInfo('run')!.usesFusedBytecode, isTrue);

        _expectBudgetParity(specification, entry: 'run');

        final expectedBoundaries =
            <int, ({int? pc, List<int> bytes, List<int> events, int? result})>{
              1: (
                pc: 1,
                bytes: <int>[0, 0, 0, 0],
                events: <int>[],
                result: null,
              ),
              2: (
                pc: 2,
                bytes: <int>[0, 0, 0, 0],
                events: <int>[],
                result: null,
              ),
              3: (
                pc: 3,
                bytes: <int>[10, 0, 0, 0],
                events: <int>[],
                result: null,
              ),
              4: (
                pc: 4,
                bytes: <int>[10, 0, 0, 0],
                events: <int>[-1],
                result: null,
              ),
              6: (
                pc: 6,
                bytes: <int>[10, 0, 0, 0],
                events: <int>[-1],
                result: null,
              ),
              7: (
                pc: 7,
                bytes: <int>[10, 20, 0, 0],
                events: <int>[-1],
                result: null,
              ),
              8: (
                pc: 8,
                bytes: <int>[10, 20, 0, 0],
                events: <int>[-1],
                result: null,
              ),
              9: (
                pc: null,
                bytes: <int>[10, 20, 0, 0],
                events: <int>[-1],
                result: 9,
              ),
            };
        for (final entry in expectedBoundaries.entries) {
          final outcome = _execute(
            specification,
            optimize: true,
            entry: 'run',
            arguments: const <int>[],
            budget: entry.key,
          );
          expect(
            outcome.error?.executedInstructions,
            entry.value.pc == null ? isNull : entry.key,
            reason: 'executed instructions at budget ${entry.key}',
          );
          expect(
            outcome.error?.function,
            entry.value.pc == null ? isNull : 'run',
            reason: 'failure function at budget ${entry.key}',
          );
          expect(
            outcome.error?.instruction,
            entry.value.pc,
            reason: 'legacy logical pc at budget ${entry.key}',
          );
          expect(outcome.u8['bytes'], entry.value.bytes);
          expect(outcome.hostEvents, entry.value.events);
          expect(outcome.result, entry.value.result);
        }
      },
    );

    test('maps loop back-edge failures to the legacy logical pc', () {
      final specification = _minimalLoopSpecification();
      for (final optimize in <bool>[false, true]) {
        final outcome = _execute(
          specification,
          optimize: optimize,
          entry: 'run',
          arguments: const <int>[1],
          budget: 8,
        );
        expect(outcome.result, isNull);
        expect(outcome.error?.budget, 8);
        expect(outcome.error?.executedInstructions, 8);
        expect(outcome.error?.function, 'run');
        expect(
          outcome.error?.instruction,
          8,
          reason: 'optimize=$optimize must report the scalar logical pc',
        );
      }
      _expectBudgetParity(
        specification,
        entry: 'run',
        arguments: const <int>[1],
        scenario: 'minimal while-loop source mapping',
      );
    });

    test(
      'keeps jumps, switches, loops, and early returns budget-identical',
      () {
        final specification = _controlFlowSpecification();
        for (final optimize in <bool>[false, true]) {
          final program = ComputeVmProgram.compile(
            specification,
            optimize: optimize,
            hosts: <String, ComputeVmHostFunction>{'mark': (_) => 1},
          );
          final info = program.functionInfo('run')!;
          expect(info.jumpTableSwitchCount, 1);
          expect(info.binarySearchSwitchCount, 1);
        }

        for (final testCase
            in <({List<int> arguments, int result, List<int> events})>[
              (arguments: <int>[10, 0, 0], result: 222, events: <int>[20]),
              (arguments: <int>[14, 2, 1], result: 111, events: <int>[10, 20]),
              (
                arguments: <int>[7, 1, 1],
                result: 111,
                events: <int>[10, 32, 20],
              ),
              (
                arguments: <int>[1000000, 2, 0],
                result: 222,
                events: <int>[33, 20],
              ),
              (arguments: <int>[99, 1, 1], result: 990, events: <int>[10]),
              (
                arguments: <int>[-1000, 0, 0],
                result: 222,
                events: <int>[31, 20],
              ),
            ]) {
          _expectBudgetParity(
            specification,
            entry: 'run',
            arguments: testCase.arguments,
          );
          final completed = _execute(
            specification,
            optimize: true,
            entry: 'run',
            arguments: testCase.arguments,
            budget: 512,
          );
          expect(completed.error, isNull);
          expect(completed.result, testCase.result);
          expect(completed.hostEvents, testCase.events);
        }
      },
    );

    test('keeps call, host, and bulk effects ordered at every budget', () {
      final specification = _callAndBulkSpecification();
      final scalar = ComputeVmProgram.compile(
        specification,
        optimize: false,
        hosts: <String, ComputeVmHostFunction>{'mark': (_) => 0},
      );
      final optimized = ComputeVmProgram.compile(
        specification,
        optimize: true,
        hosts: <String, ComputeVmHostFunction>{'mark': (_) => 0},
      );
      for (final function in <String>['run', 'leaf']) {
        expect(
          optimized.functionInfo(function)!.instructionCount,
          scalar.functionInfo(function)!.instructionCount,
          reason: '$function must retain its logical instruction address space',
        );
      }
      expect(
        optimized.functionInfo('leaf')!.usesFusedBytecode,
        isTrue,
        reason: 'the contract must exercise the fused bulk dispatch',
      );

      _expectBudgetParity(
        specification,
        entry: 'run',
        arguments: const <int>[77],
      );

      final successBudget = _firstSuccessfulBudget(
        specification,
        entry: 'run',
        arguments: const <int>[77],
      );
      final snapshots = <_ExecutionSnapshot>[
        for (var budget = 1; budget < successBudget; budget++)
          _execute(
            specification,
            optimize: true,
            entry: 'run',
            arguments: const <int>[77],
            budget: budget,
          ),
      ];

      expect(
        snapshots,
        contains(
          isA<_ExecutionSnapshot>()
              .having(
                (snapshot) => snapshot.hostEvents,
                'leaf host ran before a later failure',
                <int>[1],
              )
              .having(
                (snapshot) => snapshot.u8['bytes']!.sublist(4, 12),
                'memset remains atomic until fully charged',
                everyElement(0),
              ),
        ),
      );
      expect(
        snapshots,
        contains(
          isA<_ExecutionSnapshot>()
              .having(
                (snapshot) => snapshot.u8['bytes']!.sublist(16, 24),
                'completed memlut',
                <int>[255, 254, 253, 252, 251, 250, 249, 248],
              )
              .having(
                (snapshot) => snapshot.u8['bytes']!.sublist(24, 32),
                'planar8 remains atomic until fully charged',
                everyElement(0),
              ),
        ),
      );
      expect(
        snapshots,
        contains(
          isA<_ExecutionSnapshot>()
              .having(
                (snapshot) => snapshot.u8['bytes']!.sublist(4, 12),
                'completed memset',
                everyElement(77),
              )
              .having(
                (snapshot) => snapshot.u8['bytes']!.sublist(16, 24),
                'memlut remains atomic until fully charged',
                everyElement(0),
              ),
        ),
      );

      final completed = _execute(
        specification,
        optimize: true,
        entry: 'run',
        arguments: const <int>[77],
        budget: successBudget,
      );
      expect(completed.result, 77);
      expect(completed.hostEvents, <int>[1, 2]);
      expect(completed.u8['bytes']!.sublist(4, 12), everyElement(77));
      expect(completed.u8['bytes']!.sublist(16, 24), <int>[
        255,
        254,
        253,
        252,
        251,
        250,
        249,
        248,
      ]);
      expect(completed.u8['bytes']!.sublist(24, 32), <int>[
        1 | 12,
        2 | 12,
        0,
        3 | 12,
        0,
        0,
        0,
        1 | 12,
      ]);
      expect(completed.i32['words']![0], 12345);
    });
  });
}
