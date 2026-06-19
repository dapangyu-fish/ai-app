import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/json_ui/interpreter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('list item actions still capture outer loop values', (
    tester,
  ) async {
    final interpreter = JsonInterpreter()
      ..loadConfig({
        'global': {
          'variables': {'items': <dynamic>[]},
        },
      });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => interpreter.buildWidgetInLoopContext(
              context: context,
              loopItem: 'outer',
              loopIndex: 0,
              json: {
                'type': 'button',
                'label': 'Run',
                'action': {
                  'type': 'call',
                  'call': '@list_add',
                  'args': {'var': 'global.items', 'item': '{{ loop.item }}'},
                },
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pump();

    expect(interpreter.getVariable('global.items'), ['outer']);
  });

  testWidgets('item action keeps inner @for_each body lazy', (tester) async {
    final interpreter = JsonInterpreter()
      ..loadConfig({
        'global': {
          'variables': {'items': <dynamic>[]},
        },
      });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => interpreter.buildWidgetInLoopContext(
              context: context,
              loopItem: 'outer',
              loopIndex: 0,
              json: {
                'type': 'button',
                'label': 'Run',
                'action': {
                  'type': 'call',
                  'call': '@for_each',
                  'args': {
                    'source': ['a', 'b'],
                    'body': [
                      {
                        'type': 'call',
                        'call': '@list_add',
                        'args': {
                          'var': 'global.items',
                          'item': '{{ loop.item }}',
                        },
                      },
                    ],
                  },
                },
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Run'));
    await tester.pump();

    expect(interpreter.getVariable('global.items'), ['a', 'b']);
  });
}
