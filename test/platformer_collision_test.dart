import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/games/flame_game_engine.dart';
import 'package:myapp/games/game_entity.dart';
import 'package:myapp/games/tiled_map_entity.dart';
import 'package:myapp/json_ui/asset_manager.dart';

JsonAppAssetManager _testAssetManager() {
  return JsonAppAssetManager(
    appId: 'test-platformer-collision',
    appName: 'test-platformer-collision',
    appVersion: '0.0.0',
  );
}

Future<JsonFlameGame> _buildPipeCollisionGame() async {
  final game = JsonFlameGame(
    spec: {
      'world': {'kind': 'pixel', 'width': 320, 'height': 180, 'bg': '#000000'},
      'entities': {
        'map': {
          'kind': 'tiled_map',
          'map_data': {
            'width': 40,
            'height': 20,
            'tilewidth': 8,
            'tileheight': 8,
            'layers': [
              {
                'type': 'objectgroup',
                'name': 'collider',
                'objects': [
                  {'id': 1, 'x': 100, 'y': 40, 'width': 32, 'height': 80},
                ],
              },
              {
                'type': 'objectgroup',
                'name': 'grounds',
                'objects': [
                  {'id': 2, 'x': 0, 'y': 120, 'width': 320, 'height': 24},
                ],
              },
            ],
          },
          'solid_layers': ['collider', 'grounds'],
          'collidable': true,
        },
        'player': {
          'kind': 'pixel',
          'position': [70, 88],
          'size': [20, 32],
          'velocity': [420, 0],
          'auto_update': false,
          'render': {'shape': 'rect', 'color': '#FFFFFF'},
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

  test('objectgroup collider blocks platformer horizontal movement', () async {
    final game = await _buildPipeCollisionGame();

    game.logic.runLogic([
      {
        'call': '@platformer.step',
        'args': {
          'id': 'player',
          'map': 'map',
          'dt': 0.25,
          'gravity': 0,
          'max_fall': 900,
        },
      },
    ]);

    final player = game.entities['player'] as PixelEntity;
    expect(player.x, 80);
    expect(player.state['blockedRight'], true);
    expect(player.state['xCollision']['layer'], 'collider');
    expect(player.state['xCollision']['type'], 'Solid');
  });

  test(
    'side contact with tall collider does not become a false landing',
    () async {
      final game = await _buildPipeCollisionGame();
      final player = game.entities['player'] as PixelEntity;
      player
        ..x = 70
        ..y = 70
        ..vx = 420
        ..vy = 180;

      game.logic.runLogic([
        {
          'call': '@platformer.step',
          'args': {
            'id': 'player',
            'map': 'map',
            'dt': 0.18,
            'gravity': 0,
            'max_fall': 900,
          },
        },
      ]);

      expect(player.x, 80);
      expect(player.state['blockedRight'], true);
      expect(player.state['onGroundCollision']?['layer'], isNot('collider'));
    },
  );
}
