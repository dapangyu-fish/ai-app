import 'dart:typed_data';

/// PCM audio sink interface. See pcm_sink.dart.
abstract class PcmSink {
  /// Enqueue mono signed-16-bit samples for gapless playback.
  void feed(Int16List samples);

  /// Resume the audio context (browsers suspend it until a user gesture).
  void resume();

  void dispose();
}

/// Native/unsupported platforms: no PCM streaming sink yet (drain path is
/// platform-agnostic; wire a platform player here to enable audio).
PcmSink? createPcmSink({int sampleRate = 48000}) => null;
