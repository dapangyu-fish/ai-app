import 'package:flutter_application_1/json_ui/execution/app_execution_plan.dart';
import 'package:flutter_application_1/json_ui/execution/state_schema.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppExecutionPlan compiler', () {
    test('compiles a new dynamic JSON into immutable plan metadata', () {
      final action = <String, dynamic>{
        'call': '@set',
        'args': <String, dynamic>{
          'var': 'global.score',
          'value': '{{ global.nextScore }}',
        },
      };
      final text = <String, dynamic>{
        'type': 'text',
        'value': 'Score: {{ global.score }}',
        'visible': <String, dynamic>{
          '>': <dynamic>[
            <String, dynamic>{'var': 'global.score'},
            0,
          ],
        },
      };
      final button = <String, dynamic>{
        'type': 'button',
        'label': '{{ global.label }}',
        'onTap': action,
      };
      final config = _config(
        name: 'plan-a',
        variables: <String, dynamic>{
          'score': 1,
          'nextScore': 2,
          'label': 'Increment',
          'profile': <String, dynamic>{'name': 'Ada'},
        },
        children: <Map<String, dynamic>>[text, button],
      );

      final plan = AppExecutionPlan.compile(
        config,
        knownJsonLogicOperators: const <String>{'>', 'var'},
        knownWidgetTypes: const <String>{'text', 'button'},
      );

      expect(plan.abi, AppExecutionPlan.currentAbi);
      expect(plan.hasStableSourceHash, isTrue);
      expect(plan.sourceHash, hasLength(64));
      expect(plan.screens.keys, <String>['home']);
      expect(plan.templateFor('Score: {{ global.score }}'), isNotNull);
      expect(plan.templateFor('{{ global.nextScore }}'), isNotNull);

      final textPlan = plan.widgetPlanFor(text);
      expect(textPlan, isNotNull);
      expect(textPlan!.type, 'text');
      expect(textPlan.visible, isNotNull);
      expect(textPlan.globalDependencies, contains('global.score'));

      final actionPlan = plan.actionPlanFor(action);
      expect(actionPlan, isNotNull);
      expect(actionPlan!.kind, ActionPlanKind.call);
      expect(actionPlan.callTarget, '@set');

      expect(
        plan.stateSchema.slotForPath('global.score')?.initialKind,
        StateValueKind.integer,
      );
      expect(plan.stateSchema.slotForPath('global.profile.name'), isNotNull);
      expect(plan.stats.widgetCount, 2);
      expect(plan.stats.actionCount, 1);
      expect(plan.stats.templateCount, 3);
    });

    test('different JSON content receives a different plan hash', () {
      final first = AppExecutionPlan.compile(
        _config(
          name: 'first',
          variables: <String, dynamic>{'value': 1},
          children: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'value': '{{ global.value }}'},
          ],
        ),
        knownJsonLogicOperators: const <String>{},
        knownWidgetTypes: const <String>{'text'},
      );
      final second = AppExecutionPlan.compile(
        _config(
          name: 'second',
          variables: <String, dynamic>{'value': 2},
          children: <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'value': 'new {{ global.value }}',
            },
          ],
        ),
        knownJsonLogicOperators: const <String>{},
        knownWidgetTypes: const <String>{'text'},
      );

      expect(first.sourceHash, isNot(second.sourceHash));
      expect(first.templateFor('{{ global.value }}'), isNotNull);
      expect(second.templateFor('new {{ global.value }}'), isNotNull);
    });
  });

  group('JsonInterpreter execution-plan integration', () {
    late JsonInterpreter interpreter;

    setUp(() {
      interpreter = JsonInterpreter();
    });

    tearDown(() {
      interpreter.dispose();
    });

    test('evaluates precompiled templates against current mutable state', () {
      interpreter.loadConfig(
        _config(
          name: 'runtime',
          variables: <String, dynamic>{
            'score': 1,
            'items': <dynamic>[1, 2],
            'presentNull': null,
          },
          children: <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'value': 'Score: {{ global.score }}',
            },
          ],
        ),
      );

      final plan = interpreter.executionPlan;
      expect(plan, isNotNull);
      expect(plan!.templateFor('Score: {{ global.score }}'), isNotNull);
      expect(
        interpreter.resolveTemplate('Score: {{ global.score }}'),
        'Score: 1',
      );
      expect(interpreter.resolveExpression('{{ global.items }}'), <dynamic>[
        1,
        2,
      ]);
      expect(interpreter.resolveExpression('{{ global.presentNull }}'), isNull);

      interpreter.setVariable('global.score', 7);
      expect(
        interpreter.resolveTemplate('Score: {{ global.score }}'),
        'Score: 7',
      );

      // A runtime-generated template was not present in the source plan. It
      // still compiles on first use through the bounded dynamic cache.
      expect(
        interpreter.resolveTemplate('Dynamic {{ global.score }}'),
        'Dynamic 7',
      );
    });

    test('new and nested Apps receive isolated plans', () {
      interpreter.loadConfig(
        _config(
          name: 'parent',
          variables: <String, dynamic>{'value': 'parent'},
          children: <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'value': 'Parent {{ global.value }}',
            },
          ],
        ),
      );
      final parentPlan = interpreter.executionPlan;

      interpreter.pushState();
      interpreter.loadConfig(
        _config(
          name: 'child',
          variables: <String, dynamic>{'value': 'child'},
          children: <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'value': 'Child {{ global.value }}',
            },
          ],
        ),
      );
      final childPlan = interpreter.executionPlan;

      expect(childPlan, isNotNull);
      expect(childPlan, isNot(same(parentPlan)));
      expect(childPlan!.sourceHash, isNot(parentPlan!.sourceHash));
      expect(
        interpreter.resolveTemplate('Child {{ global.value }}'),
        'Child child',
      );

      interpreter.popState();
      expect(interpreter.executionPlan, same(parentPlan));
      expect(
        interpreter.resolveTemplate('Parent {{ global.value }}'),
        'Parent parent',
      );
    });
  });
}

Map<String, dynamic> _config({
  required String name,
  required Map<String, dynamic> variables,
  required List<Map<String, dynamic>> children,
}) {
  return <String, dynamic>{
    'dsl': '4.0',
    'meta': <String, dynamic>{'name': name},
    'global': <String, dynamic>{'variables': variables},
    'ui': <String, dynamic>{
      'screens': <dynamic>[
        <String, dynamic>{
          'id': 'home',
          'content': <String, dynamic>{'children': children},
        },
      ],
    },
  };
}
