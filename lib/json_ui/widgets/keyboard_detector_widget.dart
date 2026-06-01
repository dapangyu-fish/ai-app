import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonKeyboardDetectorWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final childJson = json['child'];
    return _KeyboardDetector(
      bind: json['bind']?.toString(),
      interpreter: interpreter,
      child: childJson is Map<String, dynamic>
          ? interpreter.buildWidget(context, childJson)
          : const SizedBox.shrink(),
    );
  }
}

class _KeyboardDetector extends StatefulWidget {
  final String? bind;
  final JsonInterpreter interpreter;
  final Widget child;

  const _KeyboardDetector({
    required this.bind,
    required this.interpreter,
    required this.child,
  });

  @override
  State<_KeyboardDetector> createState() => _KeyboardDetectorState();
}

class _KeyboardDetectorState extends State<_KeyboardDetector>
    with WidgetsBindingObserver {
  bool? _lastVisible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(covariant _KeyboardDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final bind = widget.bind;
    if (bind == null || bind.isEmpty) return;
    final visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_lastVisible == visible) return;
    _lastVisible = visible;
    widget.interpreter.setVariable(bind, visible);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
