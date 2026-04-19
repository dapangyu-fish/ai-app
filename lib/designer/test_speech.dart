import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// 独立测试页面 — 排查 speech_to_text 在 macOS 上的崩溃问题。
/// 使用方式：在 main.dart 中把 home 临时改为 SpeechTestPage() 来测试。
class SpeechTestPage extends StatefulWidget {
  const SpeechTestPage({super.key});

  @override
  State<SpeechTestPage> createState() => _SpeechTestPageState();
}

class _SpeechTestPageState extends State<SpeechTestPage> {
  final List<String> _logs = [];
  stt.SpeechToText? _speech;
  bool _inited = false;
  bool _listening = false;
  String _transcript = '';

  void _log(String msg) {
    debugPrint('[SpeechTest] $msg');
    setState(() => _logs.add('${DateTime.now().toIso8601String().substring(11, 19)} $msg'));
  }

  // Step 1: 测试能否构造 SpeechToText 对象
  void _testConstruct() {
    try {
      _speech = stt.SpeechToText();
      _log('✅ SpeechToText() 构造成功');
    } catch (e) {
      _log('❌ 构造失败: $e');
    }
  }

  // Step 2: 测试 initialize
  Future<void> _testInit() async {
    if (_speech == null) {
      _log('⚠️ 先执行 Step 1');
      return;
    }
    try {
      _log('⏳ 调用 initialize...');
      final result = await _speech!.initialize(
        onError: (error) => _log('onError: ${error.errorMsg}'),
        onStatus: (status) => _log('onStatus: $status'),
      );
      _inited = result;
      _log(result ? '✅ initialize 返回 true' : '❌ initialize 返回 false');

      // 列出可用语言
      if (result) {
        final locales = await _speech!.locales();
        _log('可用语言: ${locales.map((l) => l.localeId).take(10).join(", ")}...');
      }
    } catch (e, stack) {
      _log('❌ initialize 异常: $e');
      _log('Stack: $stack');
    }
  }

  // Step 3: 测试 listen
  Future<void> _testListen() async {
    if (!_inited) {
      _log('⚠️ 先执行 Step 2');
      return;
    }
    try {
      _log('⏳ 开始录音...');
      setState(() => _listening = true);
      _speech!.listen(
        onResult: (result) {
          setState(() => _transcript = result.recognizedWords);
          _log('识别结果: ${result.recognizedWords} (final=${result.finalResult})');
        },
        localeId: 'zh_CN',
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
      );
      _log('✅ listen 调用成功');
    } catch (e) {
      _log('❌ listen 异常: $e');
      setState(() => _listening = false);
    }
  }

  // Step 4: 停止
  void _testStop() {
    try {
      _speech?.stop();
      setState(() => _listening = false);
      _log('✅ stop 完成');
    } catch (e) {
      _log('❌ stop 异常: $e');
    }
  }

  @override
  void dispose() {
    _speech?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Speech Test')),
      body: Column(
        children: [
          // 操作按钮
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _testConstruct,
                  child: const Text('1. Construct'),
                ),
                ElevatedButton(
                  onPressed: _testInit,
                  child: const Text('2. Initialize'),
                ),
                ElevatedButton(
                  onPressed: _listening ? null : _testListen,
                  child: const Text('3. Listen'),
                ),
                ElevatedButton(
                  onPressed: _listening ? _testStop : null,
                  child: const Text('4. Stop'),
                ),
                TextButton(
                  onPressed: () => setState(() => _logs.clear()),
                  child: const Text('Clear Logs'),
                ),
              ],
            ),
          ),

          // 实时转写
          if (_transcript.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              width: double.infinity,
              child: Text('🎤 $_transcript', style: const TextStyle(fontSize: 16)),
            ),

          const SizedBox(height: 8),
          const Divider(),

          // 日志
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _logs.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _logs[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: _logs[i].contains('❌') ? Colors.red : null,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
