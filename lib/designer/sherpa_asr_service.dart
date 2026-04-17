import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:record/record.dart';

/// 离线语音识别服务 — 基于 sherpa_onnx + streaming Zipformer 14M (int8)
///
/// 用作 speech_to_text 的 fallback（中国安卓手机无 Google 服务时）。
/// 首次使用自动下载模型文件（~24MB），后续直接从本地加载。
class SherpaAsrService {
  static SherpaAsrService? _instance;
  static SherpaAsrService get instance => _instance ??= SherpaAsrService._();
  SherpaAsrService._();

  static const String _modelRepo =
      'csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23';
  static const String _hfBase =
      'https://huggingface.co/$_modelRepo/resolve/main';

  static const Map<String, String> _modelFiles = {
    'encoder': 'encoder-epoch-99-avg-1.int8.onnx',
    'decoder': 'decoder-epoch-99-avg-1.int8.onnx',
    'joiner': 'joiner-epoch-99-avg-1.int8.onnx',
    'tokens': 'tokens.txt',
  };

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _audioSub;
  Timer? _decodeTimer;
  bool _initialized = false;
  bool _downloading = false;

  /// 当前识别文本（实时更新）
  String currentText = '';

  /// 下载进度回调
  void Function(String status)? onStatusChange;

  /// 识别结果回调
  void Function(String text)? onResult;

  /// 模型文件存放目录
  Future<String> get _modelDir async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/sherpa_models/zipformer-zh-14M';
  }

  /// 检查模型是否已下载
  Future<bool> get isModelReady async {
    final dir = await _modelDir;
    for (final file in _modelFiles.values) {
      if (!File('$dir/$file').existsSync()) return false;
    }
    return true;
  }

  /// 下载模型文件
  Future<bool> downloadModel() async {
    if (_downloading) return false;
    _downloading = true;

    try {
      final dir = await _modelDir;
      await Directory(dir).create(recursive: true);

      final client = HttpClient();
      int current = 0;
      final total = _modelFiles.length;

      for (final entry in _modelFiles.entries) {
        final file = File('$dir/${entry.value}');
        if (file.existsSync() && file.lengthSync() > 100) {
          current++;
          continue;
        }

        current++;
        final label = entry.key;
        onStatusChange?.call('下载模型 ($current/$total): $label...');
        debugPrint('[SherpaASR] Downloading ${entry.value}...');

        final url = '$_hfBase/${entry.value}';
        final request = await client.getUrl(Uri.parse(url));
        request.followRedirects = true;
        final response = await request.close();

        if (response.statusCode != 200) {
          debugPrint('[SherpaASR] Download failed: ${response.statusCode}');
          _downloading = false;
          return false;
        }

        final sink = file.openWrite();
        await response.pipe(sink);
        debugPrint('[SherpaASR] Downloaded ${entry.value}: ${file.lengthSync()} bytes');
      }

      client.close();
      _downloading = false;
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Download error: $e');
      _downloading = false;
      return false;
    }
  }

  /// 初始化识别器（需要先下载模型）
  Future<bool> initialize() async {
    if (_initialized && _recognizer != null) return true;

    try {
      // 初始化 sherpa-onnx native bindings
      sherpa.initBindings();

      final dir = await _modelDir;

      final config = sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$dir/${_modelFiles['encoder']}',
            decoder: '$dir/${_modelFiles['decoder']}',
            joiner: '$dir/${_modelFiles['joiner']}',
          ),
          tokens: '$dir/${_modelFiles['tokens']}',
          modelType: 'zipformer2',
          numThreads: 2,
          debug: false,
        ),
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.2,
        rule3MinUtteranceLength: 20,
      );

      _recognizer = sherpa.OnlineRecognizer(config);
      _initialized = true;
      debugPrint('[SherpaASR] Recognizer initialized');
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Init error: $e');
      return false;
    }
  }

  /// 确保模型已下载且识别器已初始化
  Future<bool> ensureReady() async {
    if (_initialized && _recognizer != null) return true;

    if (!await isModelReady) {
      final ok = await downloadModel();
      if (!ok) return false;
    }

    return await initialize();
  }

  /// 开始录音+识别
  Future<bool> startListening() async {
    if (_recognizer == null) return false;

    // 创建新的识别流
    _stream?.free();
    _stream = _recognizer!.createStream();
    currentText = '';

    // 开始录音 — PCM 16kHz 16bit mono
    try {
      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _audioSub = audioStream.listen((data) {
        _feedAudio(data);
      });

      // 定时解码 + 取结果
      _decodeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _decodeAndReport();
      });

      debugPrint('[SherpaASR] Listening started');
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Start recording error: $e');
      return false;
    }
  }

  /// PCM int16 bytes → Float32 normalized [-1, 1] → 喂给识别器
  void _feedAudio(Uint8List pcmBytes) {
    if (_stream == null) return;

    // PCM 16-bit little-endian → Int16List
    final byteData = ByteData.sublistView(pcmBytes);
    final sampleCount = pcmBytes.length ~/ 2;
    final float32 = Float32List(sampleCount);

    for (int i = 0; i < sampleCount; i++) {
      final int16 = byteData.getInt16(i * 2, Endian.little);
      float32[i] = int16 / 32768.0;
    }

    _stream!.acceptWaveform(samples: float32, sampleRate: 16000);
  }

  /// 解码并通知结果
  void _decodeAndReport() {
    if (_recognizer == null || _stream == null) return;

    while (_recognizer!.isReady(_stream!)) {
      _recognizer!.decode(_stream!);
    }

    final result = _recognizer!.getResult(_stream!);
    if (result.text.isNotEmpty && result.text != currentText) {
      currentText = result.text;
      onResult?.call(currentText);
    }

    // 检测 endpoint（一句话结束），重置流继续识别下一句
    if (_recognizer!.isEndpoint(_stream!)) {
      if (currentText.isNotEmpty) {
        debugPrint('[SherpaASR] Endpoint: $currentText');
      }
      _recognizer!.reset(_stream!);
    }
  }

  /// 停止录音，返回最终识别文本
  Future<String> stopListening() async {
    // 停止录音
    _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    // 标记输入结束
    _stream?.inputFinished();

    // 最后一次解码
    if (_recognizer != null && _stream != null) {
      while (_recognizer!.isReady(_stream!)) {
        _recognizer!.decode(_stream!);
      }
      final result = _recognizer!.getResult(_stream!);
      if (result.text.isNotEmpty) {
        currentText = result.text;
      }
    }

    // 清理
    _decodeTimer?.cancel();
    _decodeTimer = null;
    _stream?.free();
    _stream = null;

    debugPrint('[SherpaASR] Final: $currentText');
    return currentText;
  }

  /// 释放资源
  void dispose() {
    _audioSub?.cancel();
    _decodeTimer?.cancel();
    _recorder.dispose();
    _stream?.free();
    _recognizer?.free();
    _stream = null;
    _recognizer = null;
    _initialized = false;
  }
}
