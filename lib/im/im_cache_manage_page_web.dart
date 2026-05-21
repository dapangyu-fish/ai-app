import 'package:flutter/material.dart';

/// IMCacheManagePage 的 web 占位实现。web 上没有 OpenIM / 本地缓存，展示一句说明。
class IMCacheManagePage extends StatelessWidget {
  const IMCacheManagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IM 缓存管理')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'IM 功能在 Web 端不可用。',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
