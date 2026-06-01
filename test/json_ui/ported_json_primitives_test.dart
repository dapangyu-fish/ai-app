import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_application_1/json_ui/widgets/screen_layout.dart';

void main() {
  for (var index = 20; index <= 82; index++) {
    testWidgets('ported JSON demo ${index.toString().padLeft(3, '0')} builds', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final path = Directory('templates')
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((file) {
            return file.uri.pathSegments.last.startsWith(
              index.toString().padLeft(3, '0'),
            );
          });
      final config =
          jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
      final interpreter = JsonInterpreter()..loadConfig(config);
      final screen =
          (config['ui'] as Map<String, dynamic>)['screens'][0]
              as Map<String, dynamic>;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final children = (screen['children'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map((child) => interpreter.buildWidget(context, child))
                  .toList();
              return Scaffold(body: buildScreenLayout(screen, children));
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  }
}
