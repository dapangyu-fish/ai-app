import 'dart:js_interop';
import 'dart:js_interop_unsafe';

class OpenIMWebBridge {
  static final OpenIMWebBridge instance = OpenIMWebBridge._();
  OpenIMWebBridge._();

  JSObject? _bridge;

  Future<void> init(Map<String, dynamic> config) async {
    final bridge = await _waitForBridge();
    _bridge = bridge;
    bridge.callMethodVarArgs('init'.toJS, [config.jsify()]);
  }

  void on(String event, void Function(Object? payload) handler) {
    _requireBridge().callMethodVarArgs('on'.toJS, [
      event.toJS,
      ((JSAny? payload) => handler(_dartify(payload))).toJS,
    ]);
  }

  Future<Object?> callAsync(String method, [Object? arg]) async {
    final args = arg == null ? const <JSAny?>[] : <JSAny?>[arg.jsify()];
    final promise = _requireBridge().callMethodVarArgs<JSPromise<JSAny?>>(
      method.toJS,
      args,
    );
    return _dartify(await promise.toDart);
  }

  JSObject _requireBridge() {
    final bridge = _bridge ?? globalContext['MyAppOpenIM'];
    if (bridge == null) throw Exception('OpenIM Web bridge 未加载');
    _bridge = bridge as JSObject;
    return _bridge!;
  }

  Future<JSObject> _waitForBridge() async {
    for (var i = 0; i < 50; i++) {
      final bridge = globalContext['MyAppOpenIM'];
      if (bridge != null) return bridge as JSObject;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    throw Exception('OpenIM Web bridge 未加载');
  }

  Object? _dartify(JSAny? value) => value?.dartify();
}
