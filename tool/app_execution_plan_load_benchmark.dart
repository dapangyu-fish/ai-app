import 'dart:convert';
import 'dart:io';

import 'package:flutter_application_1/json_ui/execution/app_execution_plan.dart';

const _jsonLogicOperators = <String>{
  'var',
  'missing',
  'missing_some',
  'if',
  '?:',
  'and',
  'or',
  '!',
  '!!',
  '==',
  '!=',
  '===',
  '!==',
  '<',
  '<=',
  '>',
  '>=',
  '+',
  '-',
  '*',
  '/',
  '%',
  'min',
  'max',
  'cat',
  'substr',
  'in',
  'map',
  'filter',
  'reduce',
  'all',
  'some',
  'none',
  'merge',
  'method',
  'log',
};

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln(
      'usage: app_execution_plan_load_benchmark <app.json> [samples]',
    );
    exitCode = 64;
    return;
  }
  final samples = arguments.length > 1 ? int.parse(arguments[1]) : 15;
  final hashMode = arguments.length > 2 && arguments[2] == 'canonical'
      ? AppSourceHashMode.canonicalJson
      : AppSourceHashMode.runtimeIdentity;
  final source = File(arguments.first).readAsStringSync();
  final config = jsonDecode(source) as Map<String, dynamic>;
  const widgets = <String>{'flame_game', 'text', 'button', 'column', 'row'};

  AppExecutionPlan compile() => AppExecutionPlan.compile(
    config,
    knownJsonLogicOperators: _jsonLogicOperators,
    knownWidgetTypes: widgets,
    sourceHashMode: hashMode,
  );

  for (var index = 0; index < 3; index++) {
    compile();
  }
  final timings = <int>[];
  AppExecutionPlan? lastPlan;
  for (var index = 0; index < samples; index++) {
    final watch = Stopwatch()..start();
    lastPlan = compile();
    watch.stop();
    timings.add(watch.elapsedMicroseconds);
  }
  timings.sort();
  final plan = lastPlan!;
  stdout.writeln('file_bytes=${source.length}');
  stdout.writeln('samples=$samples');
  stdout.writeln('p50_us=${timings[timings.length ~/ 2]}');
  stdout.writeln('min_us=${timings.first}');
  stdout.writeln('max_us=${timings.last}');
  stdout.writeln('value_plans=${plan.stats.valuePlanCount}');
  stdout.writeln('opaque_values=${plan.stats.opaqueValueCount}');
  stdout.writeln('expressions=${plan.stats.expressionCount}');
  stdout.writeln('templates=${plan.stats.templateCount}');
  stdout.writeln('state_slots=${plan.stats.stateSlotCount}');
}
