// Skeleton 控件 — 加载占位（带 shimmer 渐变）
//
// 两种用法：
//   1) 自给尺寸：{ "type": "skeleton", "width": 200, "height": 16, "borderRadius": 4 }
//      —— 单条占位条，常用于文字行
//   2) 包装真实内容：{ "type": "skeleton", "loading": "{{ global.busy }}",
//                     "child": { ... 真实内容 ... } }
//      —— loading=true 时渲染 shimmer 灰条占位，loading=false 时直接渲染 child
//
// 不依赖外部包：自己实现 shimmer（线性渐变随时间向右扫描）
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonSkeletonWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final loadingRaw = json['loading'];
    bool loading = true;
    if (loadingRaw is bool) {
      loading = loadingRaw;
    } else if (loadingRaw is String) {
      final resolved = interpreter.resolveExpression(loadingRaw);
      loading = resolved == true || resolved == 'true';
    }

    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 4;
    final childJson = json['child'];

    // 模式 2：有 child + loading=false → 透传
    if (childJson is Map<String, dynamic> && !loading) {
      return interpreter.buildWidget(context, childJson);
    }

    // 模式 2：有 child + loading=true → 用 child 撑出形状再覆盖 shimmer
    if (childJson is Map<String, dynamic>) {
      return _Shimmer(
        borderRadius: borderRadius,
        child: IgnorePointer(
          // 占位时不让用户点真实 child
          child: Opacity(
            opacity: 0,
            child: interpreter.buildWidget(context, childJson),
          ),
        ),
      );
    }

    // 模式 1：自给尺寸的占位条
    return SizedBox(
      width: width,
      height: height ?? 16,
      child: _Shimmer(
        borderRadius: borderRadius,
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Shimmer extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  const _Shimmer({required this.child, required this.borderRadius});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor =
        isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0);
    final highlightColor =
        isDark ? const Color(0xFF3A3A3A) : const Color(0xFFF5F5F5);

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) {
              // 把 [-1, 1] 的进度映射成渐变中心位置（左→右扫过）
              final t = _controller.value * 2 - 0.5;
              return LinearGradient(
                begin: Alignment(t - 0.5, 0),
                end: Alignment(t + 0.5, 0),
                colors: [baseColor, highlightColor, baseColor],
                stops: const [0.0, 0.5, 1.0],
              ).createShader(bounds);
            },
            child: Container(color: Colors.white),
          );
        },
      ),
    );
  }
}
