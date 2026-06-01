import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonFloatingTouchDemoWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return const Center(child: _FloatingTouchLauncher());
  }
}

class _FloatingTouchLauncher extends StatefulWidget {
  const _FloatingTouchLauncher();

  @override
  State<_FloatingTouchLauncher> createState() => _FloatingTouchLauncherState();
}

class _FloatingTouchLauncherState extends State<_FloatingTouchLauncher> {
  Offset _offset = const Offset(200, 200);
  static const double _size = 80;
  OverlayEntry? _entry;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(onPressed: _showFloating, child: const Text('显示悬浮'));
  }

  void _showFloating() {
    if (_entry != null) return;
    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned(
            left: _offset.dx,
            top: _offset.dy,
            child: _floatingControl(),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  Widget _floatingControl() {
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onPanDown: (details) {
        _offset = details.globalPosition - const Offset(_size / 2, _size / 2);
        _entry?.markNeedsBuild();
      },
      onPanUpdate: (details) {
        _offset += details.delta;
        _entry?.markNeedsBuild();
      },
      onLongPress: () {
        _entry?.remove();
        _entry = null;
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: _size,
          width: _size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.redAccent,
            borderRadius: BorderRadius.all(Radius.circular(_size / 2)),
          ),
          child: const Text(
            '长按\n移除',
            style: TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
