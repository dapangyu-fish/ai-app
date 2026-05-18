// Camera 控件 — 实时预览
// 支持: lensDirection (back/front, 默认 back),
//       resolution (low/medium/high/veryHigh, 默认 medium),
//       width / height (可选),
//       fit (cover/contain, 默认 contain，仅在指定 width 或 height 时生效)
//
// 关键：CameraPreview 内部已经包了 AspectRatio。如果外层用 SizedBox 给两个维度
// 都设 tight constraints，AspectRatio 会失效，画面被拉伸压扁。
// 所以本控件区分两种模式：
//   1) 不指定 width / height：直接铺由 CameraPreview 的原生比例撑开
//   2) 指定了尺寸：用 FittedBox + 摄像头实际宽高比，按 fit 缩放（不压扁）
//
// 注意：需要平台权限
//   - Android: AndroidManifest.xml 添加 <uses-permission android:name="android.permission.CAMERA"/>
//   - iOS: Info.plist 添加 NSCameraUsageDescription
//
// 如果只需要"拍照然后存路径"，用 image_picker（source=camera）更简单。
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'base_widget.dart';
import '../interpreter.dart';
import '../../i18n/framework_strings.dart';

class JsonCameraWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final lensStr = json['lensDirection']?.toString() ?? 'back';
    final lens = lensStr == 'front'
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final height = (json['height'] as num?)?.toDouble();
    final width = (json['width'] as num?)?.toDouble();
    final resolution = _parseResolution(json['resolution']?.toString());
    final fit = _parseFit(json['fit']?.toString());

    return _CameraPreview(
      lens: lens,
      resolution: resolution,
      width: width,
      height: height,
      fit: fit,
    );
  }

  ResolutionPreset _parseResolution(String? s) {
    switch (s) {
      case 'low':
        return ResolutionPreset.low;
      case 'high':
        return ResolutionPreset.high;
      case 'veryHigh':
        return ResolutionPreset.veryHigh;
      case 'medium':
      default:
        return ResolutionPreset.medium;
    }
  }

  BoxFit _parseFit(String? s) {
    switch (s) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'contain':
      default:
        return BoxFit.contain;
    }
  }
}

class _CameraPreview extends StatefulWidget {
  final CameraLensDirection lens;
  final ResolutionPreset resolution;
  final double? width;
  final double? height;
  final BoxFit fit;

  const _CameraPreview({
    required this.lens,
    required this.resolution,
    required this.width,
    required this.height,
    required this.fit,
  });

  @override
  State<_CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<_CameraPreview> {
  CameraController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = T.current.widgetCameraNoCamera);
        return;
      }
      final selected = cams.firstWhere(
        (c) => c.lensDirection == widget.lens,
        orElse: () => cams.first,
      );
      final ctl = CameraController(selected, widget.resolution);
      await ctl.initialize();
      if (!mounted) {
        ctl.dispose();
        return;
      }
      setState(() => _controller = ctl);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _wrapBox(Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ));
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return _wrapBox(const Center(child: CircularProgressIndicator()));
    }

    // CameraPreview 自身用的是 controller.value.aspectRatio（横向），但当设备
    // 处于竖屏时，预览的实际宽高比应该取倒数。我们直接读取这个原生比例
    // 作为内层 SizedBox 的尺寸，再让 FittedBox 按 fit 缩放。
    final nativeAspect = _controller!.value.aspectRatio;
    final preview = CameraPreview(_controller!);

    // 模式 1：不指定尺寸——直接由 CameraPreview 内部 AspectRatio 撑开
    if (widget.width == null && widget.height == null) {
      return preview;
    }

    // 模式 2：指定了尺寸——FittedBox 缩放，保比例不变形
    // 内层用一个 nativeAspect 形状的盒子（任意尺寸都可以，FittedBox 只看比例）
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRect(
        child: FittedBox(
          fit: widget.fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: nativeAspect * 1000,
            height: 1000,
            child: preview,
          ),
        ),
      ),
    );
  }

  /// 错误 / 加载占位用：尽量贴合用户给的 width / height（没给就用一个合理默认）
  Widget _wrapBox(Widget child) {
    return SizedBox(
      width: widget.width,
      height: widget.height ?? (widget.width == null ? 240 : null),
      child: child,
    );
  }
}
