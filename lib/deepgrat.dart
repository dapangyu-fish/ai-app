import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '实时语音识别（Deepgram）',
      home: const DeepgramPage(),
    );
  }
}

class DeepgramPage extends StatefulWidget {
  const DeepgramPage({Key? key}) : super(key: key);

  @override
  State<DeepgramPage> createState() => _DeepgramPageState();
}

class _DeepgramPageState extends State<DeepgramPage> {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _audioSub;
  WebSocketChannel? _channel;

  bool _isListening = false;
  String _recognizedText = '';
  String _statusText = '按住说话（支持长句+停顿）';

  // ==================== 请替换成你的 Deepgram API Key ====================
  // 建议从环境变量或配置文件读取，不要硬编码在代码里
  static const String _deepgramApiKey = '6775d3fac799c5c3a8c3af9337ea7cace579c1c0';

  Future<void> _startListening() async {
    if (_isListening) return;

    debugPrint('[Deepgram] 开始连接 WebSocket...');

    // 1. 连接 Deepgram WebSocket（使用 IOWebSocketChannel 支持 headers）
    try {
      final ws = await WebSocket.connect(
        'wss://api.deepgram.com/v1/listen?model=nova-2&language=zh-CN&smart_format=true&interim_results=true&punctuate=true',
        headers: {'Authorization': 'Token $_deepgramApiKey'},
      );
      debugPrint('[Deepgram] WebSocket 连接成功');
      _channel = IOWebSocketChannel(ws);

    // 2. 监听返回结果
    _channel!.stream.listen(
      (message) {
        debugPrint('[Deepgram] 收到消息: $message');
        try {
          final data = jsonDecode(message);
          debugPrint('[Deepgram] 解析后的数据: $data');

          // Deepgram 返回格式可能是这样的：
          // {"channel": {"alternatives": [{"transcript": "你好"}]}}
          if (data['channel'] != null) {
            final channel = data['channel'];
            if (channel['alternatives'] != null && channel['alternatives'].isNotEmpty) {
              final transcript = channel['alternatives'][0]['transcript'];
              debugPrint('[Deepgram] 识别结果: $transcript');
              if (transcript != null && transcript.toString().isNotEmpty) {
                setState(() {
                  _recognizedText = transcript.toString();
                });
              }
            }
          }
        } catch (e, stackTrace) {
          debugPrint('[Deepgram] 解析结果失败: $e');
          debugPrint('[Deepgram] 堆栈: $stackTrace');
        }
      },
      onError: (error) {
        debugPrint('[Deepgram] WebSocket 错误: $error');
        setState(() => _statusText = '连接失败: $error');
      },
      onDone: () {
        debugPrint('[Deepgram] WebSocket 连接关闭');
      },
    );
    } catch (e, stackTrace) {
      debugPrint('[Deepgram] WebSocket 连接失败: $e');
      debugPrint('[Deepgram] 堆栈: $stackTrace');
      setState(() => _statusText = 'WebSocket 连接失败: $e');
      return;
    }

    // 3. 开始录音并发送音频
    try {
      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _audioSub = audioStream.listen((data) {
        if (_channel != null) {
          debugPrint('[Deepgram] 发送音频数据: ${data.length} bytes');
          _channel!.sink.add(data); // 直接发送 PCM 数据
        }
      });

      setState(() {
        _isListening = true;
        _recognizedText = '';
        _statusText = '正在识别中...（可停顿）';
      });
    } catch (e) {
      debugPrint('[Deepgram] 启动录音失败: $e');
      setState(() => _statusText = '启动失败: $e');
      _cleanup();
    }
  }

  void _cleanup() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    if (_channel != null) {
      try {
        await _channel!.sink.close(status.goingAway);
      } catch (e) {
        debugPrint('[Deepgram] 关闭 WebSocket 失败: $e');
      }
      _channel = null;
    }

    if (mounted) {
      setState(() {
        _isListening = false;
        _statusText = '按住说话（支持长句+停顿）';
      });
    }
  }

  Future<void> _stopListening() async {
    _cleanup();
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    _channel?.sink.close();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('实时语音识别 - Deepgram'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => setState(() => _recognizedText = ''),
          )
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _recognizedText.isEmpty ? '等待识别...\n支持长句 + 中间停顿' : _recognizedText,
                style: const TextStyle(fontSize: 24),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            Text(_statusText, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 60),
            GestureDetector(
              onPanDown: (_) => _startListening(),
              onPanEnd: (_) => _stopListening(),
              onPanCancel: () => _stopListening(),
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  color: _isListening ? Colors.red : Colors.green,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    _isListening ? '松开停止' : '按住说话',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),
            const Text(
              '提示：去 deepgram.com 注册免费 API Key\n替换代码中的 YOUR_DEEPGRAM_API_KEY_HERE',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
