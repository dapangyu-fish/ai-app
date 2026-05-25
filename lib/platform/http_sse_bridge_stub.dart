class HttpSseWebBridge {
  static bool get isSupported => false;

  static Future<Map<String, dynamic>> stream(
    Map<String, dynamic> params,
    Future<void> Function(Map<String, dynamic> event) onEvent,
  ) {
    throw UnsupportedError('HTTP SSE Web bridge is only available on Web');
  }
}
