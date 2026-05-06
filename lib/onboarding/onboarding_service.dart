import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'onboarding_overlay.dart';
import 'onboarding_step.dart';

/// 新手引导（coachmark）状态管理 + 公开 API。
///
/// 不变量：
/// - 一次只能跑一个引导（_isShowing 加锁）
/// - "见过" 标记 per-device（SharedPreferences），不上 server
/// - 版本号 v1 留着以后内容大改时强制重弹（v2_seen）
class OnboardingService {
  OnboardingService._();

  /// 改这里的版本号 = 让所有用户重看一次新手引导
  static const String _seenKey = 'onboarding_coachmark_v1_seen';

  static bool _isShowing = false;

  /// 第一次到主页时调一次。`hasSeen` true 直接返回，不打扰老用户。
  static Future<void> maybeStart(
    BuildContext context, {
    List<OnboardingStep>? steps,
  }) async {
    if (_isShowing) return;
    final seen = await hasSeen();
    if (seen) return;
    if (!context.mounted) return;
    await _start(context, steps: steps);
  }

  /// "再看一遍" 入口用：即使已 seen 也强制弹。
  static Future<void> forceStart(
    BuildContext context, {
    List<OnboardingStep>? steps,
  }) async {
    if (_isShowing) return;
    if (!context.mounted) return;
    await _start(context, steps: steps);
  }

  static Future<void> _start(
    BuildContext context, {
    List<OnboardingStep>? steps,
  }) async {
    final list = steps ?? defaultOnboardingSteps();
    if (list.isEmpty) return;
    _isShowing = true;
    try {
      // 等一帧让目标 widget layout 稳定，避免 RenderBox 还没有 size
      await WidgetsBinding.instance.endOfFrame;
      if (!context.mounted) return;

      // 至少要有一个目标 currently mounted；都没 mount 就跳过整个引导
      final mountedSteps = list.where((s) => s.targetKey.currentContext != null).toList();
      if (mountedSteps.isEmpty) {
        debugPrint('[Onboarding] 所有目标都未 mount，跳过引导');
        return;
      }
      if (mountedSteps.length < list.length) {
        debugPrint('[Onboarding] 部分目标未 mount: '
            '${list.where((s) => s.targetKey.currentContext == null).map((s) => s.targetKey.toString()).toList()}');
      }

      // 阻塞等用户走完 / 跳过
      await OnboardingOverlay.show(context, mountedSteps);
      await markSeen();
    } finally {
      _isShowing = false;
    }
  }

  static Future<bool> hasSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_seenKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
    } catch (e) {
      debugPrint('[Onboarding] markSeen 失败: $e');
    }
  }

  /// 调试 / "再看一遍" 用：把 seen 标记擦掉，下次冷启动会重新弹。
  static Future<void> reset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_seenKey);
    } catch (_) {}
  }
}
