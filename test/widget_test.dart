import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('JSON DSL App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: JsonDslApp()));

    // App 应该显示加载指示器或主界面
    await tester.pump();
    expect(find.byType(JsonDslApp), findsOneWidget);
  });

  testWidgets('screen onLoad action runs after first frame', (
    WidgetTester tester,
  ) async {
    final interpreter = JsonInterpreter()
      ..loadConfig({
        'meta': {'name': 'onload-test'},
        'global': {
          'variables': {'ready': false},
        },
        'ui': {
          'screens': [
            {
              'id': 'home',
              'title': 'OnLoad',
              'layout': 'column',
              'onLoad': {
                'call': '@set',
                'args': {'var': 'global.ready', 'value': true},
              },
              'children': [
                {'type': 'text', 'value': '{{ global.ready }}'},
              ],
            },
          ],
        },
      });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [interpreterProvider.overrideWith((ref) => interpreter)],
        child: const MaterialApp(home: JsonScreenView(fileName: 'test.json')),
      ),
    );
    await tester.pump();

    expect(interpreter.getVariable('global.ready'), isTrue);
  });
}
