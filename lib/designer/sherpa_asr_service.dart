import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================
// 模型注册表
// ============================================================

class AsrModel {
  final String id;
  final String name;
  final String description;
  final String ossPath;
  final Map<String, String> files;
  final String modelType;

  const AsrModel({
    required this.id,
    required this.name,
    required this.description,
    required this.ossPath,
    required this.files,
    required this.modelType,
  });
}

const kAsrModels = <AsrModel>[
  AsrModel(
    id: 'sensevoice',
    name: 'SenseVoice',
    description: '中英日韩粤 多语言 (~50MB)',
    ossPath: 'sherpa-onnx/sensevoice-zh-en-ja-ko-yue-int8',
    files: {
      'model': 'model.int8.onnx',
      'tokens': 'tokens.txt',
    },
    modelType: 'senseVoice',
  ),
  AsrModel(
    id: 'qwen3-asr',
    name: 'Qwen3 ASR 0.6B',
    description: '通义千问语音识别 (~600MB)',
    ossPath: 'sherpa-onnx/qwen3-asr-0.6B-int8',
    files: {
      'conv_frontend': 'conv_frontend-int8.onnx',
      'encoder': 'encoder-int8.onnx',
      'decoder': 'decoder-int8.onnx',
      'tokenizer': 'tokenizer.json',
      'tokens': 'tokens.txt',
    },
    modelType: 'qwen3Asr',
  ),
  AsrModel(
    id: 'funasr-nano',
    name: 'FunASR Nano',
    description: '阿里FunASR 轻量模型 (~400MB)',
    ossPath: 'sherpa-onnx/funasr-nano-int8',
    files: {
      'encoder_adaptor': 'encoder_adaptor-int8.onnx',
      'llm': 'llm-int8.onnx',
      'embedding': 'embedding.onnx',
      'tokenizer': 'tokenizer.json',
      'tokens': 'tokens.txt',
    },
    modelType: 'funasrNano',
  ),
];

AsrModel getAsrModelById(String id) {
  return kAsrModels.firstWhere((m) => m.id == id, orElse: () => kAsrModels[0]);
}

// ============================================================
// 离线语音识别服务 — 多模型支持
// ============================================================

class SherpaAsrService {
  static SherpaAsrService? _instance;
  static SherpaAsrService get instance => _instance ??= SherpaAsrService._();
  SherpaAsrService._();

  static const String _modelPrefKey = 'asr_model_id';

  bool _forceOffline = false;
  String _currentModelId = 'sensevoice';

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
  String get currentModelId => _currentModelId;
  AsrModel get currentModel => getAsrModelById(_currentModelId);

  Future<void> setForceOffline(bool value) async {
    _forceOffline = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('force_offline_asr', value);
    debugPrint('[SherpaASR] Force offline set to: $value');
  }

  Future<void> setModel(String modelId) async {
    if (_currentModelId == modelId) return;
    _currentModelId = modelId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelPrefKey, modelId);
    _resetRecognizer();
    debugPrint('[SherpaASR] Model switched to: $modelId');
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
    _currentModelId = prefs.getString(_modelPrefKey) ?? 'sensevoice';
    debugPrint('[SherpaASR] Config loaded: forceOffline=$_forceOffline, model=$_currentModelId');
  }

  static const _ossBase = 'https://app-oss-endpoint.dapangyu.work/models';

  Future<String> _getModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/sherpa_models/${currentModel.ossPath}';
  }

  Future<bool> isModelReady([String? modelId]) async {
    final model = modelId != null ? getAsrModelById(modelId) : currentModel;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = '${appDir.path}/sherpa_models/${model.ossPath}';
    for (final file in model.files.values) {
      if (!File('$dir/$file').existsSync()) return false;
    }
    return true;
  }

  Future<bool> downloadModels([String? modelId]) async {
    final model = modelId != null ? getAsrModelById(modelId) : currentModel;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = '${appDir.path}/sherpa_models/${model.ossPath}';
      await Directory(dir).create(recursive: true);
      final dio = Dio();

      for (final entry in model.files.entries) {
        final file = File('$dir/${entry.value}');
        if (file.existsSync() && file.lengthSync() > 100) {
          continue;
        }

        final url = '$_ossBase/${model.ossPath}/${entry.value}';
        debugPrint('[SherpaASR] Downloading ${entry.value} ...');
        onStatusChange?.call('下载 ${model.name}: ${entry.value}');

        await dio.download(
          url,
          file.path,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final pct = (received / total * 100).toStringAsFixed(0);
              onStatusChange?.call('下载 ${model.name}: $pct%');
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
      final model = currentModel;

      final config = sherpa.OfflineRecognizerConfig(
        model: _buildModelConfig(dir, model),
      );
      _recognizer = sherpa.OfflineRecognizer(config);

      _initialized = true;
      debugPrint('[SherpaASR] Recognizer initialized (${model.name})');
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Init error: $e');
      return false;
    }
  }

  sherpa.OfflineModelConfig _buildModelConfig(String dir, AsrModel model) {
    switch (model.modelType) {
      case 'senseVoice':
        return sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: '$dir/${model.files['model']!}',
            language: 'auto',
            useInverseTextNormalization: true,
          ),
          tokens: '$dir/${model.files['tokens']!}',
          modelType: 'senseVoice',
          numThreads: 2,
          debug: false,
        );

      case 'qwen3Asr':
        return sherpa.OfflineModelConfig(
          qwen3Asr: sherpa.OfflineQwen3AsrModelConfig(
            convFrontend: '$dir/${model.files['conv_frontend']!}',
            encoder: '$dir/${model.files['encoder']!}',
            decoder: '$dir/${model.files['decoder']!}',
            tokenizer: '$dir/${model.files['tokenizer']!}',
          ),
          tokens: '$dir/${model.files['tokens']!}',
          modelType: 'qwen3Asr',
          numThreads: 2,
          debug: false,
        );

      case 'funasrNano':
        return sherpa.OfflineModelConfig(
          funasrNano: sherpa.OfflineFunAsrNanoModelConfig(
            encoderAdaptor: '$dir/${model.files['encoder_adaptor']!}',
            llm: '$dir/${model.files['llm']!}',
            embedding: '$dir/${model.files['embedding']!}',
            tokenizer: '$dir/${model.files['tokenizer']!}',
            language: 'auto',
          ),
          tokens: '$dir/${model.files['tokens']!}',
          modelType: 'funasrNano',
          numThreads: 2,
          debug: false,
        );

      default:
        throw Exception('Unknown model type: ${model.modelType}');
    }
  }

  Future<bool> ensureReady() async {
    await loadConfig();
    if (_initialized && _recognizer != null) return true;

    if (!await isModelReady()) {
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
