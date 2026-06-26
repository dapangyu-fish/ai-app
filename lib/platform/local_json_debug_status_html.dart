import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void setLocalJsonDebugStatus(Map<String, Object?> status) {
  globalContext['MyAppLocalJsonDebug'] = status.jsify();
}
