/// Web stub for the compute worker: isolates don't exist on Flutter Web, so
/// worker mode is unsupported and GameCompute falls back to synchronous calls.
library;

/// Mirror of the native API surface; never instantiated on the web.
class ComputeWorker {
  static bool get supported => false;

  static Future<ComputeWorker?> spawn({
    required Map<String, dynamic> programSpec,
    required void Function(Map<dynamic, dynamic> event) onEvent,
  }) async =>
      null;

  void post(Map<String, Object?> op) {}

  void dispose() {}
}
