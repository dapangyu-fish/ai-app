// Video 控件
// 基于 video_player + chewie 的跨平台视频播放器
// 支持：网络视频 (http/https/HLS) 和本地文件
// 支持属性：url/src, autoplay, looping, aspectRatio, width, height
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'base_widget.dart';
import '../../platform/local_media.dart';
import '../interpreter.dart';
import '../../i18n/framework_strings.dart';

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

    if (src.isEmpty) {
      return _fixedSizeBox(
        aspectRatio,
        width,
        height,
        borderRadius,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, size: 40, color: Colors.white54),
            const SizedBox(height: 8),
            Text(
              T.of(context).widgetVideoNoUrl,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return _fixedSizeBox(
      aspectRatio,
      width,
      height,
      borderRadius,
      _VideoPlayerStateful(
        key: ValueKey(src),
        src: src,
        autoplay: autoplay,
        looping: looping,
        aspectRatio: aspectRatio,
      ),
    );
  }

  /// 用 LayoutBuilder + AspectRatio 确保视频区域在 ScrollView 中有固定尺寸
  Widget _fixedSizeBox(
    double aspectRatio,
    double? width,
    double? height,
    double borderRadius,
    Widget child,
  ) {
    Widget box = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: borderRadius > 0
                ? BorderRadius.circular(borderRadius)
                : null,
          ),
          clipBehavior: borderRadius > 0 ? Clip.antiAlias : Clip.none,
          child: child,
        ),
      ),
    );
    if (width != null || height != null) {
      box = SizedBox(width: width, height: height, child: box);
    }
    return box;
  }
}

/// 有状态的视频播放器，管理 controller 生命周期
class _VideoPlayerStateful extends StatefulWidget {
  final String src;
  final bool autoplay;
  final bool looping;
  final double aspectRatio;

  const _VideoPlayerStateful({
    super.key,
    required this.src,
    required this.autoplay,
    required this.looping,
    required this.aspectRatio,
  });

  @override
  State<_VideoPlayerStateful> createState() => _VideoPlayerStatefulState();
}

class _VideoPlayerStatefulState extends State<_VideoPlayerStateful> {
  VideoPlayerController? _videoController;
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
      debugPrint('[JSON DSL Video] 正在初始化: $src');

      VideoPlayerController controller;

      if (src.startsWith('http://') || src.startsWith('https://')) {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(src),
          httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
        );
      } else if (!kIsWeb) {
        controller = localFileVideoController(src);
      } else {
        if (mounted) {
          setState(() => _error = T.current.widgetVideoUnsupportedSource);
        }
        return;
      }

      _videoController = controller;

      await controller.initialize();
      debugPrint(
        '[JSON DSL Video] 初始化成功: '
        '${controller.value.size.width}x${controller.value.size.height}, '
        '时长: ${controller.value.duration}',
      );

      if (!mounted) {
        controller.dispose();
        return;
      }

      _chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: widget.autoplay,
        looping: widget.looping,
        aspectRatio: widget.aspectRatio,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: true,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, color: Colors.redAccent, size: 36),
                const SizedBox(height: 8),
                Text(
                  T.fmt(T.of(context).widgetVideoPlaybackFailedWith, {
                    'err': errorMessage,
                  }),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          );
        },
      );

      setState(() => _isInitialized = true);
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
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                T.fmt(T.of(context).widgetVideoLoadFailedWith, {
                  'err': _error ?? '',
                }),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _error = null;
                  _isInitialized = false;
                });
                _chewieController?.dispose();
                _videoController?.dispose();
                _videoController = null;
                _chewieController = null;
                _initPlayer();
              },
              icon: const Icon(Icons.refresh, color: Colors.white70, size: 16),
              label: Text(
                T.of(context).retry,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    if (!_isInitialized || _chewieController == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white70,
            ),
            const SizedBox(height: 12),
            Text(
              T.of(context).widgetVideoLoading,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Chewie(controller: _chewieController!);
  }
}
