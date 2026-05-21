import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

// Web 无本地文件访问。这两个函数只在 kIsWeb==false 分支调用，web 上永远不会执行到，
// 抛异常仅为满足类型/编译要求。web 上的图片/视频走网络 URL 分支。
ImageProvider localFileImage(String path) =>
    throw UnsupportedError('localFileImage 在 web 上不可用');

VideoPlayerController localFileVideoController(String path) =>
    throw UnsupportedError('localFileVideoController 在 web 上不可用');
