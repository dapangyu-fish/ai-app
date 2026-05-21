import 'package:flutter/material.dart';

/// IMConversationPage 的 web 占位实现。web 上没有 OpenIM SDK，展示不可用提示。
class IMConversationPage extends StatelessWidget {
  const IMConversationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('消息')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('IM 功能在 Web 端不可用。', textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
