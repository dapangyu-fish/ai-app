import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/designer/environment_page.dart';
import 'package:myapp/designer/hidden_env_entry.dart';

void main() {
  testWidgets('hidden environment entry replaces toast without layout errors', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: HiddenEnvEntry(child: Text('Logo'))),
        ),
      ),
    );

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('Logo'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull);
    }

    expect(find.text('再点 1 下解锁服务环境'), findsOneWidget);
    expect(find.text('再点 2 下解锁服务环境'), findsNothing);
    expect(find.text('再点 3 下解锁服务环境'), findsNothing);

    await tester.tap(find.text('Logo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(EnvironmentPage), findsOneWidget);
  });
}
