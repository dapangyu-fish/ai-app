import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'action_helper.dart';
import 'base_widget.dart';
import 'icon_registry.dart';

class JsonFloatingActionButtonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final label = interpreter.resolveTemplate(json['label']?.toString() ?? '');
    final rawIconName = json['icon']?.toString();
    final iconName = rawIconName == null
        ? null
        : interpreter.resolveTemplate(rawIconName);
    final iconData = iconName == null ? null : IconRegistry.get(iconName);
    final action =
        resolveActionAtBuildTime(json['action'], interpreter)
            as Map<String, dynamic>?;
    return FloatingActionButton(
      onPressed: action == null
          ? null
          : () => interpreter.executeAction(action, context),
      child: iconData != null
          ? Icon(iconData)
          : (label.isEmpty ? null : Text(label)),
    );
  }
}
