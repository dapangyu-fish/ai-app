import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/json_ui/interpreter.dart';
import 'package:myapp/json_ui/widgets/screen_layout.dart';

void main() {
  final demoIndices = <int>[
    4,
    5,
    13,
    16,
    17,
    for (var index = 20; index <= 126; index++) index,
  ];

  for (final index in demoIndices) {
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

  for (final index in [4, 5]) {
    testWidgets(
      'ported JSON demo ${index.toString().padLeft(3, '0')} onLoad generates random items',
      (tester) async {
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
        late BuildContext actionContext;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                actionContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await interpreter.executeAction(
          screen['onLoad'] as Map<String, dynamic>,
          actionContext,
        );
        final items = interpreter.getVariable('global.items') as List<dynamic>;
        expect(items, hasLength(100));
        expect(items.first, isA<Map<String, dynamic>>());
        expect((items.first as Map<String, dynamic>)['index'], 0);
      },
    );
  }

  for (final index in [10, 11]) {
    testWidgets(
      'ported JSON demo ${index.toString().padLeft(3, '0')} refresh repopulates list',
      (tester) async {
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

        late BuildContext actionContext;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                actionContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        final refreshFuture = interpreter.executeAction({
          'call': '@global.refresh',
          'args': <String, dynamic>{},
        }, actionContext);
        await tester.pump(const Duration(seconds: 2));
        await refreshFuture;
        final items = interpreter.getVariable('global.dataList') as List;
        expect(items, hasLength(30));
        expect(items.every((item) => item == 'refresh'), isTrue);
      },
    );
  }

  testWidgets('ported JSON demo 042 dropdown menus handle selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('042');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    await tester.tap(find.text('title1'));
    await tester.pump();
    expect(find.text('距离'), findsOneWidget);

    await tester.tap(find.text('距离'));
    await tester.pump();
    expect(find.text('距离1'), findsOneWidget);

    await tester.tap(find.text('距离1'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(
      interpreter.getVariable('global.menu0SelectedByGroup.距离'),
      contains('距离1'),
    );

    await tester.tap(find.text('title2'));
    await tester.pump();
    expect(find.text('问题1'), findsOneWidget);

    await tester.tap(find.text('问题1'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(
      interpreter.getVariable('global.menu1SelectedByGroup.选择1'),
      contains('问题1'),
    );

    await tester.tap(find.text('title3'));
    await tester.pump();
    await tester.tap(find.text('选择3'));
    await tester.pump();
    expect(interpreter.getVariable('global.menu2SelectedIndex'), '2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 015 hero image opens and closes detail', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('015');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screens =
        (config['ui'] as Map<String, dynamic>)['screens'] as List<dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final screen = screens.whereType<Map<String, dynamic>>().firstWhere(
              (item) => item['id'] == interpreter.currentScreenId,
            );
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(interpreter.currentScreenId, 'home');
    await tester.tapAt(const Offset(195, 422));
    await tester.pump();
    expect(interpreter.currentScreenId, 'detail');
    await tester.tapAt(const Offset(195, 422));
    await tester.pump();
    expect(interpreter.currentScreenId, 'home');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 074 maintains nested route stack', (
    tester,
  ) async {
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('074');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);

    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            actionContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await interpreter.executeAction({
      'call': '@global.openRoute',
      'args': {'index': 2},
    }, actionContext);
    await interpreter.executeAction({
      'call': '@global.openRoute',
      'args': {'index': 5},
    }, actionContext);
    expect(interpreter.getVariable('global.routeStack'), [0, 2, 5]);
    expect(interpreter.getVariable('global.currentRoute'), 5);

    await interpreter.executeAction({
      'call': '@global.popRoute',
      'args': <String, dynamic>{},
    }, actionContext);
    expect(interpreter.getVariable('global.routeStack'), [0, 2]);
    expect(interpreter.getVariable('global.currentRoute'), 2);

    await interpreter.executeAction({
      'call': '@global.popRoute',
      'args': <String, dynamic>{},
    }, actionContext);
    await interpreter.executeAction({
      'call': '@global.popRoute',
      'args': <String, dynamic>{},
    }, actionContext);
    expect(interpreter.getVariable('global.routeStack'), [0]);
    expect(interpreter.getVariable('global.currentRoute'), 0);
  });

  testWidgets('ported JSON demo 033 expands and collapses sticky section', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('033');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(interpreter.getVariable('global.expanded_0'), false);
    expect(find.text('我的 0 头啊'), findsOneWidget);
    expect(find.text('查看更多').first, findsOneWidget);

    await tester.tap(find.text('查看更多').first);
    await tester.pump();
    expect(interpreter.getVariable('global.expanded_0'), true);
    expect(find.text('我的展开的 0 内容 啊').first, findsOneWidget);

    await tester.tap(find.text('收起').first);
    await tester.pump();
    expect(interpreter.getVariable('global.expanded_0'), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 044 footer toggles source state labels', (
    tester,
  ) async {
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('044');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);

    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            actionContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(interpreter.getVariable('global.pinnedLabel'), 'pinned');
    await interpreter.executeAction({
      'call': '@global.togglePinned',
      'args': <String, dynamic>{},
    }, actionContext);
    expect(interpreter.getVariable('global.pinned'), false);
    expect(interpreter.getVariable('global.pinnedLabel'), 'scroll');

    expect(interpreter.getVariable('global.heightLabel'), 'minHeight');
    await interpreter.executeAction({
      'call': '@global.toggleHeight',
      'args': <String, dynamic>{},
    }, actionContext);
    expect(interpreter.getVariable('global.initHeight'), 0);
    expect(interpreter.getVariable('global.heightLabel'), 'non Height');

    expect(interpreter.getVariable('global.autoBackLabel'), 'non autoBack');
    await interpreter.executeAction({
      'call': '@global.toggleAutoBack',
      'args': <String, dynamic>{},
    }, actionContext);
    expect(interpreter.getVariable('global.pullTall'), true);
    expect(interpreter.getVariable('global.autoBackLabel'), 'autoBack');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 047 section more button toggles label', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('047');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(interpreter.getVariable('global.expanded_0'), false);
    expect(find.text('查看更多').first, findsOneWidget);
    await tester.tap(find.text('查看更多').first);
    await tester.pump();
    expect(interpreter.getVariable('global.expanded_0'), true);
    expect(find.text('收起').first, findsOneWidget);
    await tester.tap(find.text('收起').first);
    await tester.pump();
    expect(interpreter.getVariable('global.expanded_0'), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 057 pan updates JSON matrix variables', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('057');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            actionContext = context;
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(interpreter.getVariable('global.tx'), 0);
    expect(interpreter.getVariable('global.ty'), 0);
    await interpreter.executeActionWithEvent(
      {'call': '@global.dragMatrix', 'args': <String, dynamic>{}},
      actionContext,
      const {
        'localX': 0,
        'localY': 0,
        'globalX': 0,
        'globalY': 0,
        'deltaX': 40,
        'deltaY': -20,
        'translationDeltaX': 40,
        'translationDeltaY': -20,
        'scaleDelta': 1.2,
        'rotationDeltaDegrees': 8,
      },
    );
    expect(interpreter.getVariable('global.tx'), greaterThan(0));
    expect(interpreter.getVariable('global.ty'), lessThan(0));
    expect(interpreter.getVariable('global.rotDeg'), greaterThan(0));
    expect(interpreter.getVariable('global.scale'), greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 058 text actions move follower button', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('058');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            actionContext = context;
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final initialTop = interpreter.getVariable('global.buttonTop') as num;
    final initialHeight =
        interpreter.getVariable('global.contentMeasure.height') as num;
    for (var i = 0; i < 5; i++) {
      await interpreter.executeAction({
        'call': '@global.addText',
        'args': <String, dynamic>{},
      }, actionContext);
    }
    await tester.pump();
    await tester.pump();
    expect(interpreter.getVariable('global.content'), contains('动态文本'));
    expect(
      interpreter.getVariable('global.contentMeasure.height'),
      greaterThan(initialHeight),
    );
    expect(
      interpreter.getVariable('global.buttonTop'),
      greaterThan(initialTop),
    );
    for (var i = 0; i < 5; i++) {
      await interpreter.executeAction({
        'call': '@global.removeText',
        'args': <String, dynamic>{},
      }, actionContext);
    }
    await tester.pump();
    await tester.pump();
    expect(interpreter.getVariable('global.content'), '这是可滑动文本区域');
    expect(interpreter.getVariable('global.buttonTop'), initialTop);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 059 opens circular selector bottom sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('059');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            interpreter.globalContext = context;
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
    expect(find.text('17'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final index in [60, 61]) {
    testWidgets(
      'ported JSON demo ${index.toString().padLeft(3, '0')} drag threshold removes cards',
      (tester) async {
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

        late BuildContext actionContext;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                actionContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect(interpreter.getVariable('global.cards'), hasLength(10));
        await interpreter.executeActionWithEvent(
          {
            'call': '@global.dismissByDrag',
            'args': {'idx': 0},
          },
          actionContext,
          const {'offsetX': 40, 'offsetY': 20},
        );
        expect(interpreter.getVariable('global.cards'), hasLength(10));
        await interpreter.executeActionWithEvent(
          {
            'call': '@global.dismissByDrag',
            'args': {'idx': 0},
          },
          actionContext,
          const {'offsetX': 240, 'offsetY': 20},
        );
        expect(interpreter.getVariable('global.cards'), hasLength(9));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('ported JSON demo 065 drag updates JSON formula progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('065');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(interpreter.getVariable('global.progress'), 0);
    final gesture = find.byType(GestureDetector).first;
    await tester.dragFrom(tester.getCenter(gesture), const Offset(80, 0));
    await tester.pump();
    expect(interpreter.getVariable('global.progress'), isA<num>());
    expect(interpreter.getVariable('global.progress'), greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 069 transform gesture updates image matrix', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('069');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            actionContext = context;
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    await interpreter.executeActionWithEvent(
      {'call': '@global.updateTransform', 'args': <String, dynamic>{}},
      actionContext,
      const {
        'translationDeltaX': 24,
        'translationDeltaY': 18,
        'scaleDelta': 1.25,
        'rotationDeltaDegrees': 12,
      },
    );
    expect(interpreter.getVariable('global.tx'), 24);
    expect(interpreter.getVariable('global.ty'), 18);
    expect(interpreter.getVariable('global.scale'), greaterThan(1));
    expect(interpreter.getVariable('global.rotDeg'), greaterThan(0));

    await interpreter.executeAction({
      'call': '@global.resetTransform',
      'args': <String, dynamic>{},
    }, actionContext);
    expect(interpreter.getVariable('global.tx'), 0);
    expect(interpreter.getVariable('global.ty'), 0);
    expect(interpreter.getVariable('global.scale'), 1);
    expect(interpreter.getVariable('global.rotDeg'), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 094 tap starts JSON formula burst', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('094');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(interpreter.getVariable('global.exploded'), false);
    await tester.tap(find.byType(GestureDetector).first);
    await tester.pump();
    expect(interpreter.getVariable('global.exploded'), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 051 tabs switch list data', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('051');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(find.text('Tab 0 Item 0'), findsOneWidget);
    await tester.tap(find.text('Tab1').first);
    await tester.pump();
    expect(interpreter.getVariable('global.activeTab'), 1);
    expect(find.text('Tab 1 Item 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 076 fab cycles animated layout state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('076');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );

    expect(interpreter.getVariable('global.currentIndex'), 0);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(interpreter.getVariable('global.currentIndex'), 1);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(interpreter.getVariable('global.currentIndex'), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 071 cycles animated text examples', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('071');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Rotate'), findsOneWidget);
    await tester.tapAt(const Offset(195, 335));
    await tester.pump();
    expect(interpreter.getVariable('global.tapCount'), 1);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(interpreter.getVariable('global.index'), 1);
    expect(find.text('Fade'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 080 links secondary list scroll offset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('080');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
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
    await tester.pump();

    final primary = interpreter.scrollController('primary');
    final sub = interpreter.scrollController('sub');
    expect(primary, isNotNull);
    expect(sub, isNotNull);
    primary!.jumpTo(900);
    await tester.pump();
    expect(sub!.position.pixels, closeTo(30, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 099 pan gesture emits password path', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('099');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(95, 333));
    await gesture.moveTo(const Offset(195, 333));
    await gesture.moveTo(const Offset(195, 433));
    await gesture.up();
    await tester.pump();

    expect(interpreter.getVariable('global.pwd'), '014');
    expect(find.text('当前密码: 014'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 118 starts from entry page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('118');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screens =
        (config['ui'] as Map<String, dynamic>)['screens'] as List<dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final screen = screens.whereType<Map<String, dynamic>>().firstWhere(
              (item) => item['id'] == interpreter.currentScreenId,
            );
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('CONNECT'), findsNothing);
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(interpreter.currentScreenId, 'particle');
    expect(find.text('CONNECT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 113 toggles taichi mode label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('113');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('当前: 柔和圆'), findsOneWidget);
    await tester.tap(find.text('当前: 柔和圆'));
    await tester.pump();
    expect(interpreter.getVariable('global.sharpMode'), isTrue);
    expect(find.text('当前: 几何S形'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 115 exposes tornado twist slider', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('115');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Twist Intensity (Zoom)'), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await tester.pump();
    expect(interpreter.getVariable('global.twistIntensity'), greaterThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 116 exposes morph controls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('116');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('SPHERE'), findsOneWidget);
    expect(find.text('当前: 随机分布'), findsOneWidget);
    await tester.tapAt(const Offset(342, 422));
    await tester.pump();
    expect(interpreter.getVariable('global.shapeIndex'), 1);
    expect(find.text('CUBE'), findsOneWidget);
    await tester.tap(find.text('当前: 随机分布'));
    await tester.pump();
    expect(interpreter.getVariable('global.structured'), isTrue);
    expect(find.text('当前: 有序网格'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 119 toggles disco sphere mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('119');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('模式: 纸张铺开'), findsOneWidget);
    await tester.tap(find.text('模式: 纸张铺开'));
    await tester.pump();
    expect(interpreter.getVariable('global.paperMode'), isFalse);
    expect(find.text('模式: 随机破碎'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 120 toggles spatial grid theme', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('120');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(interpreter.getVariable('global.cyberMode'), isFalse);
    await tester.tapAt(const Offset(338, 792));
    await tester.pump();
    expect(interpreter.getVariable('global.cyberMode'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 121 matches web fallback', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('121');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
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
    await tester.pump();

    expect(find.text('当前效果不支持 Web ，请在 App 查看'), findsOneWidget);
    expect(find.text('Shock Wave Chat'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 122 toggles particle mode label', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('122');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('MODE: NORMAL'), findsOneWidget);
    await tester.tap(find.text('MODE: NORMAL'));
    await tester.pump();
    expect(interpreter.getVariable('global.cyberpunk'), isTrue);
    expect(find.text('MODE: CYBER'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 104 cycles attractor modes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('104');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('HALVORSEN'), findsOneWidget);
    expect(find.text('Switch: HALVORSEN'), findsOneWidget);
    await tester.tap(find.text('Switch: HALVORSEN'));
    await tester.pump();
    expect(interpreter.getVariable('global.typeIndex'), 1);
    expect(interpreter.getVariable('global.label'), 'LORENZ');
    expect(find.text('LORENZ'), findsOneWidget);
    expect(find.text('Switch: LORENZ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 107 drag updates neon slider progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('107');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(interpreter.getVariable('global.progress'), 0.34);
    expect(find.text('34'), findsOneWidget);
    await tester.tapAt(const Offset(300, 422));
    await tester.pump();
    expect(interpreter.getVariable('global.progress'), greaterThan(0.7));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 125 exposes jaw controls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('125');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('运动模式'), findsOneWidget);
    expect(find.text('当前: 用力咬紧 · #0'), findsOneWidget);
    await tester.tap(find.text('连续咀嚼'));
    await tester.pump();
    expect(interpreter.getVariable('global.modeIndex'), 1);
    expect(find.text('当前: 连续咀嚼 · #0'), findsOneWidget);

    await tester.drag(find.byType(Slider).first, const Offset(-120, 0));
    await tester.pump();
    expect(interpreter.getVariable('global.uiSize'), lessThan(350));

    await tester.tap(find.text('触发动画'));
    await tester.pump();
    expect(interpreter.getVariable('global.triggerCount'), 1);
    expect(find.text('当前: 连续咀嚼 · #1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 100 keeps left and right lists linked', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('100');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    final screen =
        (config['ui'] as Map<String, dynamic>)['screens'][0]
            as Map<String, dynamic>;

    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: interpreter,
          builder: (context, _) {
            actionContext = context;
            final children = (screen['children'] as List)
                .whereType<Map<String, dynamic>>()
                .map((child) => interpreter.buildWidget(context, child))
                .toList();
            return Scaffold(body: buildScreenLayout(screen, children));
          },
        ),
      ),
    );
    await tester.pump();

    final selectFuture = interpreter.executeAction({
      'call': '@global.select',
      'args': {'idx': 4},
    }, actionContext);
    await tester.pumpAndSettle();
    await selectFuture;
    expect(interpreter.getVariable('global.selected'), 4);
    expect(
      interpreter.scrollController('rightList')!.position.pixels,
      closeTo(700, 1),
    );

    interpreter.scrollController('rightList')!.jumpTo(1100);
    await tester.pump();
    expect(interpreter.getVariable('global.selected'), 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ported JSON demo 072 app bar actions append source counts', (
    tester,
  ) async {
    final path = Directory('templates')
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) {
          return file.uri.pathSegments.last.startsWith('072');
        });
    final config = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final interpreter = JsonInterpreter()..loadConfig(config);
    Object? actionError;
    StackTrace? actionStack;
    JsonInterpreter.onActionCrash = (error, stack, fileName) {
      actionError = error;
      actionStack = stack;
    };
    addTearDown(() {
      JsonInterpreter.onActionCrash = null;
    });

    late BuildContext actionContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            actionContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await interpreter.executeAction({
      'call': '@global.addOld',
      'args': <String, dynamic>{},
    }, actionContext);
    if (actionError != null) {
      throw actionError!.toString();
    }
    await interpreter.executeAction({
      'call': '@global.addNew',
      'args': <String, dynamic>{},
    }, actionContext);
    if (actionError != null) {
      throw '$actionError\n$actionStack';
    }

    expect(interpreter.getVariable('global.oldData'), hasLength(23));
    expect(interpreter.getVariable('global.newData'), hasLength(20));
    expect(
      interpreter.getVariable('global.oldData.3.txt'),
      startsWith('Old 3'),
    );
    expect(
      interpreter.getVariable('global.newData.0.txt'),
      startsWith('New 0'),
    );
    expect(tester.takeException(), isNull);
  });
}
