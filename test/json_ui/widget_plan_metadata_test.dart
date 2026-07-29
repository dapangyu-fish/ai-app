import 'package:flutter_application_1/json_ui/execution/app_execution_plan.dart';
import 'package:flutter_application_1/json_ui/widget_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const jsonLogicOperators = <String>{
    '!',
    '==',
    'and',
    'var',
    'missing',
    'missing_some',
    'method',
    'log',
  };

  AppExecutionPlan compile(Map<String, dynamic> config) {
    return AppExecutionPlan.compile(
      config,
      knownJsonLogicOperators: jsonLogicOperators,
      knownWidgetTypes: JsonWidgetBuilder.registeredWidgetTypes,
      pathScopedWidgetTypes: JsonWidgetBuilder.pathScopedWidgetTypes,
    );
  }

  test('MapValuePlan unions JSONLogic dependencies used by visible', () {
    final visible = <String, dynamic>{
      '==': <dynamic>[
        <String, dynamic>{'var': 'global.enabled'},
        true,
      ],
    };
    final text = <String, dynamic>{
      'type': 'text',
      'value': 'ready',
      'visible': visible,
    };

    final plan = compile(_config(<Map<String, dynamic>>[text]));
    final visiblePlan = plan.valuePlanFor(visible) as MapValuePlan;
    final widgetPlan = plan.widgetPlanFor(text)!;

    expect(visiblePlan.globalDependencies, {'global.enabled'});
    expect(widgetPlan.globalDependencies, contains('global.enabled'));
    expect(widgetPlan.dependenciesAreComplete, isTrue);
  });

  test('two complete text widgets receive identity-owned path scopes', () {
    final score = <String, dynamic>{
      'type': 'text',
      'value': 'Score {{ global.score }}',
    };
    final name = <String, dynamic>{
      'type': 'text',
      'value': 'Name {{ global.name }}',
    };

    final screen = compile(
      _config(<Map<String, dynamic>>[score, name]),
    ).screens['home']!;

    expect(screen.fallbackOnAnyGlobalWrite, isFalse);
    expect(screen.fallbackGlobalDependencies, isEmpty);
    expect(screen.pathScopedWidgets.length, 2);
    expect(screen.pathScopedWidgets[score]!.globalDependencies, {
      'global.score',
    });
    expect(screen.pathScopedWidgets[name]!.globalDependencies, {'global.name'});
    expect(
      screen.pathScopedWidgets[Map<String, dynamic>.from(score)],
      isNull,
      reason: 'equal runtime maps must not alias source-owned widget plans',
    );
  });

  test('unsupported and ref widgets force broad screen fallback', () {
    for (final child in <Map<String, dynamic>>[
      <String, dynamic>{'type': 'button', 'label': '{{ global.label }}'},
      <String, dynamic>{'type': 'ref', 'name': 'remote-card'},
      <String, dynamic>{'type': 'not_registered'},
    ]) {
      final screen = compile(
        _config(<Map<String, dynamic>>[child]),
      ).screens['home']!;

      expect(screen.fallbackOnAnyGlobalWrite, isTrue);
      expect(screen.pathScopedWidgets, isEmpty);
    }
  });

  test(
    'loop and fallback JSONLogic never masquerade as empty dependencies',
    () {
      final loopText = <String, dynamic>{
        'type': 'text',
        'value': '{{ loop.item.label }}',
      };
      final fallbackRuleText = <String, dynamic>{
        'type': 'text',
        'value': 'fallback',
        'visible': <String, dynamic>{
          '!': <String, dynamic>{
            'runtime_operator': <dynamic>[1, 2],
          },
        },
      };

      for (final child in <Map<String, dynamic>>[loopText, fallbackRuleText]) {
        final plan = compile(_config(<Map<String, dynamic>>[child]));
        final widgetPlan = plan.widgetPlanFor(child)!;
        final screen = plan.screens['home']!;

        expect(widgetPlan.dependenciesAreComplete, isFalse);
        expect(screen.fallbackOnAnyGlobalWrite, isTrue);
        expect(screen.pathScopedWidgets, isEmpty);
      }
    },
  );

  test('i18n and computed reads force broad screen fallback', () {
    final i18nText = <String, dynamic>{
      'type': 'text',
      'value': "{{ t('welcome') }}",
    };
    final computedText = <String, dynamic>{
      'type': 'text',
      'value': '{{ global.displayName }}',
    };

    final i18nScreen = compile(
      _config(<Map<String, dynamic>>[i18nText]),
    ).screens['home']!;
    final computedScreen = compile(
      _config(
        <Map<String, dynamic>>[computedText],
        computed: <String, dynamic>{
          'displayName': <String, dynamic>{'var': 'global.name'},
        },
      ),
    ).screens['home']!;

    expect(i18nScreen.fallbackOnAnyGlobalWrite, isTrue);
    expect(i18nScreen.pathScopedWidgets, isEmpty);
    expect(computedScreen.fallbackOnAnyGlobalWrite, isTrue);
    expect(computedScreen.pathScopedWidgets, isEmpty);
  });

  test('hidden-path and side-effect JSONLogic operators stay broad', () {
    for (final operator in <String>[
      'missing',
      'missing_some',
      'method',
      'log',
    ]) {
      final text = <String, dynamic>{
        'type': 'text',
        'value': 'conservative',
        'visible': <String, dynamic>{
          operator: operator == 'missing_some'
              ? <dynamic>[
                  1,
                  <dynamic>['global.a'],
                ]
              : <dynamic>['global.a'],
        },
      };
      final plan = compile(_config(<Map<String, dynamic>>[text]));

      expect(plan.widgetPlanFor(text)!.dependenciesAreComplete, isFalse);
      expect(plan.screens['home']!.fallbackOnAnyGlobalWrite, isTrue);
    }
  });

  test('a dynamic JSONLogic var path stays on broad invalidation', () {
    final text = <String, dynamic>{
      'type': 'text',
      'value': 'dynamic',
      'visible': <String, dynamic>{
        'var': <String, dynamic>{
          'runtime_operator': <dynamic>['global.', 'enabled'],
        },
      },
    };
    final plan = compile(_config(<Map<String, dynamic>>[text]));

    expect(plan.widgetPlanFor(text)!.dependenciesAreComplete, isFalse);
    expect(plan.screens['home']!.fallbackOnAnyGlobalWrite, isTrue);
  });

  test('duplicate screen IDs retain the first rendered screen plan', () {
    final firstText = <String, dynamic>{
      'type': 'text',
      'value': 'First {{ global.score }}',
    };
    final secondText = <String, dynamic>{
      'type': 'text',
      'value': 'Second {{ global.name }}',
    };
    final firstScreen = <String, dynamic>{
      'id': 'home',
      'title': 'First',
      'layout': 'column',
      'children': <dynamic>[firstText],
    };
    final secondScreen = <String, dynamic>{
      'id': 'home',
      'title': 'Second',
      'layout': 'column',
      'children': <dynamic>[secondText],
    };
    final config = _config(const <Map<String, dynamic>>[]);
    (config['ui'] as Map<String, dynamic>)['screens'] = <dynamic>[
      firstScreen,
      secondScreen,
    ];

    final screen = compile(config).screens['home']!;

    expect(screen.source, same(firstScreen));
    expect(screen.pathScopedWidgets[firstText], isNotNull);
    expect(screen.pathScopedWidgets[secondText], isNull);
  });
}

Map<String, dynamic> _config(
  List<Map<String, dynamic>> children, {
  Map<String, dynamic>? computed,
}) {
  return <String, dynamic>{
    'app': <String, dynamic>{'name': 'metadata'},
    'global': <String, dynamic>{
      'variables': <String, dynamic>{
        'enabled': true,
        'score': 1,
        'name': 'Ada',
        'label': 'Tap',
      },
      if (computed != null) 'computed': computed,
    },
    'ui': <String, dynamic>{
      'screens': <dynamic>[
        <String, dynamic>{
          'id': 'home',
          'title': 'Metadata',
          'layout': 'column',
          'children': children,
        },
      ],
    },
  };
}
