// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

class WebSseEvent {
  final String? id;
  final String data;

  const WebSseEvent({required this.data, this.id});
}

Stream<WebSseEvent> openWebEventSource(String url) {
  late final html.EventSource eventSource;
  late final StreamSubscription<html.MessageEvent> messageSub;
  late final StreamSubscription<html.Event> errorSub;

  final controller = StreamController<WebSseEvent>();
  var closed = false;

  void closeSource() {
    if (closed) return;
    closed = true;
    messageSub.cancel();
    errorSub.cancel();
    eventSource.close();
  }

  eventSource = html.EventSource(url);
  messageSub = eventSource.onMessage.listen((event) {
    final id = event.lastEventId.isEmpty ? null : event.lastEventId;
    controller.add(WebSseEvent(data: event.data?.toString() ?? '', id: id));
  });
  errorSub = eventSource.onError.listen((_) {
    if (!controller.isClosed) {
      controller.addError(Exception('EventSource connection failed'));
      closeSource();
      controller.close();
    }
  });

  controller.onCancel = closeSource;
  return controller.stream;
}
