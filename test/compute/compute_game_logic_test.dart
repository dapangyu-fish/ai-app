import 'dart:typed_data';

import 'package:flutter_application_1/games/framebuffer_v2_entity.dart';
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

  test('host buffer copies are typed, bounded, and do not alias VM memory', () {
    final interpreter = JsonInterpreter()
      ..loadConfig(<String, dynamic>{
        'dsl': '4.0',
        'meta': <String, dynamic>{
          'name': 'compute-buffer-copy-test',
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
            'buffers': <String, dynamic>{'pixels': 4},
            'init': <String, dynamic>{
              'pixels': <int>[1, 2, 3, 4],
            },
            'functions': <String, dynamic>{},
          },
        },
        'ui': <String, dynamic>{
          'screens': <dynamic>[
            <String, dynamic>{
              'id': 'home',
              'title': 'Buffer copy',
              'children': <dynamic>[],
            },
          ],
        },
      });
    final session = interpreter.computeSession!;
    final destination = Uint8List(4);

    expect(session.copyU8BufferInto('pixels', destination, length: 4), 4);
    expect(destination, <int>[1, 2, 3, 4]);
    destination[0] = 99;
    expect(
      session.execute('read', <String, dynamic>{
        'kind': 'u8',
        'buffer': 'pixels',
        'offset': 0,
      }),
      1,
    );
    expect(
      () => session.copyU8BufferInto(
        'pixels',
        destination,
        sourceOffset: 3,
        length: 2,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('flame game materializes a generic compute framebuffer entity', () {
    final interpreter = JsonInterpreter()
      ..loadConfig(<String, dynamic>{
        'dsl': '4.0',
        'meta': <String, dynamic>{
          'name': 'compute-framebuffer-test',
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
            'buffers': <String, dynamic>{'pixels': 4},
            'init': <String, dynamic>{
              'pixels': <int>[0, 1, 2, 3],
            },
            'functions': <String, dynamic>{},
          },
        },
        'ui': <String, dynamic>{
          'screens': <dynamic>[
            <String, dynamic>{
              'id': 'home',
              'title': 'Framebuffer',
              'children': <dynamic>[],
            },
          ],
        },
      });
    final game = JsonFlameGame(
      spec: <String, dynamic>{
        'world': <String, dynamic>{
          'kind': 'pixel',
          'width': 2,
          'height': 2,
          'bg': '#000000',
        },
        'entities': <String, dynamic>{
          'screen': <String, dynamic>{
            'kind': 'framebuffer_v2',
            'buffer': 'pixels',
            'format': 'indexed8',
            'width': 2,
            'height': 2,
            'position': <int>[0, 0],
            'size': <int>[2, 2],
            'palette': <int>[0x000000, 0xff0000, 0x00ff00, 0x0000ff],
          },
        },
      },
      assetManager: JsonAppAssetManager(
        appId: 'compute-framebuffer-test',
        appName: 'compute-framebuffer-test',
        appVersion: '1.0.0',
      ),
      computeSession: interpreter.computeSession,
    );

    game.resetGame();

    expect(game.entities['screen'], isA<FramebufferV2Entity>());
    expect(game.entities['screen']!.toMap(), containsPair('buffer', 'pixels'));

    final oversized = JsonFlameGame(
      spec: <String, dynamic>{
        'world': <String, dynamic>{'kind': 'pixel'},
        'entities': <String, dynamic>{
          'screen': <String, dynamic>{
            'kind': 'framebuffer_v2',
            'buffer': 'pixels',
            'format': 'indexed8',
            'width': (1024 * 1024) + 1,
            'height': 1,
            'palette': <int>[0x000000],
          },
        },
      },
      assetManager: JsonAppAssetManager(
        appId: 'compute-framebuffer-test',
        appName: 'compute-framebuffer-test',
        appVersion: '1.0.0',
      ),
      computeSession: interpreter.computeSession,
    );
    expect(
      oversized.resetGame,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('safety limit'),
        ),
      ),
    );
  });
}
