import 'dart:async';

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
  static const Duration _toastDuration = Duration(milliseconds: 850);
  static OverlayEntry? _activeToastEntry;
  static Timer? _activeToastTimer;

  DateTime? _firstTapAt;
  int _tapCount = 0;

  void _showUnlockToast(String message) {
    _activeToastTimer?.cancel();
    _activeToastTimer = null;
    _activeToastEntry?.remove();
    _activeToastEntry = null;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final entry = OverlayEntry(
      builder: (context) {
        final theme = Theme.of(context);
        final textStyle = theme.textTheme.bodyMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        );
        return IgnorePointer(
          child: Positioned.fill(
            child: SafeArea(
              minimum: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: const Alignment(0, 0.62),
                child: Material(
                  color: Colors.transparent,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 11,
                        ),
                        child: Text(
                          message,
                          style: textStyle,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    _activeToastEntry = entry;
    _activeToastTimer = Timer(_toastDuration, () {
      if (_activeToastEntry == entry) {
        _activeToastEntry = null;
      }
      if (entry.mounted) {
        entry.remove();
      }
    });
  }

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
      _activeToastTimer?.cancel();
      _activeToastTimer = null;
      _activeToastEntry?.remove();
      _activeToastEntry = null;
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const EnvironmentPage()));
      return;
    }
    if (remaining <= 3) {
      _showUnlockToast('再点 $remaining 下解锁服务环境');
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
