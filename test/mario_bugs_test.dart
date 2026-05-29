// 用真实 demo 的 scale=2 还原蘑菇/小怪场景
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/games/flame_game_engine.dart';
import 'package:flutter_application_1/games/game_entity.dart';
import 'package:flutter_application_1/games/tiled_map_entity.dart';
import 'package:flutter_application_1/json_ui/asset_manager.dart';
import 'package:vector_math/vector_math.dart';

const _localMarioTmxPath = '/tmp/flutter_game_ref/assets/tiles/mario.tmx';

JsonAppAssetManager _testAssetManager() {
  return JsonAppAssetManager(
    appId: 'test',
    appName: 'test',
    appVersion: '0.0.0',
  );
}

class _LocalMarioAssetManager extends JsonAppAssetManager {
  _LocalMarioAssetManager()
    : super(appId: 'test', appName: 'test', appVersion: '0.0.0');

  @override
  Future<Uint8List> loadBytes(String path) async {
    if (path.endsWith('/tiles/mario.tmx') || path.endsWith('tiles/mario.tmx')) {
      return File(_localMarioTmxPath).readAsBytes();
    }
    return super.loadBytes(path);
  }
}

Future<JsonFlameGame> _buildScene() async {
  final game = JsonFlameGame(
    spec: {
      'world': {'kind': 'pixel', 'width': 960, 'height': 540, 'bg': '#5C94FC'},
      'physics': {'engine': 'leap_platformer', 'fallback': 'aabb_platformer'},
      'entities': {
        'map': {
          'kind': 'tiled_map',
          'scale': 2,
          'map_data': {
            'width': 100,
            'height': 30,
            'tilewidth': 8,
            'tileheight': 8,
            'layers': [
              {
                'type': 'objectgroup',
                'name': 'question blocks',
                'objects': [
                  // 问号砖块（源坐标 x=288 y=128 w=16 h=16）
                  {'id': 1, 'x': 288, 'y': 128, 'width': 16, 'height': 16},
                ],
              },
              {
                'type': 'objectgroup',
                'name': 'grounds',
                'objects': [
                  {'id': 2, 'x': 0, 'y': 200, 'width': 1100, 'height': 24},
                ],
              },
              {
                'type': 'objectgroup',
                'name': 'enemies',
                'objects': [
                  {
                    'id': 14,
                    'name': 'group0',
                    'type': 'goomba',
                    'x': 832,
                    'y': 184,
                    'width': 16,
                    'height': 16,
                  },
                ],
              },
              {
                'type': 'objectgroup',
                'name': 'collider',
                'objects': [
                  // 高桶（h=64 源 = 128 px 缩放）
                  {'id': 11, 'x': 912, 'y': 136, 'width': 32, 'height': 64},
                ],
              },
            ],
          },
          'solid_layers': ['question blocks', 'grounds', 'collider'],
          'collidable': true,
        },
        'player': {
          'kind': 'pixel',
          'position': [64, 368], // 与真实 demo 一致
          'size': [24, 32],
          'velocity': [0, 0],
          'auto_update': false,
          'render': {'shape': 'rect', 'color': '#FF0000'},
        },
      },
    },
    assetManager: _testAssetManager(),
  );
  game.resetGame();
  final map = game.entities['map'] as TiledMapEntity;
  await map.load();
  return game;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实 Mario JSON: 顶红蘑菇问号块后 powerup 会 reveal 并移动', () async {
    final raw =
        json.decode(
              File('templates/demo_mario_platformer.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final flameSpec = Map<String, dynamic>.from(
      raw['ui']['screens'][0]['children'][0]['child'] as Map,
    );
    final entities = Map<String, dynamic>.from(flameSpec['entities'] as Map);
    entities['map'] = {
      ...Map<String, dynamic>.from(entities['map'] as Map),
      'source': '',
      'map_data': {
        'width': 100,
        'height': 30,
        'tilewidth': 8,
        'tileheight': 8,
        'layers': [
          {
            'type': 'objectgroup',
            'name': 'question blocks',
            'objects': [
              {
                'id': 3,
                'type': 'red mushroom',
                'x': 336,
                'y': 136,
                'width': 16,
                'height': 16,
              },
            ],
          },
          {
            'type': 'objectgroup',
            'name': 'grounds',
            'objects': [
              {'id': 2, 'x': 0, 'y': 200, 'width': 1100, 'height': 24},
            ],
          },
        ],
      },
    };
    flameSpec['entities'] = entities;

    final game = JsonFlameGame(
      spec: flameSpec,
      assetManager: _testAssetManager(),
    );
    game.resetGame(varOverrides: {'state': 'loading'});
    game.audio.dispose();
    final map = game.entities['map'] as TiledMapEntity;
    await map.load();
    final frameLogic =
        (flameSpec['frame'] as Map<String, dynamic>)['logic'] as List;

    game.logic.runLogic(frameLogic, {'dt': 0.016});
    expect(game.entities.containsKey('qblock_3'), true);
    expect(
      (game.entities['qblock_3'] as PixelEntity).state['content'],
      'red mushroom',
      reason: 'QuestionBlock 的内容类型要保存在砖块实体上，不能只依赖碰撞返回值',
    );

    game.vars['state'] = 'running';
    game.vars['jump_pressed'] = false;
    game.vars['jump_held'] = false;
    game.vars['move_axis'] = 0;
    final player = game.entities['player'] as PixelEntity;
    player
      ..x = 676
      ..y = 304
      ..vx = 0
      ..vy = -360;

    game.logic.runLogic(frameLogic, {'dt': 0.016});
    final spawned = game.entities['powerup_3'];
    expect(spawned, isA<PixelEntity>());
    final mushroom = spawned as PixelEntity;
    final spawnY = mushroom.y;
    expect(spawnY, 240);
    expect(mushroom.state['revealing'], false);
    expect(
      mushroom.priority,
      greaterThan((game.entities['qblock_3'] as PixelEntity).priority),
      reason: '真机上 reveal 循环不稳定，红蘑菇应先稳定显示在砖块上方',
    );

    for (var i = 0; i < 60; i++) {
      game.logic.runLogic(frameLogic, {'dt': 0.016});
    }

    expect(mushroom.state['revealing'], false);
    expect(mushroom.x, greaterThan(672));
  });

  test('真实 Mario JSON + 原始 TMX: 红蘑菇块按 qblock content 生成 powerup', () async {
    if (!File(_localMarioTmxPath).existsSync()) {
      markTestSkipped('original flutter_game repo is not cloned at /tmp/flutter_game_ref');
      return;
    }
    final raw =
        json.decode(
              File('templates/demo_mario_platformer.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final flameSpec = Map<String, dynamic>.from(
      raw['ui']['screens'][0]['children'][0]['child'] as Map,
    );

    final game = JsonFlameGame(
      spec: flameSpec,
      assetManager: _LocalMarioAssetManager(),
    );
    game.resetGame(varOverrides: {'state': 'loading'});
    game.audio.dispose();
    final map = game.entities['map'] as TiledMapEntity;
    await map.load();
    final frameLogic =
        (flameSpec['frame'] as Map<String, dynamic>)['logic'] as List;

    game.logic.runLogic(frameLogic, {'dt': 0.016});
    final block = game.entities['qblock_3'];
    expect(block, isA<PixelEntity>());
    expect((block as PixelEntity).state['content'], 'red mushroom');

    game.vars['state'] = 'running';
    game.vars['jump_pressed'] = false;
    game.vars['jump_held'] = false;
    game.vars['move_axis'] = 0;
    final player = game.entities['player'] as PixelEntity;
    player
      ..x = 676
      ..y = 304
      ..vx = 0
      ..vy = -360;

    game.logic.runLogic(frameLogic, {'dt': 0.016});

    expect(player.state['blockedUp'], true);
    expect(player.state['yCollision']?['objectId'], 3);
    expect(game.entities['powerup_3'], isA<PixelEntity>());
    final mushroom = game.entities['powerup_3'] as PixelEntity;
    final spawnY = mushroom.y;
    expect(mushroom.state['kind'], 'red_mushroom');
    expect(spawnY, 240);
    expect(mushroom.state['revealing'], false);

    for (var i = 0; i < 60; i++) {
      game.logic.runLogic(frameLogic, {'dt': 0.016});
    }
    expect(mushroom.state['revealing'], false);
    expect(mushroom.x, greaterThan(672));
  });

  test('BUG 1 真实场景: mushroom 从砖块顶升起', () async {
    final game = await _buildScene();

    // 砖块在源坐标 (288, 128, 16, 16) → scaled (576, 256, 32, 32)
    // 玩家顶到砖块 → yCollision.x=576, y=256
    // mushroom spawn at (576, 256), size [32,32], targetY = 256 - 32 = 224
    game.spawnEntity('powerup_1', {
      'kind': 'sprite',
      'asset': '',
      'src': [0, 0, 16, 16],
      'position': [576, 256],
      'size': [32, 32],
      'velocity': [0, 0],
      'auto_update': false,
      'state': {
        'kind': 'red_mushroom',
        'dir': 1,
        'revealing': true,
        'reveal_time': 0,
        'targetY': 224,
      },
    });
    final mushroom = game.entities['powerup_1'] as PixelEntity;
    // ignore: avoid_print
    print(
      'mushroom 初始: x=${mushroom.x} y=${mushroom.y} '
      'targetY=${mushroom.state['targetY']} '
      'revealing=${mushroom.state['revealing']}',
    );

    // 真实 demo 的 powerup loop（粘贴自 JSON）
    final powerupLogic = [
      {
        'call': '@for_each_entity',
        'args': {
          'where_prefix': 'powerup_',
          'do': [
            {
              'call': '@set',
              'args': {'var': 'vars._powerup_id', 'value': '{{ loop.id }}'},
            },
            {
              'call': '@if',
              'args': {
                'cond': {'var': 'loop.entity.revealing'},
                'then': [
                  {
                    'call': '@entity.add',
                    'args': {
                      'id': '{{ vars._powerup_id }}',
                      'field': 'y',
                      'by': {
                        '*': [
                          -64,
                          {'var': 'event.dt'},
                        ],
                      },
                      'min': {'var': 'loop.entity.targetY'},
                    },
                  },
                  {
                    'call': '@if',
                    'args': {
                      'cond': {
                        '<=': [
                          {'var': 'loop.entity.y'},
                          {
                            '+': [
                              {'var': 'loop.entity.targetY'},
                              1,
                            ],
                          },
                        ],
                      },
                      'then': [
                        {
                          'call': '@entity.set',
                          'args': {
                            'id': '{{ vars._powerup_id }}',
                            'field': 'y',
                            'value': {'var': 'loop.entity.targetY'},
                          },
                        },
                        {
                          'call': '@entity.set',
                          'args': {
                            'id': '{{ vars._powerup_id }}',
                            'field': 'state.revealing',
                            'value': false,
                          },
                        },
                        {
                          'call': '@entity.set',
                          'args': {
                            'id': '{{ vars._powerup_id }}',
                            'field': 'vx',
                            'value': {
                              '*': [
                                {'var': 'loop.entity.dir'},
                                140,
                              ],
                            },
                          },
                        },
                      ],
                    },
                  },
                ],
                'else': [
                  {
                    'call': '@entity.set',
                    'args': {
                      'id': '{{ vars._powerup_id }}',
                      'field': 'vx',
                      'value': {
                        '*': [
                          {'var': 'loop.entity.dir'},
                          140,
                        ],
                      },
                    },
                  },
                  {
                    'call': '@platformer.step',
                    'args': {
                      'id': '{{ vars._powerup_id }}',
                      'map': 'map',
                      'dt': '{{ event.dt }}',
                      'gravity': 700,
                      'max_fall': 900,
                    },
                  },
                ],
              },
            },
          ],
        },
      },
    ];

    for (var i = 0; i < 60; i++) {
      game.logic.runLogic(powerupLogic, {'dt': 0.016});
      if (i % 10 == 0) {
        // ignore: avoid_print
        print(
          '帧 $i: x=${mushroom.x.toStringAsFixed(1)} '
          'y=${mushroom.y.toStringAsFixed(1)} '
          'vx=${mushroom.vx} vy=${mushroom.vy} '
          'revealing=${mushroom.state['revealing']}',
        );
      }
    }
    // ignore: avoid_print
    print(
      '最终: x=${mushroom.x.toStringAsFixed(1)} y=${mushroom.y.toStringAsFixed(1)}',
    );

    expect(mushroom.state['revealing'], false);
    expect(mushroom.x, isNot(576), reason: '蘑菇应水平移动');
  });

  test('BUG 3 真实场景: goomba 走动', () async {
    final game = await _buildScene();
    // 通过 spawn 走真实路径（kind=animated_sprite + state.dir=-1）
    game.spawnEntity('enemy_14', {
      'kind': 'animated_sprite',
      'priority': 30,
      'asset': '',
      'src_origin': [0, 4],
      'frame_size': [16, 16],
      'frames': 2,
      'frames_per_row': 2,
      'frame_step': [30, 0],
      'step_time': 0.1,
      'position': [1664, 368], // 源 (832, 184) * scale 2
      'size': [32, 32],
      'velocity': [0, 0],
      'auto_update': false,
      'state': {'kind': 'goomba', 'dir': -1, 'activated': true},
    });

    final goomba = game.entities['enemy_14'] as PixelEntity;
    // ignore: avoid_print
    print('goomba 初始: x=${goomba.x} y=${goomba.y} dir=${goomba.state['dir']}');

    final enemyLogic = [
      {
        'call': '@for_each_entity',
        'args': {
          'where_prefix': 'enemy_',
          'do': [
            {
              'call': '@entity.set',
              'args': {
                'id': '{{ loop.id }}',
                'field': 'vx',
                'value': {
                  '*': [
                    {'var': 'loop.entity.dir'},
                    100,
                  ],
                },
              },
            },
            {
              'call': '@platformer.step',
              'args': {
                'id': '{{ loop.id }}',
                'map': 'map',
                'dt': '{{ event.dt }}',
                'gravity': 1400,
                'max_fall': 900,
              },
            },
            {
              'call': '@if',
              'args': {
                'cond': {
                  'or': [
                    {'var': 'entities.{{ loop.id }}.blockedLeft'},
                    {'var': 'entities.{{ loop.id }}.blockedRight'},
                  ],
                },
                'then': [
                  {
                    'call': '@entity.set',
                    'args': {
                      'id': '{{ loop.id }}',
                      'field': 'state.dir',
                      'value': {
                        '*': [
                          {'var': 'loop.entity.dir'},
                          -1,
                        ],
                      },
                    },
                  },
                ],
              },
            },
          ],
        },
      },
    ];

    final startX = goomba.x;
    for (var i = 0; i < 30; i++) {
      game.logic.runLogic(enemyLogic, {'dt': 0.016});
      if (i % 5 == 0) {
        // ignore: avoid_print
        print(
          '帧 $i: x=${goomba.x.toStringAsFixed(2)} '
          'vx=${goomba.vx} dir=${goomba.state['dir']} '
          'onGround=${goomba.state['onGround']} '
          'blockedLeft=${goomba.state['blockedLeft']}',
        );
      }
    }
    // ignore: avoid_print
    print('位移: ${(goomba.x - startX).toStringAsFixed(2)}');
    expect(goomba.x, lessThan(startX), reason: 'goomba 应向左走');
  });

  test('真实 Mario JSON: 完整 game.update 帧循环会推进敌人和蘑菇', () async {
    final raw =
        json.decode(
              File('templates/demo_mario_platformer.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final flameSpec = Map<String, dynamic>.from(
      raw['ui']['screens'][0]['children'][0]['child'] as Map,
    );
    final entities = Map<String, dynamic>.from(flameSpec['entities'] as Map);
    entities['map'] = {
      ...Map<String, dynamic>.from(entities['map'] as Map),
      'source': '',
      'map_data': {
        'width': 100,
        'height': 30,
        'tilewidth': 8,
        'tileheight': 8,
        'layers': [
          {
            'type': 'objectgroup',
            'name': 'question blocks',
            'objects': [
              {
                'id': 3,
                'type': 'red mushroom',
                'x': 336,
                'y': 136,
                'width': 16,
                'height': 16,
              },
            ],
          },
          {
            'type': 'objectgroup',
            'name': 'grounds',
            'objects': [
              {'id': 2, 'x': 0, 'y': 200, 'width': 1100, 'height': 24},
            ],
          },
          {
            'type': 'objectgroup',
            'name': 'enemies',
            'objects': [
              {
                'id': 14,
                'type': 'goomba',
                'x': 420,
                'y': 184,
                'width': 16,
                'height': 16,
              },
            ],
          },
        ],
      },
    };
    flameSpec['entities'] = entities;

    final game = JsonFlameGame(
      spec: flameSpec,
      assetManager: _testAssetManager(),
    );
    game.onGameResize(Vector2(960, 540));
    game.resetGame(varOverrides: {'state': 'loading'});
    game.audio.dispose();
    final map = game.entities['map'] as TiledMapEntity;
    await map.load();

    game.update(0.016);
    expect(game.vars['state'], 'running');
    expect(game.entities['enemy_14'], isA<PixelEntity>());
    final goomba = game.entities['enemy_14'] as PixelEntity;
    final goombaStartX = goomba.x;

    final player = game.entities['player'] as PixelEntity;
    player
      ..x = 676
      ..y = 304
      ..vx = 0
      ..vy = -360;
    game.update(0.016);
    expect(game.entities['powerup_3'], isA<PixelEntity>());
    final mushroom = game.entities['powerup_3'] as PixelEntity;
    final mushroomStartX = mushroom.x;

    for (var i = 0; i < 60; i++) {
      game.update(0.016);
    }

    expect(goomba.x, lessThan(goombaStartX), reason: '完整帧循环中 goomba 应向左走');
    expect(
      mushroom.x,
      greaterThan(mushroomStartX),
      reason: '完整帧循环中 red mushroom 应向右移动',
    );
  });

  test('BUG 2: 长按跳 vs 短按跳 高度对比（原版 0.4 系数）', () async {
    // 平地，没有桶。两种情形跑同样的帧数：
    // - 短按：jump_held 只在第 1 帧 true
    // - 长按：jump_held 全程 true
    // 取最高点（最小 y），长按应该明显更高
    Future<JsonFlameGame> mk() async {
      final g = JsonFlameGame(
        spec: {
          'world': {
            'kind': 'pixel',
            'width': 960,
            'height': 540,
            'bg': '#000000',
          },
          'physics': {'engine': 'aabb_platformer'},
          'entities': {
            'map': {
              'kind': 'tiled_map',
              'scale': 2,
              'map_data': {
                'width': 100,
                'height': 30,
                'tilewidth': 8,
                'tileheight': 8,
                'layers': [
                  {
                    'type': 'objectgroup',
                    'name': 'grounds',
                    'objects': [
                      {'id': 1, 'x': 0, 'y': 200, 'width': 800, 'height': 24},
                    ],
                  },
                ],
              },
              'solid_layers': ['grounds'],
              'collidable': true,
            },
            'player': {
              'kind': 'pixel',
              'position': [64, 368],
              'size': [24, 32],
              'velocity': [0, 0],
              'auto_update': false,
              'state': {'onGround': true},
              'render': {'shape': 'rect', 'color': '#FF0000'},
            },
          },
        },
        assetManager: _testAssetManager(),
      );
      g.resetGame();
      final m = g.entities['map'] as TiledMapEntity;
      await m.load();
      return g;
    }

    Future<double> runScenario(bool holdJump) async {
      final g = await mk();
      final player = g.entities['player'] as PixelEntity;
      // 把 jump_held / 阈值 / 系数都放到 vars（JSON 层），@platformer.step
      // 只收一个 number 形态的 gravity——条件分支在 jsonlogic 算
      g.vars['jump_held'] = false;
      g.vars['jump_higher_factor'] = 0.4;
      g.vars['jump_higher_max_vy'] = -340;
      g.vars['gravity_base'] = 1700;
      double minY = player.y;
      for (var i = 0; i < 80; i++) {
        final pressedThisFrame = i == 0;
        g.vars['jump_held'] = holdJump ? player.vy <= 0 : pressedThisFrame;
        g.logic.runLogic(
          [
            {
              'call': '@platformer.step',
              'args': {
                'id': 'player',
                'map': 'map',
                'dt': 0.016,
                // 跟真实 demo 同款 jsonlogic 表达式：长按 + 上升阶段 → 重力 ×0.4
                'gravity': {
                  'if': [
                    {
                      'and': [
                        {'var': 'vars.jump_held'},
                        {
                          '>': [
                            {'var': 'entities.player.vy'},
                            {'var': 'vars.jump_higher_max_vy'},
                          ],
                        },
                        {
                          '<': [
                            {'var': 'entities.player.vy'},
                            0,
                          ],
                        },
                      ],
                    },
                    {
                      '*': [
                        {'var': 'vars.gravity_base'},
                        {'var': 'vars.jump_higher_factor'},
                      ],
                    },
                    {'var': 'vars.gravity_base'},
                  ],
                },
                'jump_velocity': -560,
                'jump': pressedThisFrame,
                'max_fall': 1100,
              },
            },
          ],
          {'dt': 0.016},
        );
        if (player.y < minY) minY = player.y;
      }
      return 368 - minY;
    }

    final shortJumpHeight = await runScenario(false);
    final longJumpHeight = await runScenario(true);
    // ignore: avoid_print
    print('短按跳高: ${shortJumpHeight.toStringAsFixed(1)} px');
    // ignore: avoid_print
    print('长按跳高: ${longJumpHeight.toStringAsFixed(1)} px');
    expect(
      longJumpHeight,
      greaterThan(shortJumpHeight * 1.4),
      reason: '长按应明显比短按高（原版 0.4 重力系数）',
    );
    // 玩家在地面 y=368（脚在 400），桶最高 h=64 src → 顶在 y=272 缩放
    // 起跳高度需 ≥ (400 - 272) = 128 px 才能让脚刚好踩到桶顶
    // 长按必须能过桶（脚比桶顶高至少 1 px → 起跳高度 ≥ 128）
    final clearedShort = (400 - 32 - shortJumpHeight) <= 272;
    final clearedLong = (400 - 32 - longJumpHeight) <= 272;
    // ignore: avoid_print
    print('短按能跳过 h=64src 桶: $clearedShort');
    // ignore: avoid_print
    print('长按能跳过 h=64src 桶: $clearedLong');
    expect(clearedShort, false, reason: '短按不应跳过最高桶（这是 bug 的来源）');
    expect(clearedLong, true, reason: '长按应能跳过最高桶');
  });
}
