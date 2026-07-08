/// Low-latency PCM audio sink for streaming emulator/synth output.
///
/// The compute kernel's APU produces signed-16-bit mono samples; a game drains
/// them each frame ([GameCompute.drainAudio]) and feeds them here. Playback is
/// platform-specific: web uses the Web Audio API (scheduled AudioBuffers);
/// native platforms return null until a platform player is wired (the drain
/// path is platform-agnostic, so adding one is self-contained).
///
/// Conditional export selects the web implementation when `dart:html` is
/// available, else the no-op stub — matching the project's platform-bridge
/// convention (see lib/platform/*_html.dart / *_stub.dart).
library;

export 'pcm_sink_native.dart' if (dart.library.html) 'pcm_sink_html.dart';
