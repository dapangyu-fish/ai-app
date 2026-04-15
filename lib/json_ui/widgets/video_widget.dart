// Video 控件
// 基于 video_player + chewie 的跨平台视频播放器
// 支持：网络视频 (http/https/HLS) 和本地文件
// 支持属性：url/src, autoplay, looping, aspectRatio, width, height
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonVideoWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawSrc = (json['url'] ?? json['src'] ?? '').toString();
    final src = interpreter.resolveTemplate(rawSrc);
    final autoplay = json['autoplay'] == true;
    final looping = json['looping'] == true;
    final aspectRatio = (json['aspectRatio'] as num?)?.toDouble() ?? 16 / 9;
    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 0;
    final placeholder = json['placeholder']?.toString();

    if (src.isEmpty) {
      return _placeholderWidget(width, height, '未配置视频地址', context);
    }

    Widget player = _VideoPlayerStateful(
      key: ValueKey(src),
      src: src,
      autoplay: autoplay,
      looping: looping,
      aspectRatio: aspectRatio,
      placeholder: placeholder,
    );

    if (width != null || height != null) {
      player = SizedBox(width: width, height: height, child: player);
    }

    if (borderRadius > 0) {
      player = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: player,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: player,
    );
  }

  Widget _placeholderWidget(
      double? width, double? height, String text, BuildContext context) {
    return Container(
      width: width,
      height: height ?? 200,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, size: 40, color: Colors.white54),
            const SizedBox(height: 8),
            Text(text,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// 有状态的视频播放器，管理 controller 生命周期
class _VideoPlayerStateful extends StatefulWidget {
  final String src;
  final bool autoplay;
  final bool looping;
  final double aspectRatio;
  final String? placeholder;

  const _VideoPlayerStateful({
    super.key,
    required this.src,
    required this.autoplay,
    required this.looping,
    required this.aspectRatio,
    this.placeholder,
  });

  @override
  State<_VideoPlayerStateful> createState() => _VideoPlayerStatefulState();
}

class _VideoPlayerStatefulState extends State<_VideoPlayerStateful> {
  late VideoPlayerController _videoController;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final src = widget.src;

      if (src.startsWith('http://') || src.startsWith('https://')) {
        _videoController = VideoPlayerController.networkUrl(Uri.parse(src));
      } else if (!kIsWeb) {
        _videoController = VideoPlayerController.file(File(src));
      } else {
        setState(() => _error = '不支持的视频来源');
        return;
      }

      await _videoController.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoController,
        autoPlay: widget.autoplay,
        looping: widget.looping,
        aspectRatio: widget.aspectRatio,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: true,
        placeholder: widget.placeholder != null
            ? Center(
                child: Text(widget.placeholder!,
                    style: const TextStyle(color: Colors.white54)))
            : null,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, color: Colors.redAccent, size: 36),
                const SizedBox(height: 8),
                Text('播放失败: $errorMessage',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          );
        },
      );

      if (mounted) {
        setState(() => _isInitialized = true);
      }
    } catch (e) {
      debugPrint('[JSON DSL Video] 初始化失败: $e');
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        color: Colors.black87,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '视频加载失败',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialized || _chewieController == null) {
      return Container(
        color: Colors.black87,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
              SizedBox(height: 12),
              Text('加载中...', style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    return Chewie(controller: _chewieController!);
  }
}
