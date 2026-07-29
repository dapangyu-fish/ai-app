// ignore_for_file: avoid_print

import 'dart:math' as math;

import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';

/// A small AOT-friendly benchmark for the VM's hottest generic operations.
///
/// Run with:
///   dart compile exe tool/compute_vm_benchmark.dart -o /tmp/compute_vm_bench
///   /tmp/compute_vm_bench
void main(List<String> arguments) {
  final iterations = arguments.isEmpty ? 1000000 : int.parse(arguments.first);
  if (iterations <= 0) {
    throw ArgumentError.value(iterations, 'iterations', 'must be positive');
  }

  final cases = <dynamic>[
    for (var opcode = 0; opcode < 256; opcode++)
      <dynamic>[
        opcode,
        <dynamic>[
          <dynamic>[
            'set',
            'checksum',
            <dynamic>[
              '+',
              <dynamic>['var', 'checksum'],
              opcode,
            ],
          ],
        ],
      ],
  ];
  final program = ComputeVmProgram.compile(
    <String, dynamic>{
      'version': 2,
      'functions': <String, dynamic>{
        'dispatch256': <String, dynamic>{
          'params': <String>['iterations'],
          'body': <dynamic>[
            <dynamic>['set', 'index', 0],
            <dynamic>['set', 'checksum', 0],
            <dynamic>[
              'repeat',
              <dynamic>['var', 'iterations'],
              <dynamic>[
                <dynamic>[
                  'switch',
                  <dynamic>[
                    '&',
                    <dynamic>['var', 'index'],
                    255,
                  ],
                  cases,
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
              <dynamic>['var', 'checksum'],
            ],
          ],
        },
      },
    },
    // Benchmark-only allowance: published JSON Apps keep the 5M ceiling.
    limits: const ComputeVmLimits(maxBudget: 20000000),
  );

  final remainder = iterations % 256;
  final expected =
      (iterations ~/ 256) * 32640 + (remainder * (remainder - 1) ~/ 2);
  for (var index = 0; index < 3; index++) {
    final result = program.call(
      'dispatch256',
      args: <int>[math.min(iterations, 10000)],
      budget: 20000000,
    );
    if (result < 0) throw StateError('unexpected warm-up result: $result');
  }

  final samples = <double>[];
  var result = 0;
  for (var sample = 0; sample < 5; sample++) {
    final stopwatch = Stopwatch()..start();
    result = program.call(
      'dispatch256',
      args: <int>[iterations],
      budget: 20000000,
    );
    stopwatch.stop();
    samples.add(iterations / stopwatch.elapsedMicroseconds * 1000000);
  }
  samples.sort();
  if (result != expected.toSigned(32)) {
    throw StateError(
      'wrong result: $result, expected ${expected.toSigned(32)}',
    );
  }

  final info = program.functionInfo('dispatch256')!;
  final median = samples[samples.length ~/ 2];
  print('Compute VM v2 AOT benchmark');
  print('iterations: $iterations');
  print('bytecode instructions: ${info.instructionCount}');
  print('basic blocks: ${info.basicBlockCount}');
  print('median dispatch iterations/s: ${median.toStringAsFixed(0)}');
  print('median ns/iteration: ${(1000000000 / median).toStringAsFixed(1)}');
}
