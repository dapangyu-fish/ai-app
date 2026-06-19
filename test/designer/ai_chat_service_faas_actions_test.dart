import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/designer/ai_chat_service.dart';

void main() {
  test('FaaS client actions become visible system messages', () {
    expect(
      AiChatService.systemMessageFromClientAction({
        'type': 'faas_service_ready',
        'service_id': 'todo-api',
        'invoke_url': '/api/faas/invoke/todo-api',
      }),
      '后端服务已部署：todo-api\n调用地址：/api/faas/invoke/todo-api',
    );

    expect(
      AiChatService.systemMessageFromClientAction({
        'type': 'faas_service_failed',
        'path': 'faas_bundle.json',
        'error': 'bundle invalid',
      }),
      '后端服务部署失败：faas_bundle.json\nbundle invalid',
    );
  });
}
