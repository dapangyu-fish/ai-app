// Image 控件
// 支持 url (网络图片), fit, width, height, borderRadius
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
    final url = interpreter.resolveTemplate(
      (json['url'] ?? '').toString(),
    );
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

    if (url.isEmpty) {
      return const SizedBox.shrink();
    }

    Widget image = Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => Container(
        width: width,
        height: height ?? 100,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.broken_image,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height ?? 100,
          alignment: Alignment.center,
          child: CircularProgressIndicator(
            value: progress.expectedTotalBytes != null
                ? progress.cumulativeBytesLoaded /
                    progress.expectedTotalBytes!
                : null,
            strokeWidth: 2,
          ),
        );
      },
    );

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
}
