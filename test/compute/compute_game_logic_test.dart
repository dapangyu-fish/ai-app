import 'package:flutter_application_1/games/flame_game_engine.dart';
import 'package:flutter_application_1/json_ui/asset_manager.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('flame game logic uses the app-scoped generic compute session', () {
    final interpreter = JsonInterpreter()
      ..loadConfig(<String, dynamic>{
        'dsl': '4.0',
        'meta': <String, dynamic>{
          'name': 'compute-game-test',
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
            'functions': <String, dynamic>{
              'mix': <String, dynamic>{
                'params': <String>['left', 'right'],
                'body': <dynamic>[
                  <dynamic>[
                    'ret',
                    <dynamic>[
                      '+',
                      <dynamic>[
                        '*',
                        <dynamic>['var', 'left'],
                        10,
                      ],
                      <dynamic>['var', 'right'],
                    ],
                  ],
                ],
              },
            },
          },
        },
        'ui': <String, dynamic>{
          'screens': <dynamic>[
            <String, dynamic>{
              'id': 'home',
              'title': 'Compute game',
              'children': <dynamic>[],
            },
          ],
        },
      });
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': <String, dynamic>{
          'kind': 'free',
          'width': 100,
          'height': 100,
          'bg': '#000000',
        },
        'vars': <String, dynamic>{'result': 0},
      },
      assetManager: JsonAppAssetManager(
        appId: 'compute-game-test',
        appName: 'compute-game-test',
        appVersion: '1.0.0',
      ),
      computeSession: interpreter.computeSession,
    );
    game.resetGame();

    final result = game.logic.runAction(<String, dynamic>{
      'call': '@compute.call',
      'args': <String, dynamic>{
        'function': 'mix',
        'args': <dynamic>[4, 2],
      },
      'assign': 'vars.result',
    });

    expect(result, 42);
    expect(game.vars['result'], 42);
  });

  test('flame compute calls fail explicitly when the app has no module', () {
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': <String, dynamic>{
          'kind': 'free',
          'width': 100,
          'height': 100,
          'bg': '#000000',
        },
      },
      assetManager: JsonAppAssetManager(
        appId: 'no-compute-game',
        appName: 'no-compute-game',
        appVersion: '1.0.0',
      ),
    );
    game.resetGame();

    expect(
      () => game.logic.runAction(<String, dynamic>{
        'call': '@compute.call',
        'args': <String, dynamic>{'function': 'missing'},
      }),
      throwsA(isA<StateError>()),
    );
  });
}
