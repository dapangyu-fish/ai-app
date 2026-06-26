import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/json_ui/interpreter.dart';

void main() {
  test('ref props jsonlogic can provide defaults', () {
    final interpreter = JsonInterpreter();

    final rule = {
      'or': [
        {'var': 'props.moveEndInput'},
        {'var': 'props.moveInput'},
      ],
    };

    expect(
      interpreter.evaluateJsonLogicWithLocals(rule, {
        'props': {'moveInput': 'move_axis'},
      }),
      'move_axis',
    );
    expect(
      interpreter.evaluateJsonLogicWithLocals(rule, {
        'props': {'moveInput': 'move_axis', 'moveEndInput': 'stop_axis'},
      }),
      'stop_axis',
    );
  });

  test('ref props jsonlogic supports var default values', () {
    final interpreter = JsonInterpreter();

    final rule = {
      'var': ['props.moveEndInput', 'move_axis'],
    };

    expect(
      interpreter.evaluateJsonLogicWithLocals(rule, {
        'props': <String, Object?>{},
      }),
      'move_axis',
    );
    expect(
      interpreter.evaluateJsonLogicWithLocals(rule, {
        'props': {'moveEndInput': 'stop_axis'},
      }),
      'stop_axis',
    );
  });
}
