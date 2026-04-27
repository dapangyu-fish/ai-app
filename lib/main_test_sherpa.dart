import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:record/record.dart';

void main() {
  runApp(const TestSherpaApp());
}

class TestSherpaApp extends StatelessWidget {
  const TestSherpaApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sherpa 长句识别',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const TestSherpaPage(),
    );
  }
}

class TestSherpaPage extends StatefulWidget {
  const TestSherpaPage({Key? key}) : super(key: key);

  @override
  State<TestSherpaPage> createState() => _TestSherpaPageState();
}

class _TestSherpaPageState extends State<TestSherpaPage> {
  static const String _ossBase = 'https://app-oss-endpoint.dapangyu.work/models';
  static const String _modelPath = 'sherpa-onnx/streaming-zipformer-small-bilingual-zh-en-int8';
  static const Map<String, String> _modelFiles = {
    'encoder': 'encoder-epoch-99-avg-1.int8.onnx',
    'decoder': 'decoder-epoch-99-avg-1.int8.onnx',
    'joiner': 'joiner-epoch-99-avg-1.int8.onnx',
    'tokens': 'tokens.txt',
  };

  bool _isDownloading = false;
  bool _isReady = false;
  bool _isListening = false;
  String _statusText = '点击下载模型';
  String _recognizedText = '';
  double _downloadProgress = 0.0;

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _audioSub;

  final List<Float32List> _audioQueue = [];
  Timer? _processTimer;

  // ==================== 新增：完整文本累加 ====================
  String _fullText = '';

  @override
  void initState() {
    super.initState();
    _checkModelExists();
  }

  Future<String> _getModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/sherpa_test/$_modelPath';
  }

  Future<void> _checkModelExists() async {
    final dir = await _getModelDir();
    bool allExist = true;
    for (final file in _modelFiles.values) {
      final f = File('$dir/$file');
      if (!f.existsSync() || f.lengthSync() == 0) allExist = false;
    }
    if (allExist) setState(() => _statusText = '模型已下载，点击初始化');
  }

  Future<void> _downloadModel() async {
    setState(() {
      _isDownloading = true;
      _statusText = '开始下载模型...';
      _downloadProgress = 0.0;
    });

    try {
      final dir = await _getModelDir();
      await Directory(dir).create(recursive: true);
      final dio = Dio();

      for (final entry in _modelFiles.entries) {
        final file = File('$dir/${entry.value}');
        if (file.existsSync() && file.lengthSync() > 0) continue;
        await file.parent.create(recursive: true);
        await dio.download('$_ossBase/$_modelPath/${entry.value}', file.path);
      }

      setState(() {
        _isDownloading = false;
        _statusText = '下载完成！点击初始化';
        _downloadProgress = 1.0;
      });
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _statusText = '下载失败: $e';
      });
    }
  }

  Future<void> _initializeModel() async {
    setState(() => _statusText = '初始化模型...');

    try {
      sherpa.initBindings();
      final dir = await _getModelDir();

      final config = sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$dir/${_modelFiles['encoder']}',
            decoder: '$dir/${_modelFiles['decoder']}',
            joiner: '$dir/${_modelFiles['joiner']}',
          ),
          tokens: '$dir/${_modelFiles['tokens']}',
          numThreads: 1,
        ),
        ruleFsts: '',
        enableEndpoint: true,                    // 开启端点检测（支持停顿）
      );

      _recognizer = sherpa.OnlineRecognizer(config);
      _stream = _recognizer!.createStream();

      setState(() {
        _isReady = true;
        _statusText = '就绪！按住按钮说话（支持长句+停顿）';
      });
    } catch (e) {
      setState(() => _statusText = '初始化失败: $e');
    }
  }

  Future<void> _startListening() async {
    if (!_isReady || _recognizer == null) return;

    _stream?.free();
    _stream = _recognizer!.createStream();
    _fullText = '';                    // 新开始时清空累加文本
    setState(() => _recognizedText = '');

    if (!await _recorder.hasPermission()) {
      setState(() => _statusText = '麦克风权限未授予');
      return;
    }

    try {
      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _audioSub = audioStream.listen(
        (data) => _enqueueAudio(data),
        onError: (e, s) => debugPrint('[Test] Audio error: $e'),
        cancelOnError: false,
      );

      _processTimer?.cancel();
      _processTimer = Timer.periodic(
        const Duration(milliseconds: 80),
        (_) => _processQueuedAudio(),
      );

      setState(() {
        _isListening = true;
        _statusText = '正在录音...（可停顿）';
      });
    } catch (e) {
      setState(() => _statusText = '录音启动失败: $e');
    }
  }

  void _enqueueAudio(Uint8List pcmBytes) {
    try {
      final byteData = ByteData.view(Uint8List.fromList(pcmBytes).buffer);
      final samples = Float32List(pcmBytes.length ~/ 2);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
      }
      _audioQueue.add(samples);
    } catch (_) {}
  }

  void _processQueuedAudio() {
    if (_audioQueue.isEmpty || _stream == null || _recognizer == null) return;

    try {
      for (final s in _audioQueue) {
        _stream!.acceptWaveform(samples: s, sampleRate: 16000);
      }
      _audioQueue.clear();

      while (_recognizer!.isReady(_stream!)) {
        _recognizer!.decode(_stream!);
      }

      final result = _recognizer!.getResult(_stream!);
      if (result.text.isNotEmpty && result.text != _recognizedText.split(' ').last) {
        // 累加文本
        if (_fullText.isNotEmpty) _fullText += ' ';
        _fullText += result.text;
        setState(() => _recognizedText = _fullText.trim());
      }

      // 检测到停顿/句子结束 → 自动开始新段（支持长句）
      if (_recognizer!.isEndpoint(_stream!)) {
        debugPrint('[Test] 检测到停顿 → 自动分段');
        _recognizer!.reset(_stream!);
      }
    } catch (e) {
      debugPrint('[Test] Process error: $e');
    }
  }

  Future<void> _stopListening() async {
    _processTimer?.cancel();
    _processTimer = null;
    _audioQueue.clear();

    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    // 最后一次完整解码
    if (_stream != null && _recognizer != null) {
      while (_recognizer!.isReady(_stream!)) {
        _recognizer!.decode(_stream!);
      }
      final finalResult = _recognizer!.getResult(_stream!);
      if (finalResult.text.isNotEmpty) {
        if (_fullText.isNotEmpty) _fullText += ' ';
        _fullText += finalResult.text;
        setState(() => _recognizedText = _fullText.trim());
      }
      _recognizer!.reset(_stream!);
    }

    setState(() {
      _isListening = false;
      _statusText = '就绪！按住按钮说话（支持长句+停顿）';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sherpa 长句识别（支持停顿）'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              setState(() {
                _recognizedText = '';
                _fullText = '';
              });
            },
          )
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                _recognizedText.isEmpty ? '等待识别...\n\n支持长句 + 中间停顿' : _recognizedText,
                style: const TextStyle(fontSize: 22),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            Text(_statusText, style: const TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 40),
            if (!_isReady && !_isDownloading)
              ElevatedButton(onPressed: _downloadModel, child: const Text('下载模型')),
            const SizedBox(height: 10),
            if (!_isReady && !_isDownloading && _downloadProgress > 0)
              ElevatedButton(onPressed: _initializeModel, child: const Text('初始化模型')),
            const SizedBox(height: 50),
            if (_isReady)
              GestureDetector(
                onLongPressStart: (_) => _startListening(),
                onLongPressEnd: (_) => _stopListening(),
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    color: _isListening ? Colors.red : Colors.green,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      _isListening ? '松开停止\n（可停顿）' : '按住说话\n（支持长句）',
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
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
    _processTimer?.cancel();
    _audioSub?.cancel();
    _recorder.dispose();
    _stream?.free();
    _recognizer?.free();
    super.dispose();
  }
}