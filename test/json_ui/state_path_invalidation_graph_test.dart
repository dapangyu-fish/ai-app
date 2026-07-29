import 'package:flutter_application_1/json_ui/execution/state_path_invalidation_graph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'invalidates exact, parent, and child paths without prefix collisions',
    () {
      final graph = StatePathInvalidationGraph();
      final exact = graph.signalFor(
        owner: Object(),
        paths: const <String>{'global.profile.name'},
        anyGlobalWrite: false,
      );
      final parent = graph.signalFor(
        owner: Object(),
        paths: const <String>{'global.profile'},
        anyGlobalWrite: false,
      );
      final siblingPrefix = graph.signalFor(
        owner: Object(),
        paths: const <String>{'global.profiled'},
        anyGlobalWrite: false,
      );

      graph.didWrite('global.profile.name');
      expect(exact.value, 1);
      expect(parent.value, 1);
      expect(siblingPrefix.value, 0);

      graph.didWrite('global.profile');
      expect(exact.value, 2);
      expect(parent.value, 2);
      expect(siblingPrefix.value, 0);
    },
  );

  test('deduplicates a signal which owns several overlapping paths', () {
    final graph = StatePathInvalidationGraph();
    final owner = Object();
    final signal = graph.signalFor(
      owner: owner,
      paths: const <String>{'global.profile', 'global.profile.name'},
      anyGlobalWrite: false,
    );

    graph.didWrite('global.profile.name');
    expect(signal.value, 1);
    expect(
      identical(
        signal,
        graph.signalFor(
          owner: owner,
          paths: const <String>{},
          anyGlobalWrite: true,
        ),
      ),
      isTrue,
    );
  });

  test('supports broad fallback and whole-graph invalidation', () {
    final graph = StatePathInvalidationGraph();
    final precise = graph.signalFor(
      owner: Object(),
      paths: const <String>{'global.a'},
      anyGlobalWrite: false,
    );
    final broad = graph.signalFor(
      owner: Object(),
      paths: const <String>{},
      anyGlobalWrite: true,
    );

    graph.didWrite(r'$.global.b');
    expect(precise.value, 0);
    expect(broad.value, 1);

    graph.invalidateAll();
    expect(precise.value, 1);
    expect(broad.value, 2);
  });
}
