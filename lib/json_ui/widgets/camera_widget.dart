// Camera 控件 — 实时预览
// 支持: lensDirection (back/front, 默认 back), height (默认 300),
//       resolution (low/medium/high/veryHigh, 默认 medium),
//       onCapture (action) — 当前 widget 不主动捕获，只显示预览
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
    final height = (json['height'] as num?)?.toDouble() ?? 300;
    final width = (json['width'] as num?)?.toDouble();
    final resolution = _parseResolution(json['resolution']?.toString());

    return SizedBox(
      width: width,
      height: height,
      child: _CameraPreview(lens: lens, resolution: resolution),
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
}

class _CameraPreview extends StatefulWidget {
  final CameraLensDirection lens;
  final ResolutionPreset resolution;

  const _CameraPreview({required this.lens, required this.resolution});

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
        setState(() => _error = '无可用相机');
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return CameraPreview(_controller!);
  }
}
