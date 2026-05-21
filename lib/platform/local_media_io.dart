import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

/// 本地文件图片的 ImageProvider。
ImageProvider localFileImage(String path) => FileImage(File(path));

/// 本地文件视频控制器。
VideoPlayerController localFileVideoController(String path) =>
    VideoPlayerController.file(File(path));
