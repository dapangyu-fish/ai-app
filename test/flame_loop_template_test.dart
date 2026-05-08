// 复现 match3-pixel 调试发现的 bug：
// flame logic 引擎里 `{{ loop.id }}` 模板在 _resolveString 解析时
// 返回 null，但同 scope 的 jsonlogic {"var": "loop.id"} 能读到。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/games/flame_game_engine.dart';

void main() {
  late JsonFlameGame game;

  setUp(() {
    game = JsonFlameGame(spec: {
      'world': {'kind': 'free', 'width': 100, 'height': 100, 'bg': '#000000'},
      'entities': {
        'g7': {
          'kind': 'pixel',
          'init': [10, 20],
          'size': [16, 16],
          'render': {'shape': 'rect', 'color': '#FF0000'},
        },
      },
      'vars': {
        'targets': {'g7': [99.0, 88.0]},
        '_uid': 'g7',
        'via_jsonlogic': null,
        'via_template': null,
        'read_loop': null,
        'read_vars': null,
      },
    });
    game.resetGame(); // 直接初始化 vars + entities
  });

  test('jsonlogic {"var": "loop.id"} reads pushed loop context', () {
    game.logic.runLogicWithLoop(
      [
        {
          'call': '@set',
          'args': {
            'var': 'vars.via_jsonlogic',
            'value': {'var': 'loop.id'},
          }
        }
      ],
      {'id': 'g7', 'index': 0},
    );
    expect(game.vars['via_jsonlogic'], 'g7');
  });

  test('"{{ loop.id }}" full template reads pushed loop context', () {
    game.logic.runLogicWithLoop(
      [
        {
          'call': '@set',
          'args': {'var': 'vars.via_template', 'value': '{{ loop.id }}'}
        }
      ],
      {'id': 'g7', 'index': 0},
    );
    expect(game.vars['via_template'], 'g7');
  });

  test('"vars.targets.{{ loop.id }}" path template inside var op', () {
    game.logic.runLogicWithLoop(
      [
        {
          'call': '@set',
          'args': {
            'var': 'vars.read_loop',
            'value': {'var': 'vars.targets.{{ loop.id }}'},
          }
        }
      ],
      {'id': 'g7', 'index': 0},
    );
    expect(game.vars['read_loop'], [99.0, 88.0]);
  });

  test('vars-side path template control: should always work', () {
    game.logic.runLogicWithLoop(
      [
        {
          'call': '@set',
          'args': {
            'var': 'vars.read_vars',
            'value': {'var': 'vars.targets.{{ vars._uid }}'},
          }
        }
      ],
      {'id': 'g7', 'index': 0},
    );
    expect(game.vars['read_vars'], [99.0, 88.0]);
  });

  test('@for_each_entity body sees loop.id template', () {
    // 实际生产路径：@for_each_entity 内部 push loopStack 然后 runLogicWithLoop
    game.vars['hits'] = 0;
    game.logic.runLogic([
      {
        'call': '@for_each_entity',
        'args': {
          'where_prefix': 'g',
          'do': [
            {
              'call': '@set',
              'args': {
                'var': 'vars.captured',
                'value': '{{ loop.id }}',
              }
            },
            {
              'call': '@if',
              'args': {
                'cond': {'!=': [{'var': 'vars.captured'}, '']},
                'then': [
                  {
                    'call': '@set',
                    'args': {
                      'var': 'vars.hits',
                      'value': {'+': [{'var': 'vars.hits'}, 1]},
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    ]);
    expect(game.vars['hits'], 1,
        reason: 'loop.id template should resolve inside @for_each_entity body');
    expect(game.vars['captured'], 'g7');
  });

  test('multiple entities (64) + nested @if + event stack mimics frame.logic',
      () {
    // 重建跟 match3-pixel 一样的环境：64 个 g* entity，frame.logic 在
    // @if(phase=="swapping") 嵌套里跑 for_each
    final spec = <String, dynamic>{
      'world': {
        'kind': 'free',
        'width': 400,
        'height': 400,
        'bg': '#000000'
      },
      'entities': <String, dynamic>{},
      'vars': <String, dynamic>{
        'phase': 'swapping',
        'targets': <String, dynamic>{'g7': [99.0, 88.0]},
        'hits': 0,
      },
    };
    for (var i = 0; i < 64; i++) {
      spec['entities']['g$i'] = {
        'kind': 'pixel',
        'init': [0, 0],
        'size': [16, 16],
        'render': {'shape': 'rect', 'color': '#FF0000'},
      };
    }
    final big = JsonFlameGame(spec: spec);
    big.resetGame();

    // 模拟 update(dt) 调 frame.logic
    big.logic.runLogic([
      {
        'call': '@if',
        'args': {
          'cond': {'==': [{'var': 'vars.phase'}, 'swapping']},
          'then': [
            {
              'call': '@for_each_entity',
              'args': {
                'where_prefix': 'g',
                'do': [
                  {
                    'call': '@set',
                    'args': {
                      'var': 'vars._t',
                      'value': {'var': 'vars.targets.{{ loop.id }}'},
                    }
                  },
                  {
                    'call': '@if',
                    'args': {
                      'cond': {'!=': [{'var': 'vars._t'}, null]},
                      'then': [
                        {
                          'call': '@set',
                          'args': {
                            'var': 'vars.hits',
                            'value': {
                              '+': [{'var': 'vars.hits'}, 1]
                            },
                          }
                        }
                      ]
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    ], {'dt': 0.016});

    expect(big.vars['hits'], 1,
        reason: '64 entities, only g7 has target → hits should be 1');
  });

  test('write then read: targets written via {{ vars.X }} read via {{ loop.id }}',
      () {
    // 复刻 match3 真实流程：先用 vars._uid_a 写 targets，再 for_each 用 loop.id 读
    final spec = <String, dynamic>{
      'world': {
        'kind': 'free',
        'width': 400,
        'height': 400,
        'bg': '#000000'
      },
      'entities': <String, dynamic>{
        'g0': {
          'kind': 'pixel',
          'init': [0, 0],
          'size': [16, 16],
          'render': {'shape': 'rect', 'color': '#FF0000'},
        }
      },
      'vars': <String, dynamic>{
        '_uid': 'g0',
        'targets': <String, dynamic>{},
        'hits': 0,
      },
    };
    final g = JsonFlameGame(spec: spec);
    g.resetGame();

    // step 1: 写 targets[_uid] = [10, 20]，跟 tap_logic 一样路径
    g.logic.runLogic([
      {
        'call': '@set',
        'args': {
          'var': 'vars.targets.{{ vars._uid }}',
          'value': [10, 20]
        }
      }
    ]);
    expect(g.vars['targets'], {'g0': [10, 20]},
        reason: 'tap-side write should land at key "g0"');

    // step 2: for_each 用 {{ loop.id }} 读，frame.logic 一样路径
    g.logic.runLogic([
      {
        'call': '@for_each_entity',
        'args': {
          'where_prefix': 'g',
          'do': [
            {
              'call': '@set',
              'args': {
                'var': 'vars._t',
                'value': {'var': 'vars.targets.{{ loop.id }}'},
              }
            },
            {
              'call': '@if',
              'args': {
                'cond': {'!=': [{'var': 'vars._t'}, null]},
                'then': [
                  {
                    'call': '@set',
                    'args': {
                      'var': 'vars.hits',
                      'value': {
                        '+': [{'var': 'vars.hits'}, 1]
                      },
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    ]);

    expect(g.vars['hits'], 1,
        reason: 'frame-side read of {{ loop.id }} should match tap-written key');
  });

  test('reproduce match3-pixel: @spawn entities + write+read via {{ loop.id }}',
      () {
    // 完全镜像 match3-pixel 流程：
    //   1. init.logic 用 @spawn 动态加 entity（不在 spec.entities 里）
    //   2. tap.logic 写 vars.targets[uid]
    //   3. frame.logic for_each 读 vars.targets[loop.id]
    final spec = <String, dynamic>{
      'world': {
        'kind': 'free',
        'width': 400,
        'height': 400,
        'bg': '#000000'
      },
      'vars': <String, dynamic>{
        '_uid_a': 'g0',
        'targets': <String, dynamic>{},
        'hits': 0,
      },
      'init': {
        'logic': [
          {
            'call': '@spawn',
            'args': {
              'id': 'g0',
              'kind': 'pixel',
              'position': [0, 0],
              'size': [16, 16],
              'render': {'shape': 'rect', 'color': '#FF0000'},
            }
          },
          {
            'call': '@spawn',
            'args': {
              'id': 'g1',
              'kind': 'pixel',
              'position': [16, 0],
              'size': [16, 16],
              'render': {'shape': 'rect', 'color': '#00FF00'},
            }
          },
        ]
      }
    };
    final g = JsonFlameGame(spec: spec);
    g.resetGame();
    expect(g.entities.keys.toList(), ['g0', 'g1'],
        reason: 'init.logic should @spawn 2 entities');

    // tap 写 targets[_uid_a]
    g.logic.runLogic([
      {
        'call': '@set',
        'args': {
          'var': 'vars.targets.{{ vars._uid_a }}',
          'value': [50, 60]
        }
      }
    ]);
    expect(g.vars['targets'], {'g0': [50, 60]});

    // frame 读 targets[loop.id]
    g.logic.runLogic([
      {
        'call': '@for_each_entity',
        'args': {
          'where_prefix': 'g',
          'do': [
            {
              'call': '@set',
              'args': {
                'var': 'vars._t',
                'value': {'var': 'vars.targets.{{ loop.id }}'},
              }
            },
            {
              'call': '@if',
              'args': {
                'cond': {'!=': [{'var': 'vars._t'}, null]},
                'then': [
                  {
                    'call': '@set',
                    'args': {
                      'var': 'vars.hits',
                      'value': {'+': [{'var': 'vars.hits'}, 1]}
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    ], {'dt': 0.016});

    expect(g.vars['hits'], 1,
        reason: 'spawn-created g0 entity should be matched by loop.id template');
  });

  test('@for_each_entity body reads vars.targets.{{ loop.id }}', () {
    game.vars['hits'] = 0;
    game.logic.runLogic([
      {
        'call': '@for_each_entity',
        'args': {
          'where_prefix': 'g',
          'do': [
            {
              'call': '@set',
              'args': {
                'var': 'vars._t',
                'value': {'var': 'vars.targets.{{ loop.id }}'},
              }
            },
            {
              'call': '@if',
              'args': {
                'cond': {'!=': [{'var': 'vars._t'}, null]},
                'then': [
                  {
                    'call': '@set',
                    'args': {
                      'var': 'vars.hits',
                      'value': {'+': [{'var': 'vars.hits'}, 1]},
                    }
                  }
                ]
              }
            }
          ]
        }
      }
    ]);
    expect(game.vars['hits'], 1,
        reason:
            'path template `{{ loop.id }}` should substitute inside @for_each');
  });
}
