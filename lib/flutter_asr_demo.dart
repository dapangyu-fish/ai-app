import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

void main() {
  runApp(const FlutterASRDemo());
}

class FlutterASRDemo extends StatelessWidget {
  const FlutterASRDemo({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASR Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ASRDemoPage(),
    );
  }
}

class ASRDemoPage extends StatefulWidget {
  const ASRDemoPage({Key? key}) : super(key: key);

  @override
  State<ASRDemoPage> createState() => _ASRDemoPageState();
}

class _ASRDemoPageState extends State<ASRDemoPage> {
  // 服务器地址
  static const String SERVER_URL = 'http://192.168.111.181:5001';

  // Socket.IO 客户端
  IO.Socket? _socket;

  // 录音器
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _audioSub;
  Timer? _sendTimer;

  // 状态
  bool _isConnected = false;
  bool _isRecording = false;
  String _recognizedText = '';
  String _statusText = '未连接';

  // 音频缓冲区
  final List<Uint8List> _audioBuffer = [];

  @override
  void initState() {
    super.initState();
    _connectToServer();
  }

  void _connectToServer() {
    debugPrint('[ASR] Connecting to $SERVER_URL');

    _socket = IO.io(SERVER_URL, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    _socket!.onConnect((_) {
      debugPrint('[ASR] Connected to server');
      setState(() {
        _isConnected = true;
        _statusText = '已连接，按住按钮说话';
      });
    });

    _socket!.onDisconnect((_) {
      debugPrint('[ASR] Disconnected from server');
      setState(() {
        _isConnected = false;
        _statusText = '连接断开';
      });
    });

    _socket!.on('connected', (data) {
      debugPrint('[ASR] Server confirmed connection: $data');
    });

    _socket!.on('started', (data) {
      debugPrint('[ASR] Recognition started: $data');
    });

    _socket!.on('result', (data) {
      debugPrint('[ASR] Received result: $data');
      if (data is Map && data['text'] != null) {
        setState(() {
          _recognizedText = data['text'];
        });
      }
    });

    _socket!.on('error', (data) {
      debugPrint('[ASR] Error: $data');
      if (data is Map && data['message'] != null) {
        setState(() {
          _statusText = '错误: ${data['message']}';
        });
      }
    });
  }

  Future<void> _startRecording() async {
    if (!_isConnected || _isRecording) return;

    debugPrint('[ASR] Starting recording...');

    // 检查麦克风权限
    if (!await _recorder.hasPermission()) {
      setState(() {
        _statusText = '麦克风权限未授予';
      });
      return;
    }

    // 通知服务器开始识别
    _socket!.emit('start', {});

    // 清空缓冲区和识别文本
    _audioBuffer.clear();
    setState(() {
      _recognizedText = '';
      _statusText = '正在录音...';
    });

    try {
      // 开始录音
      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      // 监听音频流
      _audioSub = audioStream.listen(
        (data) {
          _audioBuffer.add(data);
        },
        onError: (e) {
          debugPrint('[ASR] Audio stream error: $e');
        },
      );

      // 启动定时发送任务（每 400ms 发送一次）
      _sendTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        _sendAudioBuffer();
      });

      setState(() {
        _isRecording = true;
      });

      debugPrint('[ASR] Recording started');
    } catch (e) {
      debugPrint('[ASR] Start recording error: $e');
      setState(() {
        _statusText = '录音启动失败: $e';
      });
    }
  }

  void _sendAudioBuffer() {
    if (_audioBuffer.isEmpty) return;

    // 合并缓冲区中的所有音频数据
    int totalLength = 0;
    for (var chunk in _audioBuffer) {
      totalLength += chunk.length;
    }

    final combined = Uint8List(totalLength);
    int offset = 0;
    for (var chunk in _audioBuffer) {
      combined.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    // 清空缓冲区
    _audioBuffer.clear();

    // Base64 编码
    final base64Audio = base64Encode(combined);

    // 发送到服务器
    _socket!.emit('audio', {
      'type': 'audio',
      'data': base64Audio,
      'is_last': false,
    });

    debugPrint('[ASR] Sent audio chunk: ${combined.length} bytes');
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    debugPrint('[ASR] Stopping recording...');

    // 停止定时器
    _sendTimer?.cancel();
    _sendTimer = null;

    // 发送最后一包音频
    _sendAudioBuffer();

    // 发送结束标记
    _socket!.emit('audio', {
      'type': 'audio',
      'data': '',
      'is_last': true,
    });

    // 停止录音
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    setState(() {
      _isRecording = false;
      _statusText = '已连接，按住按钮说话';
    });

    debugPrint('[ASR] Recording stopped');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('语音识别 Demo'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 识别结果
            Padding(
              padding: const EdgeInsets.all(20),
              child: Container(
                width: double.infinity,
                height: 200,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _recognizedText.isEmpty ? '等待识别...' : _recognizedText,
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // 状态文本
            Text(
              _statusText,
              style: TextStyle(
                fontSize: 14,
                color: _isConnected ? Colors.green : Colors.red,
              ),
            ),

            const SizedBox(height: 40),

            // 录音按钮
            GestureDetector(
              onLongPressStart: (_) => _startRecording(),
              onLongPressEnd: (_) => _stopRecording(),
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: _isRecording
                      ? Colors.red
                      : (_isConnected ? Colors.blue : Colors.grey),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    _isRecording ? '松开停止' : '按住说话',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sendTimer?.cancel();
    _audioSub?.cancel();
    _recorder.dispose();
    _socket?.dispose();
    super.dispose();
  }
}
