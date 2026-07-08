// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// PCM audio sink interface. See pcm_sink.dart.
abstract class PcmSink {
  void feed(Int16List samples);
  void resume();
  void dispose();
}

/// Web Audio implementation: each [feed] converts samples to a mono AudioBuffer
/// and schedules it back-to-back on a playback cursor for gapless streaming.
class _WebPcmSink implements PcmSink {
  _WebPcmSink(this.sampleRate) : _ctx = web.AudioContext();

  final int sampleRate;
  final web.AudioContext _ctx;

  /// Next scheduled start time (seconds, in the AudioContext clock).
  double _cursor = 0;

  // DC blocker (NES DAC output is unipolar ~0..5000): y[n]=x[n]-x[n-1]+r*y[n-1]
  double _prevIn = 0;
  double _prevOut = 0;
  static const double _r = 0.995;
  static const double _scale = 1.0 / 6000.0; // typical amplitude → ~[-1,1]

  @override
  void feed(Int16List samples) {
    final n = samples.length;
    if (n == 0) return;
    final now = _ctx.currentTime;
    // Resync on underrun; drop chunk if we've drifted >250ms ahead (cap latency).
    if (_cursor < now + 0.02) _cursor = now + 0.06; // ~60ms target latency
    if (_cursor > now + 0.25) return;

    final buf = _ctx.createBuffer(1, n, sampleRate.toDouble());
    final ch = buf.getChannelData(0).toDart; // Float32List view over JS buffer
    var pin = _prevIn, pout = _prevOut;
    for (var i = 0; i < n; i++) {
      final x = samples[i].toDouble();
      final y = x - pin + _r * pout; // high-pass removes DC offset
      pin = x;
      pout = y;
      var v = y * _scale;
      if (v > 1) {
        v = 1;
      } else if (v < -1) {
        v = -1;
      }
      ch[i] = v;
    }
    _prevIn = pin;
    _prevOut = pout;

    final src = _ctx.createBufferSource();
    src.buffer = buf;
    src.connect(_ctx.destination);
    src.start(_cursor);
    _cursor += n / sampleRate;
  }

  @override
  void resume() {
    _ctx.resume();
  }

  @override
  void dispose() {
    _ctx.close();
  }
}

PcmSink? createPcmSink({int sampleRate = 48000}) {
  try {
    return _WebPcmSink(sampleRate);
  } catch (_) {
    return null; // AudioContext unavailable
  }
}
