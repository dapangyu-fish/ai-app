import 'package:flutter/widgets.dart';

/// 新手引导聚光灯（coachmark）目标 widget 的 GlobalKey 注册表。
///
/// 用法：把这里导出的 key 挂到对应 widget 上（key: OnboardingKeys.designerBall）。
/// OnboardingService.maybeStart 会从这里读出 currentContext / RenderBox 算出
/// 目标矩形，画 spotlight 切口。
///
/// 不变量：每个 key 同一时刻**至多挂在一个 widget 上**。如果引导途中 widget
/// 被 unmount（路由跳转），currentContext 会变 null，OnboardingOverlay 自动
/// 跳过该步骤而不是画虚框。
class OnboardingKeys {
  OnboardingKeys._();

  static final GlobalKey designerBall =
      GlobalKey(debugLabel: 'onboarding.designerBall');
  static final GlobalKey userMenu =
      GlobalKey(debugLabel: 'onboarding.userMenu');
  static final GlobalKey marketCard =
      GlobalKey(debugLabel: 'onboarding.marketCard');
  static final GlobalKey myAppsCard =
      GlobalKey(debugLabel: 'onboarding.myAppsCard');
  static final GlobalKey messagesCard =
      GlobalKey(debugLabel: 'onboarding.messagesCard');
}
