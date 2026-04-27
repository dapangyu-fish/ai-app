import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'bytedance_asr_service.dart';

/// 豆包ASR测试页面
class ByteDanceAsrTestPage extends StatefulWidget {
  const ByteDanceAsrTestPage({Key? key}) : super(key: key);

  @override
  State<ByteDanceAsrTestPage> createState() => _ByteDanceAsrTestPageState();
}

class _ByteDanceAsrTestPageState extends State<ByteDanceAsrTestPage> {
  final ByteDanceAsrService _asrService = ByteDanceAsrService.instance;

  String _statusText = '未连接';
  String _recognizedText = '';
  Map<String, dynamic>? _quotaInfo;

  @override
  void initState() {
    super.initState();
    _initAsr();
  }

  Future<void> _initAsr() async {
    // 设置回调
    _asrService.onStatusChange = (status) {
      setState(() {
        _statusText = status;
      });
    };

    _asrService.onResult = (text) {
      setState(() {
        _recognizedText = text;
      });
    };

    _asrService.onError = (error) {
      setState(() {
        _statusText = '错误: $error';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    };

    _asrService.onQuotaUpdate = (quota) {
      setState(() {
        _quotaInfo = quota;
      });
    };

    // 连接到服务器
    await _connectToServer();
  }

  Future<void> _connectToServer() async {
    // 从 SharedPreferences 获取 token
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');

    if (token == null || token.isEmpty) {
      setState(() {
        _statusText = '未登录，请先登录';
      });
      return;
    }

    // 连接到服务器（替换成你的服务器地址）
    const serverUrl = 'http://192.168.111.181:5566';
    final success = await _asrService.connect(serverUrl, token);

    if (!success) {
      setState(() {
        _statusText = '连接失败';
      });
    }
  }

  void _startListening() {
    _asrService.startListening();
  }

  void _stopListening() {
    _asrService.stopListening();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('豆包语音识别'),
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
                color: _asrService.isConnected ? Colors.green : Colors.red,
              ),
            ),

            const SizedBox(height: 10),

            // 配额信息
            if (_quotaInfo != null)
              Text(
                '今日已用: ${_quotaInfo!['used']}/${_quotaInfo!['limit']} (剩余: ${_quotaInfo!['remaining']})',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),

            const SizedBox(height: 40),

            // 录音按钮
            GestureDetector(
              onLongPressStart: (_) => _startListening(),
              onLongPressEnd: (_) => _stopListening(),
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: _asrService.isRecording
                      ? Colors.red
                      : (_asrService.isConnected ? Colors.blue : Colors.grey),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    _asrService.isRecording ? '松开停止' : '按住说话',
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
    _asrService.dispose();
    super.dispose();
  }
}
