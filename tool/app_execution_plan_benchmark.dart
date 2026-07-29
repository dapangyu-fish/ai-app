// ignore_for_file: avoid_print

import 'dart:math' as math;

import 'package:flutter_application_1/json_ui/execution/app_execution_plan.dart';
import 'package:flutter_application_1/json_ui/execution/template_plan.dart';
import 'package:flutter_application_1/json_ui/path_plan.dart';

void main(List<String> arguments) {
  final batches = arguments.isEmpty ? 500000 : int.parse(arguments.first);
  if (batches <= 0) {
    throw ArgumentError.value(batches, 'batches', 'must be positive');
  }

  final state = _state();
  final config = _config(state);
  final compileWatch = Stopwatch()..start();
  final appPlan = AppExecutionPlan.compile(
    config,
    knownJsonLogicOperators: const <String>{'var', '>', '+'},
    knownWidgetTypes: const <String>{'text'},
  );
  compileWatch.stop();
  final plans = <TemplatePlan>[
    for (final source in _templates) appPlan.templateFor(source)!,
  ];
  final legacyPaths = PathPlanCache(capacity: 32);

  final warmupBatches = math.min(batches, 10000);
  for (var round = 0; round < 3; round++) {
    final legacy = _runLegacy(state, legacyPaths, warmupBatches);
    final planned = _runPlanned(state, plans, warmupBatches);
    if (legacy != planned) {
      throw StateError('warm-up mismatch: legacy=$legacy planned=$planned');
    }
  }

  final legacySamples = <double>[];
  final plannedSamples = <double>[];
  var checksum = 0;
  for (var sample = 0; sample < 5; sample++) {
    final legacyFirst = sample.isEven;
    final first = _sample(
      () => legacyFirst
          ? _runLegacy(state, legacyPaths, batches)
          : _runPlanned(state, plans, batches),
      batches * _templates.length,
      legacyFirst ? legacySamples : plannedSamples,
    );
    final second = _sample(
      () => legacyFirst
          ? _runPlanned(state, plans, batches)
          : _runLegacy(state, legacyPaths, batches),
      batches * _templates.length,
      legacyFirst ? plannedSamples : legacySamples,
    );
    if (first != second) {
      throw StateError('sample $sample mismatch: $first != $second');
    }
    checksum = first;
  }

  legacySamples.sort();
  plannedSamples.sort();
  final legacyMedian = legacySamples[legacySamples.length ~/ 2];
  final plannedMedian = plannedSamples[plannedSamples.length ~/ 2];

  print('AppExecutionPlan template AOT benchmark');
  print('batches: $batches');
  print('templates/sample: ${batches * _templates.length}');
  print('load-time plan compile: ${compileWatch.elapsedMicroseconds} us');
  print(
    'plan stats: templates=${appPlan.stats.templateCount}, '
    'values=${appPlan.stats.valuePlanCount}, '
    'widgets=${appPlan.stats.widgetCount}, '
    'slots=${appPlan.stats.stateSlotCount}',
  );
  print(
    'legacy regex + cached path: ${legacyMedian.toStringAsFixed(0)} templates/s',
  );
  print(
    'precompiled TemplatePlan: ${plannedMedian.toStringAsFixed(0)} templates/s',
  );
  print('speedup: ${(plannedMedian / legacyMedian).toStringAsFixed(3)}x');
  print('checksum: $checksum');
}

const List<String> _templates = <String>[
  'Score {{ global.score }} / {{ global.best }}',
  '{{ global.player.name }}: {{ global.player.level }}',
  'HP {{ global.player.hp }}/{{ global.player.maxHp }}',
  'Tile {{ global.world.x }},{{ global.world.y }}',
  'Coins {{ global.inventory.coins }}',
  'State {{ global.mode }} #{{ global.frame }}',
  '{{ global.player.name }}',
  'static/{{ global.asset }}/{{ global.locale }}.png',
];

Map<String, dynamic> _state() {
  return <String, dynamic>{
    'score': 123,
    'best': 456,
    'player': <String, dynamic>{
      'name': 'Mario',
      'level': 8,
      'hp': 3,
      'maxHp': 5,
    },
    'world': <String, dynamic>{'x': 4, 'y': 2},
    'inventory': <String, dynamic>{'coins': 77},
    'mode': 'running',
    'frame': 999,
    'asset': 'hero',
    'locale': 'zh',
  };
}

Map<String, dynamic> _config(Map<String, dynamic> state) {
  return <String, dynamic>{
    'dsl': '4.0',
    'global': <String, dynamic>{'variables': state},
    'ui': <String, dynamic>{
      'screens': <dynamic>[
        <String, dynamic>{
          'id': 'home',
          'content': <String, dynamic>{
            'children': <dynamic>[
              for (final template in _templates)
                <String, dynamic>{'type': 'text', 'value': template},
            ],
          },
        },
      ],
    },
  };
}

int _runLegacy(Map<String, dynamic> state, PathPlanCache paths, int batches) {
  var checksum = 0;
  for (var batch = 0; batch < batches; batch++) {
    for (final template in _templates) {
      final resolved = template.replaceAllMapped(TemplatePlan.templatePattern, (
        match,
      ) {
        var path = match.group(1)!.trim();
        if (TemplatePlan.i18nCallPattern.hasMatch(path)) return path;
        if (path.startsWith(r'$.')) path = path.substring(2);
        if (path.startsWith('global.')) path = path.substring(7);
        final lookup = paths.lookup(state, path);
        return _stringify(lookup.found ? lookup.value : null);
      });
      checksum = _fold(checksum, resolved);
    }
  }
  return checksum;
}

int _runPlanned(
  Map<String, dynamic> state,
  List<TemplatePlan> plans,
  int batches,
) {
  var checksum = 0;
  for (var batch = 0; batch < batches; batch++) {
    for (final plan in plans) {
      final output = StringBuffer();
      for (final part in plan.parts) {
        if (part is TemplateLiteralPart) {
          output.write(part.value);
        } else if (part is TemplateBindingPart) {
          final lookup = part.variable!.pathPlan.lookup(state);
          output.write(_stringify(lookup.found ? lookup.value : null));
        }
      }
      checksum = _fold(checksum, output.toString());
    }
  }
  return checksum;
}

String _stringify(dynamic value) {
  if (value == null) return '';
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

int _fold(int checksum, String value) {
  return ((checksum * 16777619) ^ value.hashCode) & 0x7fffffff;
}

int _sample(int Function() body, int operations, List<double> samples) {
  final watch = Stopwatch()..start();
  final checksum = body();
  watch.stop();
  final seconds = watch.elapsedTicks / watch.frequency;
  samples.add(operations / seconds);
  return checksum;
}
