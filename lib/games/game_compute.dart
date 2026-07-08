/// Framework bridge exposing the general compute kernel (T7) to flame_game JSON
/// apps: a `compute` block declares a program + buffers; `@compute.*` actions
/// drive it; a `framebuffer` entity presents a byte buffer as pixels.
///
/// Reusable and content-agnostic — the NES port is authored as data for this
/// bridge (docs/nesd-port-feasibility.md). Nothing here is NES-specific.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../json_ui/asset_manager.dart';
import '../json_ui/compute/compute_kernel.dart';
import 'pcm_sink.dart';

/// Holds a compiled [ComputeProgram] for a flame_game plus helpers to load
/// binary blobs into buffers and present a palette-indexed buffer as an image.
class GameCompute {
  GameCompute._(this.program, this.assetManager);

  final ComputeProgram program;
  final JsonAppAssetManager? assetManager;

  /// Host-visible input words (e.g. controller state), readable by the program
  /// through a `host("input", [i])` binding.
  final Int32List inputs = Int32List(8);

  /// Latest presented frame (decoded async; drawn by [framebufferImage]).
  ui.Image? _frameImage;
  bool _decoding = false;

  ui.Image? get framebufferImage => _frameImage;

  static GameCompute? fromSpec(
    dynamic spec, {
    JsonAppAssetManager? assetManager,
  }) {
    if (spec is! Map) return null;
    final progSpec = spec['program'];
    if (progSpec is! Map) return null;
    late final GameCompute gc;
    final hosts = <String, HostFn>{
      // input(i) -> inputs[i]  (controller / peripheral state)
      'input': (args) {
        final i = args.isNotEmpty ? args[0] : 0;
        return (i >= 0 && i < gc.inputs.length) ? gc.inputs[i] : 0;
      },
    };
    final program = ComputeProgram.compile(
      progSpec.cast<String, dynamic>(),
      hosts: hosts,
    );
    gc = GameCompute._(program, assetManager);
    return gc;
  }

  /// Load base64 bytes into a byte buffer at [offset], optionally mirroring to
  /// fill (NROM: 16KB PRG mirrored across 32KB).
  void loadBase64(String buffer, String b64, {int offset = 0, bool mirror = false}) {
    final bytes = base64Decode(b64);
    _loadInto(buffer, bytes, offset, mirror);
  }

  Future<void> loadAsset(String buffer, String url,
      {int offset = 0, bool mirror = false, int skipHeader = 0}) async {
    final am = assetManager;
    if (am == null) return;
    final bytes = await am.loadBytes(am.resolve(url));
    _loadInto(buffer, bytes.sublist(skipHeader), offset, mirror);
  }

  void _loadInto(String buffer, Uint8List bytes, int offset, bool mirror) {
    final buf = program.u8[buffer];
    if (buf == null) return;
    final n = bytes.length;
    for (var i = 0; i < n && offset + i < buf.length; i++) {
      buf[offset + i] = bytes[i];
    }
    if (mirror && offset == 0 && n > 0 && n * 2 <= buf.length) {
      for (var i = 0; i < n; i++) {
        buf[n + i] = bytes[i];
      }
    }
  }

  int call(String fn, List<int> args, {int budget = 400000000}) {
    try {
      return program.call(fn, args: args, budget: budget);
    } catch (e) {
      debugPrint('[compute] $fn failed: $e');
      return 0;
    }
  }

  int getU8(String buffer, int addr) {
    final b = program.u8[buffer];
    if (b == null || addr < 0 || addr >= b.length) return 0;
    return b[addr];
  }

  void setU8(String buffer, int addr, int v) {
    final b = program.u8[buffer];
    if (b == null || addr < 0 || addr >= b.length) return;
    b[addr] = v & 0xFF;
  }

  void setInput(int i, int v) {
    if (i >= 0 && i < inputs.length) inputs[i] = v;
  }

  /// Drain accumulated audio samples produced since the last drain. The compute
  /// program must expose a `drainFn` returning the sample count (and resetting
  /// its write index) and store int16 PCM as little-endian byte pairs in
  /// [samplesBuffer]. Returns the samples (mono, signed 16-bit) for a PCM sink.
  Int16List drainAudio({
    String drainFn = 'apu_drain',
    String samplesBuffer = 'samples',
  }) {
    if (!program.hasFunction(drainFn)) return _emptyI16;
    final n = call(drainFn, const []);
    final bytes = program.u8[samplesBuffer];
    if (bytes == null || n <= 0) return _emptyI16;
    final count = n * 2 <= bytes.length ? n : bytes.length ~/ 2;
    final out = Int16List(count);
    for (var i = 0; i < count; i++) {
      final v = bytes[i * 2] | (bytes[i * 2 + 1] << 8);
      out[i] = v >= 0x8000 ? v - 0x10000 : v;
    }
    return out;
  }

  static final Int16List _emptyI16 = Int16List(0);

  PcmSink? _audioSink;
  bool _audioInit = false;

  /// Drain the APU's accumulated samples and stream them to the platform PCM
  /// sink for playback (web: Web Audio; native: no-op until a player is wired).
  /// Call once per emulated frame. Safe no-op if the program has no [drainFn].
  void streamAudio({
    String drainFn = 'apu_drain',
    String samplesBuffer = 'samples',
    int sampleRate = 48000,
  }) {
    if (!_audioInit) {
      _audioInit = true;
      if (program.hasFunction(drainFn)) {
        _audioSink = createPcmSink(sampleRate: sampleRate);
      }
    }
    final sink = _audioSink;
    if (sink == null) return;
    final samples = drainAudio(drainFn: drainFn, samplesBuffer: samplesBuffer);
    if (samples.isNotEmpty) sink.feed(samples);
  }

  /// Resume the audio context after a user gesture (browsers require this).
  void resumeAudio() => _audioSink?.resume();

  /// Convert a palette-indexed byte buffer (w×h, values 0..len(palette)) to
  /// RGBA and decode to a [ui.Image] asynchronously; the cached image is drawn
  /// by the framebuffer entity (≤1 frame latency, matching a texture stream).
  void present(String buffer, int w, int h, List<int> paletteRgb) {
    if (_decoding) return;
    final src = program.u8[buffer];
    if (src == null) return;
    final rgba = Uint8List(w * h * 4);
    final pal = paletteRgb;
    final palLen = pal.length;
    for (var i = 0; i < w * h; i++) {
      final idx = src[i];
      final c = idx < palLen ? pal[idx] : 0;
      final o = i * 4;
      rgba[o] = (c >> 16) & 0xFF;
      rgba[o + 1] = (c >> 8) & 0xFF;
      rgba[o + 2] = c & 0xFF;
      rgba[o + 3] = 0xFF;
    }
    _decoding = true;
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
      _frameImage?.dispose();
      _frameImage = img;
      _decoding = false;
    });
  }

  void dispose() {
    _frameImage?.dispose();
    _frameImage = null;
    _audioSink?.dispose();
    _audioSink = null;
  }
}
