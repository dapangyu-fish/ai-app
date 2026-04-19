// Image 控件 — 增强版
// 支持三种来源：
//   1. 网络图片 (http:// / https://)
//   2. 本地文件 (绝对路径 / 变量绑定)
//   3. Base64 字符串 (data:image 或纯 base64)
// 支持格式：PNG、JPG、GIF（GIF 自动播放）
// 支持属性：url/src, fit, width, height, borderRadius
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonImageWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    // 支持 url 和 src 两种字段名
    final rawSrc = (json['url'] ?? json['src'] ?? '').toString();
    final src = interpreter.resolveTemplate(rawSrc);
    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 0;

    // fit
    BoxFit fit = BoxFit.cover;
    switch (json['fit']?.toString()) {
      case 'contain':
        fit = BoxFit.contain;
        break;
      case 'fill':
        fit = BoxFit.fill;
        break;
      case 'fitWidth':
        fit = BoxFit.fitWidth;
        break;
      case 'fitHeight':
        fit = BoxFit.fitHeight;
        break;
      case 'none':
        fit = BoxFit.none;
        break;
      case 'scaleDown':
        fit = BoxFit.scaleDown;
        break;
    }

    if (src.isEmpty) {
      return SizedBox(
        width: width,
        height: height ?? 100,
        child: Center(
          child: Icon(Icons.image_not_supported,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    Widget image = _buildImage(src, width, height, fit, context);

    if (borderRadius > 0) {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: image,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: image,
    );
  }

  Widget _buildImage(
    String src,
    double? width,
    double? height,
    BoxFit fit,
    BuildContext context,
  ) {
    // 1. Base64
    if (src.startsWith('data:image')) {
      final parts = src.split(',');
      if (parts.length > 1) {
        return _base64Image(parts[1], width, height, fit, context);
      }
    }
    if (_isBase64(src)) {
      return _base64Image(src, width, height, fit, context);
    }

    // 2. 网络图片
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return Image.network(
        src,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) => _errorWidget(width, height, context),
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return _loadingWidget(width, height, progress, context);
        },
      );
    }

    // 3. 本地文件
    if (!kIsWeb) {
      final file = File(src);
      return Image.file(
        file,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) => _errorWidget(width, height, context),
      );
    }

    return _errorWidget(width, height, context);
  }

  Widget _base64Image(
    String base64Str,
    double? width,
    double? height,
    BoxFit fit,
    BuildContext context,
  ) {
    try {
      final bytes = base64Decode(base64Str);
      return Image.memory(
        bytes,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) => _errorWidget(width, height, context),
      );
    } catch (_) {
      return _errorWidget(width, height, context);
    }
  }

  bool _isBase64(String str) {
    if (str.length < 20) return false;
    final base64Regex = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
    return base64Regex.hasMatch(str);
  }

  Widget _errorWidget(double? width, double? height, BuildContext context) {
    return Container(
      width: width,
      height: height ?? 100,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.broken_image,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _loadingWidget(
    double? width,
    double? height,
    ImageChunkEvent progress,
    BuildContext context,
  ) {
    return Container(
      width: width,
      height: height ?? 100,
      alignment: Alignment.center,
      child: CircularProgressIndicator(
        value: progress.expectedTotalBytes != null
            ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
            : null,
        strokeWidth: 2,
      ),
    );
  }
}
