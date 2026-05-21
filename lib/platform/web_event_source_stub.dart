class WebSseEvent {
  final String? id;
  final String data;

  const WebSseEvent({required this.data, this.id});
}

Stream<WebSseEvent> openWebEventSource(String url) {
  throw UnsupportedError('EventSource is only available on Flutter Web');
}
