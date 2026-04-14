import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('JSON DSL App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: JsonDslApp()),
    );

    // App 应该显示加载指示器或主界面
    await tester.pump();
    expect(find.byType(JsonDslApp), findsOneWidget);
  });
}
