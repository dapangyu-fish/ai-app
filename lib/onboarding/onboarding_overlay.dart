import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/framework_strings.dart';
import 'onboarding_step.dart';

/// 新手引导聚光灯 overlay。Stack 三层：
/// 1. 半透明黑蒙层（CustomPaint 用 evenOdd path 在目标处切圆角矩形/圆形透明洞）
/// 2. 透明的 GestureDetector 吃掉所有点击（防止用户误触下面的真实按钮）
/// 3. tooltip 卡片（标题 / 正文 / 步骤指示器 / 跳过 / 下一步）
///
/// 不变量：
/// - 唯一 entrypoint：[show]，返回的 Future 在用户走完 / 点跳过 / 异常时完成
/// - 目标 widget 中途 unmount（路由跳转）→ 该步自动 skip 到下一步，不画虚框
class OnboardingOverlay {
  OnboardingOverlay._();

  /// 弹出引导，等用户走完 / 跳过后 future 完成。
  static Future<void> show(
    BuildContext context,
    List<OnboardingStep> steps,
  ) {
    final overlayState = Overlay.of(context, rootOverlay: true);
    final completer = Completer<void>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _OverlayHost(
        steps: steps,
        onDone: () {
          if (entry.mounted) entry.remove();
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    overlayState.insert(entry);
    return completer.future;
  }
}

class _OverlayHost extends StatefulWidget {
  final List<OnboardingStep> steps;
  final VoidCallback onDone;

  const _OverlayHost({required this.steps, required this.onDone});

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost> with SingleTickerProviderStateMixin {
  int _index = 0;
  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..forward();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _advance() {
    if (_index < widget.steps.length - 1) {
      setState(() => _index += 1);
    } else {
      _close();
    }
  }

  void _skip() => _close();

  void _close() {
    _fade.reverse().whenComplete(widget.onDone);
  }

  /// 目标 widget 的全局矩形；widget 已 unmount / 没 attach → null
  Rect? _rectOfStep(OnboardingStep step) {
    final ctx = step.targetKey.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return null;
    final origin = ro.localToGlobal(Offset.zero);
    return origin & ro.size;
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_index];
    final rect = _rectOfStep(step);

    // 当前步目标失踪：自动推进到下一步
    if (rect == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_index < widget.steps.length - 1) {
          setState(() => _index += 1);
        } else {
          _close();
        }
      });
      return const SizedBox.shrink();
    }

    final mq = MediaQuery.of(context);
    final t = T.of(context);
    final cs = Theme.of(context).colorScheme;

    return FadeTransition(
      opacity: _fade,
      child: Material(
        color: Colors.transparent,
        // 蒙层吃掉所有点击；放在外层而不是放在 Stack 第一层是因为：
        // GestureDetector 的 onTap 必须能盖住整个屏幕，但又要让 tooltip 上的
        // 按钮能正常工作 —— 用 Stack 嵌套：外层 GD 吃 misc 点击，按钮在上层
        // 自然 hit-test 优先。
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {}, // swallow
          child: Stack(
            children: [
              // 1. 蒙层 + 切口
              Positioned.fill(
                child: CustomPaint(
                  painter: _SpotlightPainter(
                    rect: rect.inflate(step.padding),
                    shape: step.shape,
                    bg: Colors.black.withValues(alpha: 0.72),
                  ),
                ),
              ),

              // 2. tooltip
              ..._buildTooltip(context, mq, t, cs, step, rect),
            ],
          ),
        ),
      ),
    );
  }

  /// tooltip 自动选位置：目标在屏幕上半 → tooltip 在下方；下半 → 上方。
  /// 水平方向尽量居中目标，但留 16px 屏幕边距。
  List<Widget> _buildTooltip(
    BuildContext ctx,
    MediaQueryData mq,
    FrameworkStrings t,
    ColorScheme cs,
    OnboardingStep step,
    Rect rect,
  ) {
    final screen = mq.size;
    const margin = 16.0;
    const tooltipMaxWidth = 320.0;
    const arrowGap = 14.0; // tooltip 和 spotlight 之间的距离

    final targetCenterY = rect.center.dy;
    final showBelow = targetCenterY < screen.height / 2;
    final tooltipWidth = (screen.width - margin * 2).clamp(0.0, tooltipMaxWidth);

    return [
      Positioned(
        top: showBelow ? rect.bottom + arrowGap : null,
        bottom: showBelow ? null : screen.height - rect.top + arrowGap,
        left: ((rect.center.dx - tooltipWidth / 2)
            .clamp(margin, screen.width - tooltipWidth - margin))
            .toDouble(),
        width: tooltipWidth,
        child: SafeArea(
          minimum: const EdgeInsets.symmetric(horizontal: 0),
          child: _TooltipCard(
            title: step.titleOf(t),
            body: step.bodyOf(t),
            stepIndex: _index,
            stepTotal: widget.steps.length,
            onSkip: _skip,
            onNext: _advance,
            isLast: _index == widget.steps.length - 1,
            t: t,
            cs: cs,
          ),
        ),
      ),
    ];
  }
}

class _TooltipCard extends StatelessWidget {
  final String title;
  final String body;
  final int stepIndex;
  final int stepTotal;
  final bool isLast;
  final FrameworkStrings t;
  final ColorScheme cs;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  const _TooltipCard({
    required this.title,
    required this.body,
    required this.stepIndex,
    required this.stepTotal,
    required this.isLast,
    required this.t,
    required this.cs,
    required this.onSkip,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: cs.surface,
      elevation: 14,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                // 跳过按钮 —— 右上角小号、低对比，不抢主流程
                TextButton(
                  onPressed: onSkip,
                  style: TextButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(t.onboardingSkip, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  '${stepIndex + 1} / $stepTotal',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: onNext,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(72, 36),
                  ),
                  child: Text(isLast ? t.onboardingDone : t.onboardingNext),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 全屏黑蒙层 + evenOdd 切口。spotlight 处完全透明（露出真实 UI 让用户看清在指什么）。
class _SpotlightPainter extends CustomPainter {
  final Rect rect;
  final OnboardingShape shape;
  final Color bg;

  _SpotlightPainter({required this.rect, required this.shape, required this.bg});

  @override
  void paint(Canvas canvas, Size size) {
    final fullPath = Path()..addRect(Offset.zero & size);
    final cutoutPath = Path();

    if (shape == OnboardingShape.circle) {
      final radius = rect.shortestSide / 2 + 6;
      cutoutPath.addOval(Rect.fromCircle(center: rect.center, radius: radius));
    } else {
      cutoutPath.addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(14)));
    }

    final combined = Path.combine(PathOperation.difference, fullPath, cutoutPath);
    canvas.drawPath(combined, Paint()..color = bg);

    // 切口边缘的高亮线（让聚光更明显）
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    if (shape == OnboardingShape.circle) {
      final radius = rect.shortestSide / 2 + 6;
      canvas.drawCircle(rect.center, radius, stroke);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(14)),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter old) =>
      old.rect != rect || old.shape != shape || old.bg != bg;
}
