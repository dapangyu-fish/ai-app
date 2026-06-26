import 'package:flutter/material.dart';
import 'package:rive/rive.dart' as rive;

import '../interpreter.dart';
import 'base_widget.dart';

class JsonRiveAnimationWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawSrc = (json['src'] ?? json['url'] ?? json['asset'] ?? '')
        .toString();
    final src = interpreter.resolveTemplate(rawSrc);
    if (src.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget child = _RiveAnimationView(
      src: src,
      fit: _parseFit(json['fit']?.toString()),
      alignment: _parseAlignment(json['alignment']?.toString()),
      renderer: json['renderer']?.toString(),
      layoutScaleFactor:
          _resolveDouble(interpreter, json['layoutScaleFactor']) ?? 1,
    );
    final width = _resolveDouble(interpreter, json['width']);
    final height = _resolveDouble(interpreter, json['height']);
    if (width != null || height != null) {
      child = SizedBox(width: width, height: height, child: child);
    }
    return child;
  }

  rive.Fit _parseFit(String? value) {
    return switch (value) {
      'cover' => rive.Fit.cover,
      'fill' => rive.Fit.fill,
      'fitWidth' => rive.Fit.fitWidth,
      'fitHeight' => rive.Fit.fitHeight,
      'none' => rive.Fit.none,
      'scaleDown' => rive.Fit.scaleDown,
      'layout' => rive.Fit.layout,
      _ => rive.Fit.contain,
    };
  }

  Alignment _parseAlignment(String? value) {
    return switch (value) {
      'topLeft' => Alignment.topLeft,
      'topCenter' => Alignment.topCenter,
      'topRight' => Alignment.topRight,
      'centerLeft' => Alignment.centerLeft,
      'centerRight' => Alignment.centerRight,
      'bottomLeft' => Alignment.bottomLeft,
      'bottomCenter' => Alignment.bottomCenter,
      'bottomRight' => Alignment.bottomRight,
      _ => Alignment.center,
    };
  }

  double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final resolved = interpreter.resolveExpression(value);
    if (resolved is num) return resolved.toDouble();
    return double.tryParse(resolved?.toString() ?? '');
  }
}

class _RiveAnimationView extends StatefulWidget {
  final String src;
  final rive.Fit fit;
  final Alignment alignment;
  final String? renderer;
  final double layoutScaleFactor;

  const _RiveAnimationView({
    required this.src,
    required this.fit,
    required this.alignment,
    required this.renderer,
    required this.layoutScaleFactor,
  });

  @override
  State<_RiveAnimationView> createState() => _RiveAnimationViewState();
}

class _RiveAnimationViewState extends State<_RiveAnimationView> {
  late rive.FileLoader _loader;
  rive.RiveWidgetController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loader = _createLoader();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RiveAnimationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src || oldWidget.renderer != widget.renderer) {
      _controller?.dispose();
      _controller = null;
      _loader.dispose();
      _loader = _createLoader();
      _failed = false;
      _load();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _loader.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_isWidgetTest && widget.src.startsWith('http')) {
      setState(() => _failed = true);
      return;
    }
    try {
      final file = await _loader.file();
      if (!mounted) return;
      final controller = rive.RiveWidgetController(file);
      setState(() {
        _controller?.dispose();
        _controller = controller;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _controller?.dispose();
        _controller = null;
        _failed = true;
      });
    }
  }

  bool get _isWidgetTest {
    final bindingType = WidgetsBinding.instance.runtimeType.toString();
    return bindingType.contains('TestWidgetsFlutterBinding');
  }

  rive.FileLoader _createLoader() {
    final factory = widget.renderer == 'rive'
        ? rive.Factory.rive
        : rive.Factory.flutter;
    if (widget.src.startsWith('http://') || widget.src.startsWith('https://')) {
      return rive.FileLoader.fromUrl(widget.src, riveFactory: factory);
    }
    return rive.FileLoader.fromAsset(widget.src, riveFactory: factory);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) {
      return rive.RiveWidget(
        controller: controller,
        fit: widget.fit,
        alignment: widget.alignment,
        layoutScaleFactor: widget.layoutScaleFactor,
      );
    }
    if (_failed) return const SizedBox.shrink();
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}
