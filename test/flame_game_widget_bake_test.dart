import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/games/flame_game_engine.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_application_1/json_ui/widgets/flame_game_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('flame_game outer template bake preserves game loop namespace', () {
    final interpreter = JsonInterpreter()
      ..loadConfig({
        'global': {
          'variables': {'bestScore': 42},
        },
      });

    final baked = JsonFlameGameWidget().bakeOuterTemplatesForTest({
      'type': 'flame_game',
      'vars': {
        'best': '{{ global.bestScore }}',
        'loopId': '{{ loop.id }}',
        'loopPath': 'enemy_{{ loop.id }}',
        'eventDt': '{{ event.dt }}',
        'entityX': '{{ entities.player.x }}',
      },
    }, interpreter);

    final vars = baked['vars'] as Map<String, dynamic>;
    expect(vars['best'], 42);
    expect(vars['loopId'], '{{ loop.id }}');
    expect(vars['loopPath'], 'enemy_{{ loop.id }}');
    expect(vars['eventDt'], '{{ event.dt }}');
    expect(vars['entityX'], '{{ entities.player.x }}');
  });

  testWidgets(
    'flame games keep parent scope across nested routes and rebind in place',
    (tester) async {
      Map<String, dynamic> config(int value) => <String, dynamic>{
        'dsl': '4.0',
        'appid': 'compute-scope-$value',
        'meta': <String, dynamic>{
          'name': 'compute-scope-$value',
          'version': '1.0.0',
          'type': 'app',
        },
        'global': <String, dynamic>{'variables': <String, dynamic>{}},
        'compute': <String, dynamic>{
          'engine': <String, dynamic>{
            'abi': 2,
            'backend': 'vm',
            'semantics': 'i32-v2',
          },
          'program': <String, dynamic>{
            'version': 2,
            'i32': <String, dynamic>{'state': 1},
            'init': <String, dynamic>{
              'state': <int>[value],
            },
            'functions': <String, dynamic>{},
          },
        },
        'ui': <String, dynamic>{
          'screens': <dynamic>[
            <String, dynamic>{
              'id': 'home',
              'title': 'Scope',
              'children': <dynamic>[],
            },
          ],
        },
      };

      final interpreter = JsonInterpreter();
      addTearDown(interpreter.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      final parentSpec = <String, dynamic>{
        'type': 'flame_game',
        'height': 100,
        'world': <String, dynamic>{
          'kind': 'free',
          'width': 100,
          'height': 100,
          'bg': '#000000',
        },
        'vars': <String, dynamic>{'scope': 'parent'},
      };
      final childSpec = <String, dynamic>{
        'type': 'flame_game',
        'height': 100,
        'world': <String, dynamic>{
          'kind': 'free',
          'width': 100,
          'height': 100,
          'bg': '#000000',
        },
        'vars': <String, dynamic>{'scope': 'child'},
      };

      Widget gamePage(Map<String, dynamic> spec) {
        return Scaffold(
          body: AnimatedBuilder(
            animation: interpreter,
            builder: (context, _) =>
                JsonFlameGameWidget().build(context, spec, interpreter),
          ),
        );
      }

      List<JsonFlameGame> mountedGames() {
        final finder = find.byWidgetPredicate(
          (widget) => widget is GameWidget && widget.game is JsonFlameGame,
          skipOffstage: false,
        );
        return tester
            .widgetList<GameWidget>(finder)
            .map((widget) => widget.game)
            .whereType<JsonFlameGame>()
            .toList(growable: false);
      }

      interpreter.loadConfig(config(1));
      final parentSession = interpreter.computeSession;
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: gamePage(parentSpec)),
      );
      await tester.pump();
      final parentGame = mountedGames().single;
      expect(parentGame.computeSession, same(parentSession));

      // launch_app loads and runs the child before Navigator.push. The parent
      // route is still current during this window and must not bind child state.
      interpreter.pushState();
      interpreter.loadConfig(config(2));
      final childSession = interpreter.computeSession;
      interpreter.setVariable('global.pulse', 1);
      await tester.pump();
      expect(mountedGames().single, same(parentGame));
      expect(parentGame.computeSession, same(parentSession));

      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => gamePage(childSpec)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      var games = mountedGames();
      expect(games, hasLength(2));
      expect(games, contains(same(parentGame)));
      final childGame = games.singleWhere(
        (game) => !identical(game, parentGame),
      );
      expect(childGame.computeSession, same(childSession));

      interpreter.setVariable('global.pulse', 2);
      await tester.pump();
      games = mountedGames();
      expect(games, containsAll(<JsonFlameGame>[parentGame, childGame]));

      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      interpreter.popState();
      await tester.pump();
      games = mountedGames();
      expect(
        games,
        hasLength(1),
        reason:
            'remaining scopes: '
            '${games.map((game) => game.vars['scope']).toList()}',
      );
      expect(games.single, same(parentGame));
      expect(parentGame.computeSession, same(parentSession));

      // A real in-place root App replacement stays at depth 0 and must rebuild
      // the game so it cannot retain the previous App's Compute session.
      interpreter.loadConfig(config(3));
      final replacementSession = interpreter.computeSession;
      interpreter.setVariable('global.pulse', 3);
      await tester.pump();
      final replacementGame = mountedGames().single;
      expect(replacementGame, isNot(same(parentGame)));
      expect(replacementGame.computeSession, same(replacementSession));

      // A same-depth replacement can arrive while another route covers the
      // game. The hidden mount still has to accept the new App identity:
      // popping the cover does not guarantee another didUpdateWidget call.
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      interpreter.loadConfig(config(4));
      final hiddenReplacementSession = interpreter.computeSession;
      interpreter.setVariable('global.pulse', 4);
      await tester.pump();
      final hiddenReplacementGame = mountedGames().single;
      expect(hiddenReplacementGame, isNot(same(replacementGame)));
      expect(
        hiddenReplacementGame.computeSession,
        same(hiddenReplacementSession),
      );

      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(mountedGames().single, same(hiddenReplacementGame));

      // A dialog is still part of the active App scope. In particular,
      // @flame_game_reset is used by game-over dialogs' "play again" button.
      hiddenReplacementGame.vars['scope'] = 'mutated';
      final dialog = showDialog<void>(
        context: navigatorKey.currentContext!,
        builder: (dialogContext) => AlertDialog(
          content: const Text('game over'),
          actions: <Widget>[
            TextButton(
              onPressed: () async {
                await interpreter.executeAction(<String, dynamic>{
                  'call': '@flame_game_reset',
                }, dialogContext);
              },
              child: const Text('play again'),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('play again'));
      await tester.pump();
      expect(hiddenReplacementGame.vars['scope'], 'parent');

      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await dialog;
    },
  );
}
