// 用真实 demo 的 scale=2 还原蘑菇/小怪场景
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flame/extensions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/games/flame_game_engine.dart';
import 'package:flutter_application_1/games/game_entity.dart';
import 'package:flutter_application_1/games/tiled_map_entity.dart';
import 'package:flutter_application_1/json_ui/asset_manager.dart';

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
      markTestSkipped(
        'original flutter_game repo is not cloned at /tmp/flutter_game_ref',
      );
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

  test('真实 Mario JSON: 加载后渲染旗杆并能生成原始 Koopa 对象', () async {
    if (!File(_localMarioTmxPath).existsSync()) {
      markTestSkipped(
        'original flutter_game repo is not cloned at /tmp/flutter_game_ref',
      );
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
    expect(game.entities['flagpole_101'], isA<SpriteEntity>());
    expect(game.entities['flagpole_111'], isA<SpriteEntity>());

    final player = game.entities['player'] as PixelEntity;
    player.x = 2500;
    game.vars['state'] = 'running';
    game.logic.runLogic(frameLogic, {'dt': 0.016});
    final koopa = game.entities['enemy_98'];
    expect(koopa, isA<AnimatedSpriteEntity>());
    expect((koopa as PixelEntity).state['kind'], 'koopa');
    final farX = koopa.x;
    expect(koopa.vx, 0, reason: 'Koopa should be present but idle off-screen');

    player.x = 2800;
    game.logic.runLogic(frameLogic, {'dt': 0.016});
    expect(koopa.vx, lessThan(0));
    expect(koopa.x, lessThan(farX));
    for (var i = 0; i < 90; i++) {
      game.logic.runLogic(frameLogic, {'dt': 0.016});
    }
    expect(
      koopa.y,
      closeTo(352, 1),
      reason: 'Koopa should stay on the platform after activation',
    );
    expect(
      koopa.vy,
      0,
      reason: 'Koopa should not fall through the ground while off-camera',
    );
  });

  test('真实 Mario JSON: 只有 fire 状态可以发射原版火球 sprite', () async {
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
      assetManager: _testAssetManager(),
    );
    game.resetGame(varOverrides: {'state': 'running'});
    game.audio.dispose();
    final attackLogic =
        (flameSpec['input'] as Map<String, dynamic>)['attack'] as List;

    game.vars['player_power'] = null;
    game.logic.runLogic(attackLogic, {});
    expect(game.entities['fireball'], isNull);

    game.vars['player_power'] = 'big';
    game.logic.runLogic(attackLogic, {});
    expect(game.entities['fireball'], isNull);

    game.vars['player_power'] = 'fire';
    game.logic.runLogic(attackLogic, {});
    final fireball = game.entities['fireball'];
    expect(fireball, isA<AnimatedSpriteEntity>());
    expect(
      (fireball as AnimatedSpriteEntity).asset,
      contains('item_objects.png'),
    );
    expect(fireball.frameW, 8);
    expect(fireball.frameH, 8);
  });

  test('真实 Mario JSON: powered Mario 碰敌人会变小且不扣生命', () async {
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
      assetManager: _testAssetManager(),
    );
    game.resetGame(varOverrides: {'state': 'running'});
    game.audio.dispose();
    final frameLogic =
        (flameSpec['frame'] as Map<String, dynamic>)['logic'] as List;
    final mainLogic =
        ((frameLogic[8] as Map<String, dynamic>)['args']
                as Map<String, dynamic>)['else']
            as List;
    final hitAction = mainLogic.cast<Map<String, dynamic>>().firstWhere(
      (node) =>
          node['call'] == '@if' && node.toString().contains('vars.hit_enemy'),
    );

    final player = game.entities['player'] as PixelEntity;
    player
      ..x = 100
      ..y = 100
      ..w = 28
      ..h = 64
      ..vy = 0;
    player.state['spriteW'] = 32;
    player.state['spriteH'] = 64;
    player.state['hurtTimer'] = 0;
    game.spawnEntity('enemy_test', {
      'kind': 'pixel',
      'position': [110, 120],
      'size': [32, 32],
      'velocity': [0, 0],
      'render': {'shape': 'rect', 'color': '#00FF00'},
    });
    game.vars['player_power'] = 'fire';
    game.vars['lives'] = 3;
    game.vars['hit_enemy'] = 'enemy_test';

    game.logic.runStep(hitAction);

    expect(game.vars['lives'], 3);
    expect(game.vars['player_power'], isNull);
    expect(player.h, 32);
    expect(player.w, 24);
    expect(player.state['hurtTimer'], greaterThan(0));
  });

  test('真实 Mario JSON: Koopa 被踩后变成可踢龟壳', () async {
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
      assetManager: _testAssetManager(),
    );
    game.resetGame(varOverrides: {'state': 'running'});
    game.audio.dispose();
    final frameLogic =
        (flameSpec['frame'] as Map<String, dynamic>)['logic'] as List;
    final mainLogic =
        ((frameLogic[8] as Map<String, dynamic>)['args']
                as Map<String, dynamic>)['else']
            as List;
    final hitAction = mainLogic.cast<Map<String, dynamic>>().firstWhere(
      (node) =>
          node['call'] == '@if' && node.toString().contains('vars.hit_enemy'),
    );

    final player = game.entities['player'] as PixelEntity;
    player
      ..x = 100
      ..y = 100
      ..w = 24
      ..h = 32
      ..vy = 120;
    player.state['hurtTimer'] = 0;
    game.spawnEntity('enemy_98', {
      'kind': 'animated_sprite',
      'asset': '',
      'position': [96, 128],
      'size': [32, 48],
      'velocity': [0, 0],
      'auto_update': false,
      'state': {'kind': 'koopa', 'dir': -1, 'tiledObjectId': 98},
      'frame_size': [16, 24],
      'frames': 2,
      'frames_per_row': 2,
      'render': {'shape': 'rect', 'color': '#00FF00'},
    });
    game.vars['hit_enemy'] = 'enemy_98';

    game.logic.runStep(hitAction);

    expect(game.entities['enemy_98'], isNull);
    final shell = game.entities['shell_98'];
    expect(shell, isA<SpriteEntity>());
    expect((shell as PixelEntity).state['kind'], 'shell');
    expect(shell.state['dir'], 0);
    expect(shell.vx, 0);
  });

  test('真实 Mario JSON: 玩家碰到龟壳会把龟壳踢出', () async {
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
      assetManager: _testAssetManager(),
    );
    game.resetGame(varOverrides: {'state': 'running'});
    game.audio.dispose();
    final frameLogic =
        (flameSpec['frame'] as Map<String, dynamic>)['logic'] as List;
    final mainLogic =
        ((frameLogic[8] as Map<String, dynamic>)['args']
                as Map<String, dynamic>)['else']
            as List;
    final hitShellIndex = mainLogic.indexWhere(
      (node) => node is Map && node['assign'] == 'vars.hit_shell',
    );
    expect(hitShellIndex, greaterThanOrEqualTo(0));

    final player = game.entities['player'] as PixelEntity;
    player
      ..x = 80
      ..y = 100
      ..w = 24
      ..h = 32;
    player.state['hurtTimer'] = 0;
    game.spawnEntity('shell_98', {
      'kind': 'sprite',
      'asset': '',
      'position': [100, 100],
      'size': [32, 30],
      'velocity': [0, 0],
      'auto_update': false,
      'src': [360, 5, 16, 15],
      'state': {'kind': 'shell', 'dir': 0},
      'render': {'shape': 'rect', 'color': '#00FF00'},
    });

    game.logic.runStep(mainLogic[hitShellIndex]);
    game.logic.runStep(mainLogic[hitShellIndex + 1]);

    final shell = game.entities['shell_98'] as PixelEntity;
    expect(shell.state['dir'], 1);
    expect(shell.vx, 400);
    expect(shell.state['moving_shell'], true);
  });

  test('真实 Mario JSON: 移动龟壳会击杀碰到的敌人', () async {
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
      assetManager: _testAssetManager(),
    );
    game.resetGame(varOverrides: {'state': 'running'});
    game.audio.dispose();
    final frameLogic =
        (flameSpec['frame'] as Map<String, dynamic>)['logic'] as List;
    final mainLogic =
        ((frameLogic[8] as Map<String, dynamic>)['args']
                as Map<String, dynamic>)['else']
            as List;
    final shellLoop = mainLogic.cast<Map<String, dynamic>>().firstWhere(
      (node) =>
          node['call'] == '@for_each_entity' &&
          (node['args'] as Map)['where_prefix'] == 'shell_',
    );

    game.spawnEntity('shell_98', {
      'kind': 'sprite',
      'asset': '',
      'position': [100, 100],
      'size': [32, 30],
      'velocity': [0, 0],
      'auto_update': false,
      'src': [360, 5, 16, 15],
      'state': {'kind': 'shell', 'dir': 1},
      'render': {'shape': 'rect', 'color': '#00FF00'},
    });
    game.spawnEntity('enemy_14', {
      'kind': 'pixel',
      'position': [112, 100],
      'size': [32, 32],
      'velocity': [0, 0],
      'auto_update': false,
      'state': {'kind': 'goomba', 'dir': -1},
      'render': {'shape': 'rect', 'color': '#FF0000'},
    });

    game.logic.runStep(shellLoop);

    expect(game.entities['enemy_14'], isNull);
    final shell = game.entities['shell_98'] as PixelEntity;
    expect(shell.vx, 400);
  });

  test('平台跳跃: 向上撞击多个相邻块时选择角色中心命中的块', () async {
    final game = JsonFlameGame(
      spec: {
        'world': {'kind': 'pixel', 'width': 320, 'height': 240, 'bg': '#000'},
        'physics': {'engine': 'aabb_platformer'},
        'entities': {
          'map': {
            'kind': 'tiled_map',
            'scale': 1,
            'map_data': {
              'width': 20,
              'height': 15,
              'tilewidth': 16,
              'tileheight': 16,
              'layers': [
                {
                  'type': 'objectgroup',
                  'name': 'brick blocks',
                  'objects': [
                    {'id': 10, 'x': 64, 'y': 100, 'width': 32, 'height': 32},
                  ],
                },
                {
                  'type': 'objectgroup',
                  'name': 'question blocks',
                  'objects': [
                    {'id': 20, 'x': 32, 'y': 100, 'width': 32, 'height': 32},
                    {'id': 21, 'x': 96, 'y': 100, 'width': 32, 'height': 32},
                  ],
                },
              ],
            },
            'solid_layers': ['brick blocks', 'question blocks'],
            'collidable': true,
          },
          'player': {
            'kind': 'pixel',
            'position': [57, 137],
            'size': [46, 32],
            'velocity': [0, -200],
            'auto_update': false,
            'state': {},
            'render': {'shape': 'rect', 'color': '#FF0000'},
          },
        },
      },
      assetManager: _testAssetManager(),
    );
    game.resetGame();
    final map = game.entities['map'] as TiledMapEntity;
    await map.load();

    game.logic.runLogic([
      {
        'call': '@platformer.step',
        'args': {
          'id': 'player',
          'map': 'map',
          'dt': 0.05,
          'gravity': 0,
          'max_fall': 1000,
        },
      },
    ]);

    final player = game.entities['player'] as PixelEntity;
    expect(player.state['blockedUp'], true);
    expect(player.state['yCollision']['tileset'], 'brick blocks');
    expect(player.state['yCollision']['objectId'], 10);
  });

  test('真实 Mario JSON: powered Mario 碎砖会移除砖块实体和 TMX 碰撞对象', () async {
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
        'width': 20,
        'height': 20,
        'tilewidth': 8,
        'tileheight': 8,
        'layers': [
          {
            'type': 'objectgroup',
            'name': 'brick blocks',
            'objects': [
              {'id': 7, 'x': 100, 'y': 80, 'width': 16, 'height': 16},
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
    expect(game.entities['brick_7'], isA<SpriteEntity>());
    expect(
      map.collisionRectsIn(const Rect.fromLTWH(200, 160, 32, 32)),
      isNotEmpty,
    );

    final player = game.entities['player'] as PixelEntity;
    player.state['blockedUp'] = true;
    player.state['yCollision'] = {
      'x': 200,
      'y': 160,
      'w': 32,
      'h': 32,
      'type': 'Solid',
      'tileset': 'brick blocks',
      'objectId': 7,
      'layer': 'brick blocks',
    };
    game.vars['player_power'] = 'big';
    game.vars['state'] = 'running';
    final brickBreakAction =
        ((frameLogic[8] as Map<String, dynamic>)['args']
                as Map<String, dynamic>)['else']
            .cast<Map<String, dynamic>>()
            .firstWhere(
              (node) => node.toString().contains('@tiled.remove_object'),
            );
    game.logic.runStep(brickBreakAction);

    expect(game.entities['brick_7'], isNull);
    expect(game.entities['brick_piece_7_a'], isA<AnimatedSpriteEntity>());
    expect(game.entities['brick_piece_7_b'], isA<AnimatedSpriteEntity>());
    expect(game.entities['brick_piece_7_c'], isA<AnimatedSpriteEntity>());
    expect(game.entities['brick_piece_7_d'], isA<AnimatedSpriteEntity>());
    expect(map.objectsByLayer['brick blocks'], isEmpty);
    expect(
      map.collisionRectsIn(const Rect.fromLTWH(200, 160, 32, 32)),
      isEmpty,
    );
  });
}
