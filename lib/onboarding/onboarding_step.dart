import 'package:flutter/widgets.dart';

import '../i18n/framework_strings.dart';
import 'onboarding_keys.dart';

/// 单个引导步骤的数据。
///
/// titleOf / bodyOf 是函数而不是字符串：本地化随 [appLocale] 切换时，
/// build() 重新读 T.current.* 即可拿到对应语言的最新文案，不需要重建 step。
class OnboardingStep {
  final GlobalKey targetKey;
  final String Function(FrameworkStrings t) titleOf;
  final String Function(FrameworkStrings t) bodyOf;

  /// spotlight 切口的额外 padding（避免紧贴目标边缘）
  final double padding;

  /// spotlight 形状：圆形（设计师球）或圆角矩形（卡片、按钮）
  final OnboardingShape shape;

  const OnboardingStep({
    required this.targetKey,
    required this.titleOf,
    required this.bodyOf,
    this.padding = 8,
    this.shape = OnboardingShape.roundedRect,
  });
}

enum OnboardingShape { circle, roundedRect }

/// 引导的步骤序列。改顺序 / 加步骤直接动这里就行。
List<OnboardingStep> defaultOnboardingSteps() => [
      OnboardingStep(
        targetKey: OnboardingKeys.designerBall,
        titleOf: (t) => t.onboardingStep1Title,
        bodyOf: (t) => t.onboardingStep1Body,
        shape: OnboardingShape.circle,
        padding: 6,
      ),
      OnboardingStep(
        targetKey: OnboardingKeys.userMenu,
        titleOf: (t) => t.onboardingStep2Title,
        bodyOf: (t) => t.onboardingStep2Body,
        shape: OnboardingShape.circle,
        padding: 4,
      ),
      OnboardingStep(
        targetKey: OnboardingKeys.marketCard,
        titleOf: (t) => t.onboardingStep3Title,
        bodyOf: (t) => t.onboardingStep3Body,
      ),
      OnboardingStep(
        targetKey: OnboardingKeys.myAppsCard,
        titleOf: (t) => t.onboardingStep4Title,
        bodyOf: (t) => t.onboardingStep4Body,
      ),
      OnboardingStep(
        targetKey: OnboardingKeys.messagesCard,
        titleOf: (t) => t.onboardingStep5Title,
        bodyOf: (t) => t.onboardingStep5Body,
      ),
    ];
