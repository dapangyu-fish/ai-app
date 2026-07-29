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
  final specification = <String, dynamic>{
    'version': 2,
    'buffers': <String, dynamic>{'scratch': 8},
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
      'denseLoop': <String, dynamic>{
        'params': <String>['iterations'],
        'body': <dynamic>[
          <dynamic>['set', 'checksum', 0],
          <dynamic>[
            'repeat',
            <dynamic>['var', 'iterations'],
            <dynamic>[
              <dynamic>['setu8', 'scratch', 0, 17],
              <dynamic>['setu8', 'scratch', 1, 23],
              <dynamic>[
                'set',
                'checksum',
                <dynamic>[
                  '+',
                  <dynamic>['var', 'checksum'],
                  3,
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
  };
  final optimized = ComputeVmProgram.compile(
    specification,
    // Benchmark-only allowance: published JSON Apps keep the 5M ceiling.
    limits: const ComputeVmLimits(maxBudget: 20000000),
  );
  final scalar = ComputeVmProgram.compile(
    specification,
    limits: const ComputeVmLimits(maxBudget: 20000000),
    optimize: false,
  );

  final remainder = iterations % 256;
  final expected =
      (iterations ~/ 256) * 32640 + (remainder * (remainder - 1) ~/ 2);
  for (var index = 0; index < 3; index++) {
    final optimizedResult = optimized.call(
      'dispatch256',
      args: <int>[math.min(iterations, 10000)],
      budget: 20000000,
    );
    final scalarResult = scalar.call(
      'dispatch256',
      args: <int>[math.min(iterations, 10000)],
      budget: 20000000,
    );
    if (optimizedResult != scalarResult) {
      throw StateError(
        'warm-up mismatch: optimized=$optimizedResult, scalar=$scalarResult',
      );
    }
    final optimizedDenseResult = optimized.call(
      'denseLoop',
      args: <int>[math.min(iterations, 10000)],
      budget: 20000000,
    );
    final scalarDenseResult = scalar.call(
      'denseLoop',
      args: <int>[math.min(iterations, 10000)],
      budget: 20000000,
    );
    if (optimizedDenseResult != scalarDenseResult) {
      throw StateError(
        'dense warm-up mismatch: optimized=$optimizedDenseResult, '
        'scalar=$scalarDenseResult',
      );
    }
  }

  final optimizedSamples = <double>[];
  final scalarSamples = <double>[];
  var optimizedResult = 0;
  var scalarResult = 0;
  for (var sample = 0; sample < 5; sample++) {
    // Alternate order to reduce systematic thermal/frequency bias.
    if (sample.isEven) {
      scalarResult = _sample(scalar, 'dispatch256', iterations, scalarSamples);
      optimizedResult = _sample(
        optimized,
        'dispatch256',
        iterations,
        optimizedSamples,
      );
    } else {
      optimizedResult = _sample(
        optimized,
        'dispatch256',
        iterations,
        optimizedSamples,
      );
      scalarResult = _sample(scalar, 'dispatch256', iterations, scalarSamples);
    }
  }
  optimizedSamples.sort();
  scalarSamples.sort();
  final expectedInt32 = expected.toSigned(32);
  if (optimizedResult != expectedInt32 || scalarResult != expectedInt32) {
    throw StateError(
      'wrong result: optimized=$optimizedResult, scalar=$scalarResult, '
      'expected=$expectedInt32',
    );
  }

  final info = optimized.functionInfo('dispatch256')!;
  final optimizedMedian = optimizedSamples[optimizedSamples.length ~/ 2];
  final scalarMedian = scalarSamples[scalarSamples.length ~/ 2];
  print('Compute VM v2 AOT benchmark');
  print('iterations: $iterations');
  print('bytecode instructions: ${info.instructionCount}');
  print('physical instructions: ${info.physicalInstructionCount}');
  print('basic blocks: ${info.basicBlockCount}');
  print('static dispatch savings: ${info.staticDispatchSavings}');
  print('selected runner: ${info.requiresFusedRunner ? 'fused' : 'scalar'}');
  print(
    'scalar median iterations/s: ${scalarMedian.toStringAsFixed(0)} '
    '(${(1000000000 / scalarMedian).toStringAsFixed(1)} ns/iteration)',
  );
  print(
    'optimized median iterations/s: ${optimizedMedian.toStringAsFixed(0)} '
    '(${(1000000000 / optimizedMedian).toStringAsFixed(1)} ns/iteration)',
  );
  print('speedup: ${(optimizedMedian / scalarMedian).toStringAsFixed(3)}x');

  final optimizedDenseSamples = <double>[];
  final scalarDenseSamples = <double>[];
  var optimizedDenseResult = 0;
  var scalarDenseResult = 0;
  for (var sample = 0; sample < 5; sample++) {
    if (sample.isEven) {
      scalarDenseResult = _sample(
        scalar,
        'denseLoop',
        iterations,
        scalarDenseSamples,
      );
      optimizedDenseResult = _sample(
        optimized,
        'denseLoop',
        iterations,
        optimizedDenseSamples,
      );
    } else {
      optimizedDenseResult = _sample(
        optimized,
        'denseLoop',
        iterations,
        optimizedDenseSamples,
      );
      scalarDenseResult = _sample(
        scalar,
        'denseLoop',
        iterations,
        scalarDenseSamples,
      );
    }
  }
  if (optimizedDenseResult != scalarDenseResult) {
    throw StateError(
      'dense result mismatch: optimized=$optimizedDenseResult, '
      'scalar=$scalarDenseResult',
    );
  }
  optimizedDenseSamples.sort();
  scalarDenseSamples.sort();
  final optimizedDenseMedian =
      optimizedDenseSamples[optimizedDenseSamples.length ~/ 2];
  final scalarDenseMedian = scalarDenseSamples[scalarDenseSamples.length ~/ 2];
  final denseInfo = optimized.functionInfo('denseLoop')!;
  print('');
  print('Dense arithmetic/buffer loop');
  print('bytecode instructions: ${denseInfo.instructionCount}');
  print('physical instructions: ${denseInfo.physicalInstructionCount}');
  print('basic blocks: ${denseInfo.basicBlockCount}');
  print('static dispatch savings: ${denseInfo.staticDispatchSavings}');
  print(
    'selected runner: ${denseInfo.requiresFusedRunner ? 'fused' : 'scalar'}',
  );
  print(
    'scalar median iterations/s: ${scalarDenseMedian.toStringAsFixed(0)} '
    '(${(1000000000 / scalarDenseMedian).toStringAsFixed(1)} ns/iteration)',
  );
  print(
    'optimized median iterations/s: '
    '${optimizedDenseMedian.toStringAsFixed(0)} '
    '(${(1000000000 / optimizedDenseMedian).toStringAsFixed(1)} '
    'ns/iteration)',
  );
  print(
    'speedup: '
    '${(optimizedDenseMedian / scalarDenseMedian).toStringAsFixed(3)}x',
  );
}

int _sample(
  ComputeVmProgram program,
  String function,
  int iterations,
  List<double> samples,
) {
  final stopwatch = Stopwatch()..start();
  final result = program.call(
    function,
    args: <int>[iterations],
    budget: 20000000,
  );
  stopwatch.stop();
  samples.add(iterations / stopwatch.elapsedMicroseconds * 1000000);
  return result;
}
