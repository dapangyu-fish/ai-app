import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// PCM audio sink interface. See pcm_sink.dart.
abstract class PcmSink {
  void feed(Int16List samples);
  void resume();
  void dispose();
}

/// Native PCM sink (Android/iOS/macOS/Windows) via flutter_pcm_sound. Samples
/// are fed each emulated frame; a low-buffer callback tops up with silence to
/// keep the stream alive on underrun. Platforms the plugin doesn't support
/// (e.g. Linux) throw during [setup] and createPcmSink returns null.
class _NativePcmSink implements PcmSink {
  _NativePcmSink(this.sampleRate) {
    _init();
  }

  final int sampleRate;
  bool _ready = false;
  bool _disposed = false;

  Future<void> _init() async {
    try {
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 20); // ~50ms
      FlutterPcmSound.setFeedCallback(_onLowBuffer);
      _ready = true;
      FlutterPcmSound.start();
    } catch (e) {
      _ready = false;
      debugPrint('[pcm] native audio unavailable: $e');
    }
  }

  // Called when the internal buffer runs low; feed silence to avoid a stall.
  void _onLowBuffer(int remainingFrames) {
    if (_disposed) return;
    FlutterPcmSound.feed(PcmArrayInt16.fromList(Int16List(sampleRate ~/ 60)));
  }

  @override
  void feed(Int16List samples) {
    if (!_ready || _disposed || samples.isEmpty) return;
    FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
  }

  @override
  void resume() {}

  @override
  void dispose() {
    _disposed = true;
    FlutterPcmSound.release();
  }
}

PcmSink? createPcmSink({int sampleRate = 48000}) {
  try {
    return _NativePcmSink(sampleRate);
  } catch (_) {
    return null;
  }
}
