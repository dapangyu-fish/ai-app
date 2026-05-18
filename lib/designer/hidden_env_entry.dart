import 'package:flutter/material.dart';

import 'environment_page.dart';

/// 把 child 包起来，连点 7 下（3 秒窗口）跳到 [EnvironmentPage]。
/// 登录页和设置页共用，避免到处复制计数逻辑。
class HiddenEnvEntry extends StatefulWidget {
  final Widget child;
  const HiddenEnvEntry({super.key, required this.child});

  @override
  State<HiddenEnvEntry> createState() => _HiddenEnvEntryState();
}

class _HiddenEnvEntryState extends State<HiddenEnvEntry> {
  static const int _unlockTaps = 7;
  static const Duration _resetWindow = Duration(seconds: 3);

  DateTime? _firstTapAt;
  int _tapCount = 0;

  void _onTap() {
    final now = DateTime.now();
    if (_firstTapAt == null || now.difference(_firstTapAt!) > _resetWindow) {
      _firstTapAt = now;
      _tapCount = 1;
      return;
    }
    _tapCount++;
    final remaining = _unlockTaps - _tapCount;
    if (remaining <= 0) {
      _tapCount = 0;
      _firstTapAt = null;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const EnvironmentPage()),
      );
      return;
    }
    if (remaining <= 3) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('再点 $remaining 下解锁服务环境'),
          duration: const Duration(milliseconds: 800),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: widget.child,
    );
  }
}
