// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';

/// AOT benchmark for a complete Compute VM application frame.
///
/// Usage:
///   dart compile exe tool/nes_compute_vm_benchmark.dart \
///     -o /tmp/nes_compute_vm_benchmark
///   /tmp/nes_compute_vm_benchmark app.json [warmupFrames] [sampleFrames]
///
/// Despite the convenient NES fixture, the measured path is the public,
/// generic [ComputeVmProgram] API. No emulator-specific runtime is involved.
void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln(
      'usage: nes_compute_vm_benchmark <app.json> '
      '[warmupFrames] [sampleFrames]',
    );
    exitCode = 64;
    return;
  }
  final templatePath = arguments.first;
  final warmupFrames = arguments.length > 1 ? int.parse(arguments[1]) : 70;
  final sampleFrames = arguments.length > 2 ? int.parse(arguments[2]) : 120;
  if (warmupFrames < 0 || sampleFrames <= 0) {
    throw ArgumentError('frame counts must be warmup >= 0 and sample > 0');
  }

  final root =
      jsonDecode(File(templatePath).readAsStringSync()) as Map<String, dynamic>;
  final compute = root['compute'] as Map<String, dynamic>;
  final specification = compute['program'] as Map<String, dynamic>;
  const maximumBudget = 16 * 1000 * 1000;
  final compileWatch = Stopwatch()..start();
  final program = ComputeVmProgram.compile(
    specification,
    limits: const ComputeVmLimits(maxBudget: maximumBudget),
  );
  compileWatch.stop();

  final functions = specification['functions'] as Map<String, dynamic>;
  var logicalInstructions = 0;
  var activeStaticDispatches = 0;
  var fusedFunctions = 0;
  for (final name in functions.keys) {
    final info = program.functionInfo(name)!;
    logicalInstructions += info.instructionCount;
    activeStaticDispatches +=
        info.instructionCount - info.staticDispatchSavings;
    if (info.usesFusedBytecode) fusedFunctions++;
  }
  final frameInfo = program.functionInfo('run_frame')!;
  final mapper = program.call('load_ines', budget: maximumBudget);
  for (var frame = 0; frame < warmupFrames; frame++) {
    program.call('run_frame', args: const <int>[80000], budget: maximumBudget);
  }

  final samples = <int>[];
  final allWatch = Stopwatch()..start();
  var cpuInstructions = 0;
  for (var frame = 0; frame < sampleFrames; frame++) {
    final watch = Stopwatch()..start();
    cpuInstructions += program.call(
      'run_frame',
      args: const <int>[80000],
      budget: maximumBudget,
    );
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  allWatch.stop();
  samples.sort();

  final totalUs = allWatch.elapsedMicroseconds;
  final averageUs = totalUs / sampleFrames;
  final medianUs = samples[samples.length ~/ 2];
  final p90Us =
      samples[(samples.length * 9 ~/ 10).clamp(0, samples.length - 1)];
  var checksum = 0;
  for (final value in program.buffer('fb')) {
    checksum = ((checksum * 16777619) ^ value).toSigned(32);
  }

  print('Compute VM full-frame AOT benchmark');
  print('fixture=$templatePath');
  print('mapper=$mapper');
  print('compile_ms=${compileWatch.elapsedMicroseconds / 1000}');
  print(
    'module_functions=${functions.length} fused_functions=$fusedFunctions '
    'logical_instructions=$logicalInstructions '
    'active_static_dispatches=$activeStaticDispatches',
  );
  print(
    'run_frame_logical=${frameInfo.instructionCount} '
    'run_frame_static_dispatches='
    '${frameInfo.instructionCount - frameInfo.staticDispatchSavings}',
  );
  print('warmup_frames=$warmupFrames sample_frames=$sampleFrames');
  print('average_ms=${averageUs / 1000}');
  print('median_ms=${medianUs / 1000}');
  print('p90_ms=${p90Us / 1000}');
  print('throughput_fps=${(1000000 / averageUs).toStringAsFixed(2)}');
  print('cpu_instructions=$cpuInstructions checksum=$checksum');
}
