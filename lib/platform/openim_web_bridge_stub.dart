class OpenIMWebBridge {
  static final OpenIMWebBridge instance = OpenIMWebBridge._();
  OpenIMWebBridge._();

  Future<void> init(Map<String, dynamic> config) async {
    throw UnsupportedError(
      'OpenIM Web bridge is only available on Flutter Web',
    );
  }

  void on(String event, void Function(Object? payload) handler) {}

  Future<Object?> callAsync(String method, [Object? arg]) async {
    throw UnsupportedError(
      'OpenIM Web bridge is only available on Flutter Web',
    );
  }
}
