// ignore_for_file: avoid_print

import 'dart:math' as math;

import 'package:flutter_application_1/json_ui/path_plan.dart';

/// A pure-Dart AOT benchmark for the JSON App dot-path hot path.
///
/// Run with:
///   dart compile exe tool/json_app_plan_benchmark.dart \
///     -o /tmp/json_app_plan_bench
///   /tmp/json_app_plan_bench
void main(List<String> arguments) {
  final batches = arguments.isEmpty ? 1000000 : int.parse(arguments.first);
  if (batches <= 0) {
    throw ArgumentError.value(batches, 'batches', 'must be positive');
  }

  final root = _benchmarkRoot();
  final cache = PathPlanCache(capacity: 32);
  for (final path in _paths) {
    cache.lookup(root, path);
  }

  final warmupBatches = math.min(batches, 10000);
  for (var round = 0; round < 3; round++) {
    final legacy = _runLegacy(root, warmupBatches);
    final planned = _runPlanned(cache, root, warmupBatches);
    if (legacy != planned) {
      throw StateError('warm-up mismatch: legacy=$legacy, planned=$planned');
    }
  }

  final legacySamples = <double>[];
  final plannedSamples = <double>[];
  var legacyChecksum = 0;
  var plannedChecksum = 0;
  for (var sample = 0; sample < 5; sample++) {
    // Alternate order to reduce systematic thermal/frequency bias.
    if (sample.isEven) {
      legacyChecksum = _sample(
        () => _runLegacy(root, batches),
        batches * _paths.length,
        legacySamples,
      );
      plannedChecksum = _sample(
        () => _runPlanned(cache, root, batches),
        batches * _paths.length,
        plannedSamples,
      );
    } else {
      plannedChecksum = _sample(
        () => _runPlanned(cache, root, batches),
        batches * _paths.length,
        plannedSamples,
      );
      legacyChecksum = _sample(
        () => _runLegacy(root, batches),
        batches * _paths.length,
        legacySamples,
      );
    }
    if (legacyChecksum != plannedChecksum) {
      throw StateError(
        'sample $sample mismatch: '
        'legacy=$legacyChecksum, planned=$plannedChecksum',
      );
    }
  }

  legacySamples.sort();
  plannedSamples.sort();
  final legacyMedian = legacySamples[legacySamples.length ~/ 2];
  final plannedMedian = plannedSamples[plannedSamples.length ~/ 2];
  final lookups = batches * _paths.length;

  print('JSON App PathPlan AOT benchmark');
  print('batches: $batches');
  print('lookups/sample: $lookups');
  print(
    'workload: map/list/numeric-map/null/early-miss/mid-miss/'
    'bounds/scalar',
  );
  print('cached plans: ${cache.cachedPlanCount}/${cache.capacity}');
  print(
    'legacy split + has/get median: ${legacyMedian.toStringAsFixed(0)} '
    'lookups/s (${(1000000000 / legacyMedian).toStringAsFixed(1)} ns/lookup)',
  );
  print(
    'planned single lookup median: ${plannedMedian.toStringAsFixed(0)} '
    'lookups/s (${(1000000000 / plannedMedian).toStringAsFixed(1)} ns/lookup)',
  );
  print('speedup: ${(plannedMedian / legacyMedian).toStringAsFixed(3)}x');
  print('checksum: $plannedChecksum');
}

const List<String> _paths = <String>[
  'user.profile.stats.score',
  'levels.1.tiles.2.value',
  'numericMap.0.value',
  'presentNull',
  'missing',
  'user.profile.absent.value',
  'levels.9.tiles.0.value',
  'scalar.child',
];

Map<String, dynamic> _benchmarkRoot() {
  return <String, dynamic>{
    'user': <String, dynamic>{
      'profile': <String, dynamic>{
        'stats': <String, dynamic>{'score': 123},
      },
    },
    'levels': <dynamic>[
      <String, dynamic>{
        'tiles': <dynamic>[
          <String, dynamic>{'value': 10},
        ],
      },
      <String, dynamic>{
        'tiles': <dynamic>[
          <String, dynamic>{'value': 20},
          <String, dynamic>{'value': 21},
          <String, dynamic>{'value': 22},
        ],
      },
    ],
    'numericMap': <String, dynamic>{
      '0': <String, dynamic>{'value': 77},
    },
    'presentNull': null,
    'scalar': 9,
  };
}

int _runLegacy(Map<String, dynamic> root, int batches) {
  var checksum = 0;
  for (var batch = 0; batch < batches; batch++) {
    checksum = _fold(checksum, _legacyLookup(root, _paths[0]));
    checksum = _fold(checksum, _legacyLookup(root, _paths[1]));
    checksum = _fold(checksum, _legacyLookup(root, _paths[2]));
    checksum = _fold(checksum, _legacyLookup(root, _paths[3]));
    checksum = _fold(checksum, _legacyLookup(root, _paths[4]));
    checksum = _fold(checksum, _legacyLookup(root, _paths[5]));
    checksum = _fold(checksum, _legacyLookup(root, _paths[6]));
    checksum = _fold(checksum, _legacyLookup(root, _paths[7]));
  }
  return checksum;
}

int _runPlanned(PathPlanCache cache, Map<String, dynamic> root, int batches) {
  var checksum = 0;
  for (var batch = 0; batch < batches; batch++) {
    checksum = _fold(checksum, cache.lookup(root, _paths[0]));
    checksum = _fold(checksum, cache.lookup(root, _paths[1]));
    checksum = _fold(checksum, cache.lookup(root, _paths[2]));
    checksum = _fold(checksum, cache.lookup(root, _paths[3]));
    checksum = _fold(checksum, cache.lookup(root, _paths[4]));
    checksum = _fold(checksum, cache.lookup(root, _paths[5]));
    checksum = _fold(checksum, cache.lookup(root, _paths[6]));
    checksum = _fold(checksum, cache.lookup(root, _paths[7]));
  }
  return checksum;
}

PathLookupResult _legacyLookup(Map<String, dynamic> root, String dotPath) {
  if (!_legacyHasNestedKey(root, dotPath)) {
    return PathLookupResult.missing;
  }
  return PathLookupResult.found(_legacyGetNestedValue(root, dotPath));
}

dynamic _legacyGetNestedValue(Map<String, dynamic> root, String dotPath) {
  final keys = dotPath.split('.');
  dynamic current = root;
  for (final key in keys) {
    if (current is Map<String, dynamic>) {
      if (!current.containsKey(key)) return null;
      current = current[key];
    } else if (current is List) {
      final index = int.tryParse(key);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
  }
  return current;
}

bool _legacyHasNestedKey(Map<String, dynamic> root, String dotPath) {
  final keys = dotPath.split('.');
  dynamic current = root;
  for (final key in keys) {
    if (current is Map<String, dynamic>) {
      if (!current.containsKey(key)) return false;
      current = current[key];
    } else if (current is List) {
      final index = int.tryParse(key);
      if (index == null || index < 0 || index >= current.length) return false;
      current = current[index];
    } else {
      return false;
    }
  }
  return true;
}

int _fold(int checksum, PathLookupResult result) {
  final dynamic value = result.value;
  final contribution = !result.found
      ? 17
      : value == null
      ? 31
      : value is int
      ? value
      : value.hashCode;
  return ((checksum * 16777619) ^ contribution) & 0x7fffffff;
}

int _sample(int Function() body, int operations, List<double> samples) {
  final stopwatch = Stopwatch()..start();
  final checksum = body();
  stopwatch.stop();
  final seconds = stopwatch.elapsedTicks / stopwatch.frequency;
  samples.add(operations / seconds);
  return checksum;
}
