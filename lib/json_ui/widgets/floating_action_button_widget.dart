import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';

class JsonFloatingActionButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final label = interpreter.resolveTemplate(json['label']?.toString() ?? '');
    final action =
        resolveActionAtBuildTime(json['action'], interpreter)
            as Map<String, dynamic>?;
    return FloatingActionButton(
      onPressed: action == null
          ? null
          : () => interpreter.executeAction(action, context),
      child: label.isEmpty ? null : Text(label),
    );
  }
}
