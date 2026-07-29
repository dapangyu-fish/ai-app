// ignore_for_file: avoid_print

import 'dart:math' as math;

import 'package:flutter_application_1/json_ui/execution/compiled_json_logic_evaluator.dart';
import 'package:flutter_application_1/json_ui/execution/expression_plan.dart';
import 'package:flutter_application_1/json_ui/execution/template_plan.dart';
import 'package:jsonlogic/jsonlogic.dart';

/// Pure-Dart AOT benchmark for the generic compiled JSONLogic execution path.
///
/// Compilation is intentionally outside all timed regions. The legacy side
/// includes the recursive template/rule preprocessing performed by the JSON
/// App interpreter before every `Jsonlogic.apply` call. Both sides use cached
/// [TemplatePlan] instances and resolve the same dynamic templates.
///
/// Run with:
///
///   dart compile exe tool/json_logic_plan_benchmark.dart \
///     -o /tmp/json_logic_plan_benchmark
///   /tmp/json_logic_plan_benchmark [iterations] [samples]
void main(List<String> arguments) {
  final iterations = arguments.isEmpty ? 150000 : int.parse(arguments.first);
  final sampleCount = arguments.length < 2 ? 9 : int.parse(arguments[1]);
  if (iterations <= 0) {
    throw ArgumentError.value(iterations, 'iterations', 'must be positive');
  }
  if (sampleCount <= 0 || sampleCount.isEven) {
    throw ArgumentError.value(
      sampleCount,
      'samples',
      'must be a positive odd number',
    );
  }

  final benchmark = _JsonLogicBenchmark();

  // Compile the immutable plan before warm-up and all measured samples.
  final compiler = JsonLogicPlanCompiler(
    knownOperators: _knownOperators,
    templateFor: benchmark.templateFor,
  );
  final plan = compiler.compile(benchmark.rule, r'$.benchmark.rule');
  final evaluator = CompiledJsonLogicEvaluator(
    templateResolver: benchmark.resolveTemplatePlan,
    fallbackPreprocessor: benchmark.preprocessLegacyRule,
    fallbackRuntime: benchmark.runtime,
  );

  final warmupIterations = math.min(iterations, 10000);
  for (var round = 0; round < 3; round++) {
    final legacy = benchmark.runLegacy(warmupIterations);
    final compiled = benchmark.runCompiled(evaluator, plan, warmupIterations);
    _verifyChecksums('warm-up $round', legacy, compiled);
  }

  final legacySamples = <int>[];
  final compiledSamples = <int>[];
  var verifiedChecksum = 0;
  for (var sample = 0; sample < sampleCount; sample++) {
    late final int legacyChecksum;
    late final int compiledChecksum;

    // Alternate order to reduce systematic thermal/frequency bias.
    if (sample.isEven) {
      legacyChecksum = _measure(
        () => benchmark.runLegacy(iterations),
        legacySamples,
      );
      compiledChecksum = _measure(
        () => benchmark.runCompiled(evaluator, plan, iterations),
        compiledSamples,
      );
    } else {
      compiledChecksum = _measure(
        () => benchmark.runCompiled(evaluator, plan, iterations),
        compiledSamples,
      );
      legacyChecksum = _measure(
        () => benchmark.runLegacy(iterations),
        legacySamples,
      );
    }
    _verifyChecksums('sample $sample', legacyChecksum, compiledChecksum);
    verifiedChecksum = compiledChecksum;
  }

  legacySamples.sort();
  compiledSamples.sort();
  final legacyP50 = legacySamples[legacySamples.length ~/ 2];
  final compiledP50 = compiledSamples[compiledSamples.length ~/ 2];
  final legacyNsPerEvaluation = legacyP50 * 1000 / iterations;
  final compiledNsPerEvaluation = compiledP50 * 1000 / iterations;

  print('Compiled JSONLogic AOT benchmark');
  print('iterations/sample: $iterations');
  print('samples: $sampleCount');
  print(
    'workload: nested arithmetic/comparison/if/and, static vars, '
    '2 dynamic templates',
  );
  print('plan compilation: outside timed regions');
  print(
    'legacy p50: ${legacyP50}us '
    '(${legacyNsPerEvaluation.toStringAsFixed(1)} ns/eval)',
  );
  print(
    'compiled p50: ${compiledP50}us '
    '(${compiledNsPerEvaluation.toStringAsFixed(1)} ns/eval)',
  );
  print('speedup: ${(legacyP50 / compiledP50).toStringAsFixed(3)}x');
  print('checksum: $verifiedChecksum (legacy == compiled)');
}

const Set<String> _knownOperators = <String>{
  'var',
  'if',
  'and',
  '==',
  '>',
  '<=',
  '+',
  '-',
  '*',
  '/',
  '%',
};

final class _JsonLogicBenchmark {
  _JsonLogicBenchmark()
    : rule = <String, dynamic>{
        'if': <dynamic>[
          <String, dynamic>{
            'and': <dynamic>[
              <String, dynamic>{
                '>': <dynamic>[
                  <String, dynamic>{
                    '+': <dynamic>[
                      <String, dynamic>{
                        '*': <dynamic>[
                          <String, dynamic>{'var': 'global.player.x'},
                          <String, dynamic>{'var': 'global.physics.scale'},
                        ],
                      },
                      <String, dynamic>{'var': 'global.player.velocity'},
                      <String, dynamic>{
                        '%': <dynamic>[
                          <String, dynamic>{'var': 'global.tick'},
                          7,
                        ],
                      },
                    ],
                  },
                  <String, dynamic>{'var': 'global.threshold'},
                ],
              },
              <String, dynamic>{
                '<=': <dynamic>[
                  <String, dynamic>{
                    '/': <dynamic>[
                      <String, dynamic>{
                        '+': <dynamic>[
                          <String, dynamic>{'var': 'global.elapsed'},
                          <String, dynamic>{'var': 'global.latency'},
                        ],
                      },
                      <String, dynamic>{
                        '+': <dynamic>[
                          <String, dynamic>{'var': 'global.frameDivisor'},
                          1,
                        ],
                      },
                    ],
                  },
                  <String, dynamic>{'var': 'global.timeLimit'},
                ],
              },
              <String, dynamic>{
                '==': <dynamic>[
                  <String, dynamic>{'var': 'global.mode'},
                  '{{ global.expectedMode }}',
                ],
              },
            ],
          },
          <String, dynamic>{
            '+': <dynamic>[
              <String, dynamic>{
                '*': <dynamic>[
                  <String, dynamic>{'var': 'global.score'},
                  <String, dynamic>{'var': 'global.combo'},
                  '{{ global.templateMultiplier }}',
                ],
              },
              <String, dynamic>{
                '-': <dynamic>[
                  <String, dynamic>{'var': 'global.bonus'},
                  <String, dynamic>{'var': 'global.penalty'},
                ],
              },
              <String, dynamic>{
                '%': <dynamic>[
                  <String, dynamic>{'var': 'global.tick'},
                  11,
                ],
              },
            ],
          },
          <String, dynamic>{
            '-': <dynamic>[
              0,
              <String, dynamic>{
                '+': <dynamic>[
                  <String, dynamic>{'var': 'global.penalty'},
                  <String, dynamic>{
                    '%': <dynamic>[
                      <String, dynamic>{'var': 'global.tick'},
                      3,
                    ],
                  },
                ],
              },
            ],
          },
        ],
      };

  final Jsonlogic runtime = Jsonlogic();
  final Map<String, dynamic> rule;
  final Map<String, TemplatePlan> _templates = <String, TemplatePlan>{};
  final Map<String, dynamic> _global = <String, dynamic>{
    'player': <String, dynamic>{'x': 0.0, 'velocity': 0.0},
    'physics': <String, dynamic>{'scale': 1.25},
    'tick': 0,
    'threshold': 55.0,
    'elapsed': 0.0,
    'latency': 3.0,
    'frameDivisor': 2,
    'timeLimit': 30.0,
    'mode': 'run',
    'expectedMode': 'run',
    'score': 100.0,
    'combo': 1.0,
    'templateMultiplier': 1.25,
    'bonus': 12.0,
    'penalty': 4.0,
  };

  late final Map<String, dynamic> _data = <String, dynamic>{'global': _global};

  TemplatePlan templateFor(String source) {
    return _templates.putIfAbsent(source, () => TemplatePlan.compile(source));
  }

  String resolveTemplatePlan(TemplatePlan plan) {
    final output = StringBuffer();
    for (final part in plan.parts) {
      if (part is TemplateLiteralPart) {
        output.write(part.value);
      } else if (part is TemplateBindingPart) {
        final variable = part.variable;
        if (variable == null ||
            variable.namespace != VariableNamespace.global) {
          output.write(part.token);
          continue;
        }
        final lookup = variable.pathPlan.lookup(_global);
        output.write(
          _stringifyTemplateValue(lookup.found ? lookup.value : null),
        );
      }
    }
    return output.toString();
  }

  dynamic preprocessLegacyRule(dynamic value) {
    if (value is String && value.contains('{{') && value.contains('}}')) {
      return resolveTemplatePlan(templateFor(value));
    }
    if (value is List) {
      return <dynamic>[for (final item in value) preprocessLegacyRule(item)];
    }
    if (value is Map<String, dynamic>) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key: preprocessLegacyRule(entry.value),
      };
    }
    return value;
  }

  int runLegacy(int iterations) {
    var checksum = 0;
    for (var index = 0; index < iterations; index++) {
      _updateData(index);
      final preprocessed = preprocessLegacyRule(rule);
      final result = runtime.apply(preprocessed, _data);
      checksum = _fold(checksum, result);
    }
    return checksum;
  }

  int runCompiled(
    CompiledJsonLogicEvaluator evaluator,
    JsonLogicExpressionPlan plan,
    int iterations,
  ) {
    var checksum = 0;
    for (var index = 0; index < iterations; index++) {
      _updateData(index);
      final prepared = evaluator.prepare(plan);
      final result = evaluator.evaluatePrepared(plan, _data, prepared);
      checksum = _fold(checksum, result);
    }
    return checksum;
  }

  void _updateData(int index) {
    final player = _global['player'] as Map<String, dynamic>;
    player['x'] = (index % 101).toDouble();
    player['velocity'] = ((index * 3) % 29).toDouble();
    _global['tick'] = index;
    _global['elapsed'] = (index % 181).toDouble();
    _global['mode'] = index % 5 == 0 ? 'idle' : 'run';
    _global['expectedMode'] = index % 7 == 0 ? 'idle' : 'run';
    _global['score'] = (100 + index % 997).toDouble();
    _global['combo'] = (1 + index % 8).toDouble();
    _global['bonus'] = (index % 37).toDouble();
    _global['penalty'] = (index % 13).toDouble();
  }
}

String _stringifyTemplateValue(dynamic value) {
  if (value == null) return '';
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

int _fold(int checksum, dynamic value) {
  final contribution = value is num
      ? (value * 1000).round()
      : value == null
      ? 17
      : value.hashCode;
  return ((checksum * 16777619) ^ contribution) & 0x7fffffff;
}

int _measure(int Function() body, List<int> timings) {
  final stopwatch = Stopwatch()..start();
  final checksum = body();
  stopwatch.stop();
  timings.add(stopwatch.elapsedMicroseconds);
  return checksum;
}

void _verifyChecksums(String label, int legacy, int compiled) {
  if (legacy != compiled) {
    throw StateError(
      '$label checksum mismatch: legacy=$legacy compiled=$compiled',
    );
  }
}
