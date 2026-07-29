import 'package:flutter/material.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_application_1/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('an exact text dependency rebuilds only its planned host', (
    tester,
  ) async {
    final interpreter = JsonInterpreter()
      ..loadConfig(
        _config(
          name: 'exact-a',
          variables: <String, dynamic>{'a': 0, 'b': 0},
          children: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'value': 'A={{ global.a }}'},
            <String, dynamic>{'type': 'text', 'value': 'B={{ global.b }}'},
          ],
        ),
      );

    await _pumpScreen(tester, interpreter);
    final bBefore = tester.widget<Text>(find.text('B=0'));

    interpreter.setVariable('global.a', 1);
    await tester.pump();

    expect(find.text('A=1'), findsOneWidget);
    expect(find.text('B=0'), findsOneWidget);
    expect(tester.widget<Text>(find.text('B=0')), same(bBefore));
  });

  testWidgets(
    'an unsupported widget safely falls back to whole-screen updates',
    (tester) async {
      final interpreter = JsonInterpreter()
        ..loadConfig(
          _config(
            name: 'broad',
            variables: <String, dynamic>{'a': 0},
            children: <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'value': 'A={{ global.a }}'},
              <String, dynamic>{'type': 'button', 'label': 'Static'},
            ],
          ),
        );

      await _pumpScreen(tester, interpreter);
      interpreter.setVariable('global.a', 1);
      await tester.pump();

      expect(find.text('A=1'), findsOneWidget);
    },
  );

  testWidgets('duplicate screen IDs invalidate the first rendered screen', (
    tester,
  ) async {
    final config = _config(
      name: 'duplicate-screen-id',
      variables: <String, dynamic>{'a': 0, 'b': 0},
      children: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'value': 'First={{ global.a }}'},
      ],
    );
    final screens =
        (config['ui'] as Map<String, dynamic>)['screens'] as List<dynamic>;
    screens.add(<String, dynamic>{
      'id': 'home',
      'title': 'Second',
      'layout': 'column',
      'children': <dynamic>[
        <String, dynamic>{'type': 'text', 'value': 'Second={{ global.b }}'},
      ],
    });
    final interpreter = JsonInterpreter()..loadConfig(config);

    await _pumpScreen(tester, interpreter);
    expect(find.text('First=0'), findsOneWidget);
    expect(find.text('Second=0'), findsNothing);

    interpreter.setVariable('global.a', 1);
    await tester.pump();

    expect(find.text('First=1'), findsOneWidget);
    expect(find.text('Second=0'), findsNothing);
  });

  testWidgets('planned widget failures still use the JSON-App error guard', (
    tester,
  ) async {
    final previousErrorBuilder = ErrorWidget.builder;
    try {
      Object? guardedError;
      ErrorWidget.builder = (details) {
        guardedError = details.exception;
        return const Text('Guarded JSON crash');
      };
      final interpreter = JsonInterpreter()
        ..loadConfig(
          _config(
            name: 'planned-error-guard',
            variables: const <String, dynamic>{},
            children: <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'value': 'broken',
                'style': 'not-a-style-map',
              },
            ],
          ),
        );

      await _pumpScreen(tester, interpreter);

      expect(find.text('Guarded JSON crash'), findsOneWidget);
      expect(guardedError, isA<TypeError>());
    } finally {
      ErrorWidget.builder = previousErrorBuilder;
    }
  });

  testWidgets(
    'a newly loaded JSON receives a new plan without rebuilding Flutter',
    (tester) async {
      final first = _config(
        name: 'first-json',
        variables: <String, dynamic>{'label': 'first'},
        children: <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'value': '{{ global.label }}'},
        ],
      );
      final second = _config(
        name: 'second-json',
        variables: <String, dynamic>{'label': 'second'},
        children: <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'value': '{{ global.label }}'},
        ],
      );
      final interpreter = JsonInterpreter()..loadConfig(first);
      final firstPlan = interpreter.executionPlan;
      final firstScope = interpreter.appScopeIdentity;

      await _pumpScreen(tester, interpreter);
      interpreter.loadConfig(second);
      // The embedding controller normally announces a successful load. Reusing
      // the public navigation notifier keeps this test independent of internals.
      interpreter.navigateTo('home');
      await tester.pump();

      expect(interpreter.executionPlan, isNot(same(firstPlan)));
      expect(interpreter.appScopeIdentity, isNot(same(firstScope)));
      expect(find.text('second'), findsOneWidget);
    },
  );

  testWidgets('@apply_app_config publishes a fully initialized new plan', (
    tester,
  ) async {
    final second =
        _config(
            name: 'applied-json',
            variables: <String, dynamic>{
              'label': 'second',
              'initialized': 'pending',
            },
            children: <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'value': '{{ global.label }} {{ global.initialized }}',
              },
            ],
          )
          ..['steps'] = <dynamic>[
            <String, dynamic>{
              'call': '@set',
              'args': <String, dynamic>{
                'var': 'global.initialized',
                'value': 'ready',
              },
            },
          ];
    final action = <String, dynamic>{
      'call': '@apply_app_config',
      'args': <String, dynamic>{'config': '{{ global.nextConfig }}'},
    };
    final first = _config(
      name: 'applying-json',
      variables: <String, dynamic>{'nextConfig': second},
      children: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'value': 'first'},
      ],
    )..['_apply'] = action;
    final interpreter = JsonInterpreter()..loadConfig(first);
    final firstPlan = interpreter.executionPlan;
    final firstScope = interpreter.appScopeIdentity;

    await _pumpScreen(tester, interpreter);
    final context = tester.element(find.byType(JsonScreenView));
    expect(await interpreter.executeActionWithResult(action, context), isTrue);
    await tester.pump();

    expect(interpreter.executionPlan, isNot(same(firstPlan)));
    expect(interpreter.appScopeIdentity, isNot(same(firstScope)));
    expect(find.text('second ready'), findsOneWidget);
  });

  test('a failed new load leaves the current compiled App intact', () {
    final interpreter = JsonInterpreter()
      ..loadConfig(
        _config(
          name: 'atomic-parent',
          variables: <String, dynamic>{'value': 1},
          children: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'value': '{{ global.value }}'},
          ],
        ),
      );
    final parentPlan = interpreter.executionPlan;
    final parentScope = interpreter.appScopeIdentity;
    final parentSignal = interpreter.screenRevision('home');
    final invalid =
        _config(
            name: 'invalid-child',
            variables: <String, dynamic>{'value': 99},
            children: const <Map<String, dynamic>>[],
          )
          ..['compute'] = <String, dynamic>{
            'engine': <String, dynamic>{
              'abi': 3,
              'backend': 'vm',
              'semantics': 'i32-v2',
            },
          };

    expect(() => interpreter.loadConfig(invalid), throwsA(isA<Exception>()));
    expect(interpreter.executionPlan, same(parentPlan));
    expect(interpreter.appScopeIdentity, same(parentScope));
    expect(interpreter.screenRevision('home'), same(parentSignal));
    expect(interpreter.getVariable('global.value'), 1);
  });

  testWidgets('exposing mutable source invalidates plans and stays broad', (
    tester,
  ) async {
    final interpreter = JsonInterpreter()
      ..loadConfig(
        _config(
          name: 'mutable-source',
          variables: <String, dynamic>{'a': 0, 'unrelated': 0},
          children: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'value': 'A={{ global.a }}'},
          ],
        ),
      );
    await _pumpScreen(tester, interpreter);
    final screenSignal = interpreter.screenRevision('home');
    final initialRevision = screenSignal.value;
    final context = tester.element(find.byType(JsonScreenView));

    await interpreter.executeActionWithResult(<String, dynamic>{
      'call': '@get_app_config',
    }, context);
    await tester.pump();
    expect(screenSignal.value, initialRevision + 1);

    interpreter.setVariable('global.unrelated', 1);
    await tester.pump();
    expect(screenSignal.value, initialRevision + 2);
    expect(find.text('A=0'), findsOneWidget);
  });

  test('nested Apps restore the parent plan and invalidation graph', () {
    final parent = _config(
      name: 'parent',
      variables: <String, dynamic>{'title': 'Parent'},
      title: '{{ global.title }}',
      children: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'value': 'parent'},
      ],
    );
    final child = _config(
      name: 'child',
      variables: <String, dynamic>{'title': 'Child'},
      title: '{{ global.title }}',
      children: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'value': 'child'},
      ],
    );
    final interpreter = JsonInterpreter()..loadConfig(parent);
    final parentPlan = interpreter.executionPlan;
    final parentSignal = interpreter.screenRevision('home');
    final parentPresentationRevision = interpreter.presentationRevision;

    interpreter.pushState();
    interpreter.loadConfig(child);
    expect(interpreter.executionPlan, isNot(same(parentPlan)));
    expect(interpreter.screenRevision('home'), isNot(same(parentSignal)));

    interpreter.popState();
    expect(interpreter.executionPlan, same(parentPlan));
    expect(interpreter.screenRevision('home'), same(parentSignal));
    expect(interpreter.presentationRevision, parentPresentationRevision + 1);
    interpreter.setVariable('global.title', 'Restored');
    expect(parentSignal.value, 1);
  });

  testWidgets('nested App pop republishes the restored parent shell', (
    tester,
  ) async {
    final interpreter = JsonInterpreter()
      ..loadConfig(
        _config(
          name: 'parent-shell',
          variables: const <String, dynamic>{},
          children: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'value': 'Parent shell'},
          ],
        ),
      );
    await _pumpScreen(tester, interpreter);

    final navigator = Navigator.of(tester.element(find.byType(JsonScreenView)));
    interpreter.pushState();
    interpreter.loadConfig(
      _config(
        name: 'child-shell',
        variables: const <String, dynamic>{},
        children: <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'value': 'Child shell'},
        ],
      ),
    );
    final routeFuture = navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const JsonScreenView(fileName: 'child.json'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Child shell'), findsOneWidget);
    final childContext = interpreter.globalContext!;

    navigator.pop();
    await tester.pumpAndSettle();
    await routeFuture;
    interpreter.popState();
    await tester.pump();

    expect(find.text('Parent shell'), findsOneWidget);
    expect(childContext.mounted, isFalse);
    expect(interpreter.globalContext, isNot(same(childContext)));
    expect(interpreter.globalContext!.mounted, isTrue);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  JsonInterpreter interpreter,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        interpreterProvider.overrideWith((ref) => interpreter),
      ],
      child: const MaterialApp(
        home: JsonScreenView(fileName: 'widget-plan-test.json'),
      ),
    ),
  );
  await tester.pump();
}

Map<String, dynamic> _config({
  required String name,
  required Map<String, dynamic> variables,
  required List<Map<String, dynamic>> children,
  String title = 'Static',
}) {
  return <String, dynamic>{
    'meta': <String, dynamic>{'name': name},
    'global': <String, dynamic>{'variables': variables},
    'ui': <String, dynamic>{
      'screens': <dynamic>[
        <String, dynamic>{
          'id': 'home',
          'title': title,
          'layout': 'column',
          'children': children,
        },
      ],
    },
  };
}
