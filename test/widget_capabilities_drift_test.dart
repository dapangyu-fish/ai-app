// Drift guard: the backend lint (backend/validate_json_app.py) must know exactly
// which widget types / icons / custom jsonlogic operators the REAL framework
// supports. Instead of letting the Python lint re-encode that knowledge and
// silently drift, this test imports the real registries and pins them into a
// committed manifest (backend/generated/widget_capabilities.json) that the lint
// consumes. If the framework gains/loses a capability and the manifest is not
// regenerated, this test goes RED — drift becomes a failing test, not a silent
// divergence.
//
//   Regenerate:  UPDATE_CAPABILITIES=1 flutter test test/widget_capabilities_drift_test.dart
//   Verify:      flutter test test/widget_capabilities_drift_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/json_ui/widget_builder.dart';
import 'package:myapp/json_ui/widgets/icon_registry.dart';

const kManifestPath = 'backend/generated/widget_capabilities.json';
const kRegen =
    'UPDATE_CAPABILITIES=1 flutter test test/widget_capabilities_drift_test.dart';

/// Custom jsonlogic operators are registered via `jl.add('name', ...)` in the
/// interpreter (the package ships the standard ops separately). These are the
/// drift-prone ones, so the manifest captures exactly the registered names.
Set<String> _customJsonLogicOps() {
  final src = File('lib/json_ui/interpreter.dart').readAsStringSync();
  return RegExp(r"jl\.add\('([^']+)'")
      .allMatches(src)
      .map((m) => m.group(1)!)
      .toSet();
}

Map<String, dynamic> _computeCapabilities() {
  List<String> sorted(Iterable<String> s) => s.toList()..sort();
  return {
    'note': 'AUTO-GENERATED from the real Flutter registries by '
        'test/widget_capabilities_drift_test.dart. Do not hand-edit. '
        'Regenerate with: $kRegen',
    'widget_types': sorted(JsonWidgetBuilder.registeredWidgetTypes),
    'icons': sorted(IconRegistry.registeredNames),
    'jsonlogic_custom_ops': sorted(_customJsonLogicOps()),
  };
}

void main() {
  test('widget_capabilities.json == the real framework registries', () {
    final computed = _computeCapabilities();
    final encoded = const JsonEncoder.withIndent('  ').convert(computed);
    final file = File(kManifestPath);

    if (Platform.environment['UPDATE_CAPABILITIES'] == '1') {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$encoded\n');
      // ignore: avoid_print
      print('REGENERATED $kManifestPath '
          '(${(computed['widget_types'] as List).length} types, '
          '${(computed['icons'] as List).length} icons, '
          '${(computed['jsonlogic_custom_ops'] as List).length} ops)');
      return;
    }

    expect(file.existsSync(), isTrue,
        reason: 'missing $kManifestPath — generate it with: $kRegen');

    final committed = json.decode(file.readAsStringSync()) as Map;
    for (final key in ['widget_types', 'icons', 'jsonlogic_custom_ops']) {
      final got = (committed[key] as List).cast<String>().toSet();
      final want = (computed[key] as List).cast<String>().toSet();
      expect(got, want,
          reason: 'DRIFT in "$key": the framework changed but $kManifestPath '
              'was not regenerated.\n'
              '  missing_from_manifest=${want.difference(got).toList()..sort()}\n'
              '  stale_in_manifest=${got.difference(want).toList()..sort()}\n'
              '  fix: $kRegen');
    }
  });
}
