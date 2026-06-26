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
  static ValueNotifier<String>? _activeToastMessage;
  static Timer? _activeToastTimer;

  DateTime? _firstTapAt;
  int _tapCount = 0;

  static void _removeActiveToast({OverlayEntry? ifEntry}) {
    _activeToastTimer?.cancel();
    _activeToastTimer = null;

    final entry = _activeToastEntry;
    if (ifEntry != null && entry != ifEntry) return;
    _activeToastEntry = null;

    final message = _activeToastMessage;
    _activeToastMessage = null;
    message?.dispose();

    if (entry?.mounted == true) {
      entry!.remove();
    }
  }

  void _showUnlockToast(String message) {
    _activeToastTimer?.cancel();
    _activeToastTimer = null;

    if (_activeToastEntry?.mounted == true && _activeToastMessage != null) {
      final entry = _activeToastEntry;
      _activeToastMessage!.value = message;
      _activeToastTimer = Timer(
        _toastDuration,
        () => _removeActiveToast(ifEntry: entry),
      );
      return;
    }

    _removeActiveToast();

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null || !mounted) return;

    final messageNotifier = ValueNotifier<String>(message);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: const Alignment(0, 0.62),
              child: Material(
                color: Colors.transparent,
                child: ValueListenableBuilder<String>(
                  valueListenable: messageNotifier,
                  builder: (context, text, _) {
                    final theme = Theme.of(context);
                    final textStyle = theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    );
                    return ConstrainedBox(
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
                            text,
                            style: textStyle,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    _activeToastEntry = entry;
    _activeToastMessage = messageNotifier;
    _activeToastTimer = Timer(
      _toastDuration,
      () => _removeActiveToast(ifEntry: entry),
    );
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
      _removeActiveToast();
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
