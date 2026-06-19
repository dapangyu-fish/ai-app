import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/json_ui/interpreter.dart';
import 'package:myapp/json_ui/widgets/flame_game_widget.dart';

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
}
