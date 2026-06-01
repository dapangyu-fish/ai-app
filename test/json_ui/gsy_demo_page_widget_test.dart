import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_application_1/json_ui/widgets/gsy_demo_page_widget.dart';

void main() {
  final demos = List.generate(
    30,
    (index) => (index + 23).toString().padLeft(3, '0'),
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  for (final demo in demos) {
    testWidgets('GSY demo $demo builds first frame', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final interpreter = JsonInterpreter()
        ..loadConfig({
          'appid': 'gsy-demo-widget-test',
          'meta': {'name': 'gsy-demo-widget-test'},
          'global': {
            'variables': <String, dynamic>{},
            'functions': <String, dynamic>{},
          },
          'ui': {
            'screens': [
              {'id': 'home'},
            ],
          },
        });
      final builder = JsonGsyDemoPageWidget();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return builder.build(context, {
                'type': 'gsy_demo_page',
                'demo': demo,
              }, interpreter);
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
