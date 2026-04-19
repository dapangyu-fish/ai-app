import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 离线语音识别服务 — SenseVoice 多语言
class SherpaAsrService {
  static SherpaAsrService? _instance;
  static SherpaAsrService get instance => _instance ??= SherpaAsrService._();
  SherpaAsrService._();

  bool _forceOffline = false;

  sherpa.OfflineRecognizer? _recognizer;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _audioSub;
  Timer? _decodeTimer;
  bool _initialized = false;

  List<double> _audioBuffer = [];
  String currentText = '';

  void Function(String status)? onStatusChange;
  void Function(String text)? onResult;

  bool get forceOffline => _forceOffline;

  Future<void> setForceOffline(bool value) async {
    _forceOffline = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('force_offline_asr', value);
    debugPrint('[SherpaASR] Force offline set to: $value');
  }

  void _resetRecognizer() {
    if (_recognizer != null) {
      try {
        _recognizer?.free();
      } catch (_) {}
    }
    _recognizer = null;
    _initialized = false;
    _audioBuffer = [];
  }

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _forceOffline = prefs.getBool('force_offline_asr') ?? false;
    debugPrint('[SherpaASR] Config loaded: forceOffline=$_forceOffline');
  }

  static const _ossBase = 'https://app-oss-endpoint.dapangyu.work/models';
  static const _modelId = 'sherpa-onnx/sensevoice-zh-en-ja-ko-yue-int8';

  Future<String> _getModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/sherpa_models/$_modelId';
  }

  Map<String, String> get _modelFiles => {
    'model': 'model.int8.onnx',
    'tokens': 'tokens.txt',
  };

  Future<bool> get isModelReady async {
    final dir = await _getModelDir();
    for (final file in _modelFiles.values) {
      if (!File('$dir/$file').existsSync()) return false;
    }
    return true;
  }

  Future<bool> downloadModels() async {
    try {
      final dir = await _getModelDir();
      await Directory(dir).create(recursive: true);
      final dio = Dio();

      for (final entry in _modelFiles.entries) {
        final file = File('$dir/${entry.value}');
        if (file.existsSync() && file.lengthSync() > 100) {
          continue;
        }

        final url = '$_ossBase/$_modelId/${entry.value}';
        debugPrint('[SherpaASR] Downloading ${entry.value} ...');
        onStatusChange?.call('下载语音模型: ${entry.value}');

        await dio.download(
          url,
          file.path,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final pct = (received / total * 100).toStringAsFixed(0);
              onStatusChange?.call('下载语音模型: $pct%');
            }
          },
        );

        debugPrint('[SherpaASR] Downloaded ${entry.value}: ${file.lengthSync()} bytes');
      }

      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Download model error: $e');
      return false;
    }
  }

  Future<bool> initialize() async {
    _resetRecognizer();

    try {
      sherpa.initBindings();
      final dir = await _getModelDir();

      final config = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: '$dir/${_modelFiles['model']!}',
            language: 'auto',
            useInverseTextNormalization: true,
          ),
          tokens: '$dir/${_modelFiles['tokens']!}',
          modelType: 'senseVoice',
          numThreads: 2,
          debug: false,
        ),
      );
      _recognizer = sherpa.OfflineRecognizer(config);

      _initialized = true;
      debugPrint('[SherpaASR] Recognizer initialized');
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Init error: $e');
      return false;
    }
  }

  Future<bool> ensureReady() async {
    await loadConfig();
    if (_initialized && _recognizer != null) return true;

    if (!await isModelReady) {
      final ok = await downloadModels();
      if (!ok) return false;
    }

    return await initialize();
  }

  Future<bool> startListening() async {
    if (_recognizer == null) return false;

    currentText = '';
    _audioBuffer = [];

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

      _decodeTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _decodeAndReport();
      });

      debugPrint('[SherpaASR] Listening started');
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Start recording error: $e');
      return false;
    }
  }

  void _feedAudio(Uint8List pcmBytes) {
    final byteData = ByteData.sublistView(pcmBytes);
    final sampleCount = pcmBytes.length ~/ 2;

    for (int i = 0; i < sampleCount; i++) {
      final int16 = byteData.getInt16(i * 2, Endian.little);
      _audioBuffer.add(int16 / 32768.0);
    }
  }

  void _decodeAndReport() {
    if (_recognizer != null && _audioBuffer.isNotEmpty) {
      final stream = _recognizer!.createStream();
      final samples = Float32List.fromList(_audioBuffer);
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _recognizer!.decode(stream);

      final result = _recognizer!.getResult(stream);
      if (result.text.isNotEmpty && result.text != currentText) {
        currentText = result.text;
        onResult?.call(currentText);
      }
      stream.free();
    }
  }

  Future<String> stopListening() async {
    _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    if (_recognizer != null && _audioBuffer.isNotEmpty) {
      final stream = _recognizer!.createStream();
      final samples = Float32List.fromList(_audioBuffer);
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _recognizer!.decode(stream);

      final result = _recognizer!.getResult(stream);
      if (result.text.isNotEmpty) {
        currentText = result.text;
      }
      stream.free();
    }

    _decodeTimer?.cancel();
    _decodeTimer = null;
    _audioBuffer = [];

    debugPrint('[SherpaASR] Final: $currentText');
    return currentText;
  }

  void dispose() {
    _audioSub?.cancel();
    _decodeTimer?.cancel();
    _recorder.dispose();
    _resetRecognizer();
  }
}
