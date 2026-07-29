import 'package:flutter_application_1/games/flame_game_engine.dart';
import 'package:flutter_application_1/json_ui/asset_manager.dart';
import 'package:flutter_test/flutter_test.dart';

JsonAppAssetManager _assetManager() {
  return JsonAppAssetManager(
    appId: 'game-logic-compiled-expression-test',
    appName: 'game-logic-compiled-expression-test',
    appVersion: '0.0.0',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only spec-owned roots compile and reuse their identity plan', () {
    final ownedRule = <String, dynamic>{
      '+': [
        {'var': 'vars.left'},
        {'var': 'vars.right'},
      ],
    };
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': {'kind': 'free', 'width': 100, 'height': 100, 'bg': '#000000'},
        'vars': {'left': 2, 'right': 3},
        '_test_rules': [ownedRule],
      },
      assetManager: _assetManager(),
    );
    game.resetGame();

    expect(
      game.logic.compiledExpressionPlanCount,
      3,
      reason:
          'the owned root and both nested var expressions compile before '
          'their first frame use',
    );
    expect(game.logic.resolveExpression(ownedRule), 5.0);
    expect(game.logic.resolveExpression(ownedRule), 5.0);
    expect(game.logic.compiledExpressionPlanCount, 3);
    expect(game.logic.compiledExpressionEvaluationCount, 2);
    expect(
      game.logic.entityScopeSnapshotCount,
      0,
      reason: 'a vars-only static rule does not need an entities snapshot',
    );

    final dynamicCopy = Map<String, dynamic>.from(ownedRule);
    expect(game.logic.resolveExpression(dynamicCopy), 5.0);
    expect(game.logic.compiledExpressionPlanCount, 3);
    expect(game.logic.legacyExpressionEvaluationCount, 1);
    expect(game.logic.entityScopeSnapshotCount, 1);
  });

  test('compiled Game templates preserve exact values and dynamic paths', () {
    final exactValueRule = <String, dynamic>{
      '===': ['{{ vars.number }}', 7],
    };
    final dynamicPathRule = <String, dynamic>{
      'var': 'vars.targets.{{ vars.key }}',
    };
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': {'kind': 'free', 'width': 100, 'height': 100, 'bg': '#000000'},
        'vars': {
          'number': 7,
          'key': 'chosen',
          'targets': {
            'chosen': [9, 8],
          },
        },
        '_test_rules': [exactValueRule, dynamicPathRule],
      },
      assetManager: _assetManager(),
    );
    game.resetGame();

    expect(game.logic.resolveExpression(exactValueRule), isTrue);
    expect(game.logic.resolveExpression(dynamicPathRule), <dynamic>[9, 8]);
    expect(game.logic.compiledExpressionPlanCount, 2);
  });

  test('any inline action forces the entire owned root through legacy', () {
    final eagerInlineActionRule = <String, dynamic>{
      'or': [
        true,
        {
          'call': '@set',
          'args': {'var': 'vars.side_effect', 'value': 1},
        },
      ],
    };
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': {'kind': 'free', 'width': 100, 'height': 100, 'bg': '#000000'},
        'vars': {'side_effect': 0},
        '_test_rules': [eagerInlineActionRule],
      },
      assetManager: _assetManager(),
    );
    game.resetGame();

    expect(game.logic.resolveExpression(eagerInlineActionRule), isTrue);
    expect(
      game.vars['side_effect'],
      1,
      reason:
          'legacy preprocessing eagerly executes inline actions even in a '
          'short-circuited branch',
    );
    expect(game.logic.compiledExpressionPlanCount, 0);
    expect(game.logic.compiledExpressionEvaluationCount, 0);
    expect(game.logic.legacyExpressionEvaluationCount, 1);
  });

  test('entity and whole-data reads retain a complete data scope', () {
    final entityRule = <String, dynamic>{'var': 'entities.hero.x'};
    final wholeDataRule = <String, dynamic>{'var': ''};
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': {'kind': 'free', 'width': 100, 'height': 100, 'bg': '#000000'},
        'entities': {
          'hero': {
            'kind': 'pixel',
            'init': [12, 34],
            'size': [8, 8],
            'render': {'shape': 'rect', 'color': '#FF0000'},
          },
        },
        '_test_rules': [entityRule, wholeDataRule],
      },
      assetManager: _assetManager(),
    );
    game.resetGame();

    expect(game.logic.resolveExpression(entityRule), 0.0);
    final wholeData = game.logic.resolveExpression(wholeDataRule);
    expect(wholeData, isA<Map<String, dynamic>>());
    expect(
      (wholeData as Map<String, dynamic>)['entities'],
      isA<Map<String, dynamic>>(),
    );
    expect(game.logic.entityScopeSnapshotCount, 2);
  });

  test('compiled literal containers are fresh on every evaluation', () {
    final rule = <String, dynamic>{
      'if': [
        true,
        [
          1,
          {'label': 'fresh'},
        ],
        <dynamic>[],
      ],
    };
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': {'kind': 'free', 'width': 100, 'height': 100, 'bg': '#000000'},
        '_test_rules': [rule],
      },
      assetManager: _assetManager(),
    );
    game.resetGame();

    final first = game.logic.resolveExpression(rule) as List<dynamic>;
    final second = game.logic.resolveExpression(rule) as List<dynamic>;
    expect(first, second);
    expect(identical(first, second), isFalse);
    expect(identical(first[1], second[1]), isFalse);
  });

  test('compiled and legacy expression failures still return null', () {
    final ownedMalformed = <String, dynamic>{
      'method': ['not-a-target', 'missingMethod'],
    };
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': {'kind': 'free', 'width': 100, 'height': 100, 'bg': '#000000'},
        '_test_rules': [ownedMalformed],
      },
      assetManager: _assetManager(),
    );
    game.resetGame();

    expect(game.logic.resolveExpression(ownedMalformed), isNull);
    expect(
      game.logic.resolveExpression(Map<String, dynamic>.from(ownedMalformed)),
      isNull,
    );
  });
}
