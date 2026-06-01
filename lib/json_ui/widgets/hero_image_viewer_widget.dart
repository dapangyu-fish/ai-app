import 'package:flutter/material.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonHeroImageViewerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawSrc = (json['url'] ?? json['src'] ?? '').toString();
    final src = interpreter.resolveTemplate(rawSrc);
    return _HeroImageViewer(
      src: src,
      tag: json['tag']?.toString() ?? 'image',
      width: (json['width'] as num?)?.toDouble() ?? 100,
      height: (json['height'] as num?)?.toDouble() ?? 100,
    );
  }
}

class _HeroImageViewer extends StatelessWidget {
  final String src;
  final String tag;
  final double width;
  final double height;

  const _HeroImageViewer({
    required this.src,
    required this.tag,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _open(context),
      child: Hero(tag: tag, child: _image(src, width, height)),
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        fullscreenDialog: true,
        pageBuilder: (context, animation, secondaryAnimation) {
          final screenWidth = MediaQuery.sizeOf(context).width;
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: InkWell(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                alignment: Alignment.center,
                child: Hero(
                  tag: tag,
                  child: _image(src, screenWidth, screenWidth),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _image(String source, double width, double height) {
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return Image.network(
        source,
        width: width,
        height: height,
        fit: BoxFit.cover,
      );
    }
    return Image.asset(source, width: width, height: height, fit: BoxFit.cover);
  }
}
