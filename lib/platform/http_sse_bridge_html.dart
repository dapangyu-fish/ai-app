import 'dart:js_interop';
import 'dart:js_interop_unsafe';

class HttpSseWebBridge {
  static bool get isSupported => globalContext['MyAppHttpSSE'] != null;

  static Future<Map<String, dynamic>> stream(
    Map<String, dynamic> params,
    Future<void> Function(Map<String, dynamic> event) onEvent,
  ) async {
    final bridge = globalContext['MyAppHttpSSE'];
    if (bridge == null) {
      throw Exception('HTTP SSE Web bridge 未加载');
    }
    final promise = (bridge as JSObject)
        .callMethodVarArgs<JSPromise<JSAny?>>('stream'.toJS, [
          params.jsify(),
          ((JSAny? payload) {
            final dart = payload?.dartify();
            if (dart is Map) {
              onEvent(Map<String, dynamic>.from(dart));
            }
          }).toJS,
        ]);
    final result = (await promise.toDart)?.dartify();
    if (result is Map) return Map<String, dynamic>.from(result);
    return {
      'status': -1,
      'events': const [],
      'done': false,
      'error': 'Invalid web SSE result',
    };
  }
}
