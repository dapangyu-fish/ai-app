import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../json_ui/compute/compute_session.dart';
import 'game_entity.dart';
import 'game_world.dart';

/// Generic renderer for a Compute VM byte buffer.
///
/// The entity deliberately knows nothing about the producer of the pixels.
/// Any JSON App can render an `indexed8` compute buffer by providing a palette.
final class FramebufferV2Entity extends GameEntity
    implements PostLogicGameEntity {
  FramebufferV2Entity({
    required super.id,
    required super.renderConfig,
    required this.computeSession,
    required this.bufferName,
    required this.format,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required List<int> palette,
    super.priority,
  }) : palette = List<int>.unmodifiable(palette),
       _decodeSlots = List<_FramebufferDecodeSlot>.generate(
         2,
         (_) => _FramebufferDecodeSlot(pixelWidth * pixelHeight),
       );

  final ComputeSession computeSession;
  final String bufferName;
  final String format;
  final int pixelWidth;
  final int pixelHeight;
  final double x;
  final double y;
  final double w;
  final double h;
  final List<int> palette;
  final List<_FramebufferDecodeSlot> _decodeSlots;

  ui.Image? _image;
  bool _disposed = false;
  int _decodedFrames = 0;
  int _nextSequence = 0;
  int _displayedSequence = -1;

  int get decodedFrames => _decodedFrames;

  @override
  void capturePostLogicFrame(GameWorld world) {
    if (_disposed) return;
    _FramebufferDecodeSlot? slot;
    for (final candidate in _decodeSlots) {
      if (!candidate.pending) {
        slot = candidate;
        break;
      }
    }
    if (slot == null) return;
    final decodeSlot = slot;

    final pixelCount = pixelWidth * pixelHeight;
    computeSession.copyU8BufferInto(
      bufferName,
      decodeSlot.indexed,
      length: pixelCount,
    );
    if (format != 'indexed8') {
      throw StateError(
        'framebuffer_v2 "$id" does not support format "$format"',
      );
    }
    if (palette.isEmpty) {
      throw StateError('framebuffer_v2 "$id" requires a non-empty palette');
    }

    for (
      var source = 0, target = 0;
      source < pixelCount;
      source++, target += 4
    ) {
      final color = palette[decodeSlot.indexed[source] % palette.length];
      decodeSlot.rgba[target] = (color >> 16) & 0xff;
      decodeSlot.rgba[target + 1] = (color >> 8) & 0xff;
      decodeSlot.rgba[target + 2] = color & 0xff;
      decodeSlot.rgba[target + 3] = (color >> 24) == 0
          ? 0xff
          : (color >> 24) & 0xff;
    }

    final sequence = _nextSequence++;
    decodeSlot.pending = true;
    ui.decodeImageFromPixels(
      decodeSlot.rgba,
      pixelWidth,
      pixelHeight,
      ui.PixelFormat.rgba8888,
      (decoded) {
        decodeSlot.pending = false;
        if (_disposed) {
          decoded.dispose();
          return;
        }
        if (sequence <= _displayedSequence) {
          decoded.dispose();
          return;
        }
        final previous = _image;
        _image = decoded;
        _displayedSequence = sequence;
        _decodedFrames++;
        previous?.dispose();
      },
      rowBytes: pixelWidth * 4,
    );
  }

  @override
  void render(Canvas canvas, GameWorld world) {
    final image = _image;
    if (image == null) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, pixelWidth.toDouble(), pixelHeight.toDouble()),
      Rect.fromLTWH(x, y, w, h),
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
  }

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'buffer': bufferName,
    'format': format,
    'width': pixelWidth,
    'height': pixelHeight,
    'position': <double>[x, y],
    'size': <double>[w, h],
    'decoded_frames': _decodedFrames,
  };

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _image?.dispose();
    _image = null;
  }
}

final class _FramebufferDecodeSlot {
  _FramebufferDecodeSlot(int pixelCount)
    : indexed = Uint8List(pixelCount),
      rgba = Uint8List(pixelCount * 4);

  final Uint8List indexed;
  final Uint8List rgba;
  bool pending = false;
}
