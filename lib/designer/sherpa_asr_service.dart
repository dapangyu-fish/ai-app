import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AsrModelInfo {
  final String id;
  final String name;
  final String ossPath;
  final String modelType;
  final Map<String, String> files;
  final bool isStreaming;

  const AsrModelInfo({
    required this.id,
    required this.name,
    required this.ossPath,
    required this.modelType,
    required this.files,
    this.isStreaming = false,
  });
}

class SherpaAsrService {
  static SherpaAsrService? _instance;
  static SherpaAsrService get instance => _instance ??= SherpaAsrService._();
  SherpaAsrService._();

  static const _ossBase = 'https://app-oss-endpoint.dapangyu.work/models';
  static const _modelKey = 'asr_model_id';

  static const List<AsrModelInfo> availableModels = [
    AsrModelInfo(
      id: 'sensevoice',
      name: 'SenseVoice',
      ossPath: 'sherpa-onnx/sensevoice-zh-en-ja-ko-yue-int8',
      modelType: 'senseVoice',
      files: {
        'model': 'model.int8.onnx',
        'tokens': 'tokens.txt',
      },
    ),
    AsrModelInfo(
      id: 'qwen3-asr',
      name: 'Qwen3 ASR',
      ossPath: 'sherpa-onnx/qwen3-asr-0.6B-int8',
      modelType: 'qwen3Asr',
      files: {
        'conv_frontend': 'conv_frontend.onnx',
        'encoder': 'encoder.int8.onnx',
        'decoder': 'decoder.int8.onnx',
        'tokenizer_vocab': 'tokenizer/vocab.json',
        'tokenizer_config': 'tokenizer/tokenizer_config.json',
        'tokenizer_merges': 'tokenizer/merges.txt',
      },
    ),
    AsrModelInfo(
      id: 'funasr-nano',
      name: 'FunASR Nano',
      ossPath: 'sherpa-onnx/funasr-nano-int8',
      modelType: 'funasrNano',
      files: {
        'encoder_adaptor': 'encoder_adaptor.int8.onnx',
        'llm': 'llm.int8.onnx',
        'embedding': 'embedding.int8.onnx',
        'qwen_vocab': 'Qwen3-0.6B/vocab.json',
        'qwen_merges': 'Qwen3-0.6B/merges.txt',
        'qwen_tokenizer': 'Qwen3-0.6B/tokenizer.json',
      },
    ),
    AsrModelInfo(
      id: 'streaming-zipformer',
      name: 'Zipformer Streaming (中英)',
      ossPath: 'sherpa-onnx/streaming-zipformer-small-bilingual-zh-en-int8',
      modelType: 'streamingZipformer',
      isStreaming: true,
      files: {
        'encoder': 'encoder-epoch-99-avg-1.int8.onnx',
        'decoder': 'decoder-epoch-99-avg-1.int8.onnx',
        'joiner': 'joiner-epoch-99-avg-1.int8.onnx',
        'tokens': 'tokens.txt',
      },
    ),
  ];

  bool _forceOffline = false;
  String _selectedModelId = 'sensevoice';

  sherpa.OfflineRecognizer? _recognizer;
  sherpa.OnlineRecognizer? _onlineRecognizer;
  sherpa.OnlineStream? _onlineStream;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _audioSub;
  Timer? _decodeTimer;
  bool _initialized = false;

  List<double> _audioBuffer = [];
  String currentText = '';

  void Function(String status)? onStatusChange;
  void Function(String text)? onResult;

  bool get forceOffline => _forceOffline;
  String get selectedModelId => _selectedModelId;

  AsrModelInfo get _currentModel =>
      availableModels.firstWhere((m) => m.id == _selectedModelId,
          orElse: () => availableModels.first);

  Future<void> setForceOffline(bool value) async {
    _forceOffline = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('force_offline_asr', value);
    debugPrint('[SherpaASR] Force offline set to: $value');
  }

  Future<void> setModel(String modelId) async {
    if (_selectedModelId == modelId) return;
    _selectedModelId = modelId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelKey, modelId);
    _resetRecognizer();
    debugPrint('[SherpaASR] Model switched to: $modelId');
  }

  void _resetRecognizer() {
    try { _recognizer?.free(); } catch (_) {}
    _recognizer = null;
    try { _onlineStream?.free(); } catch (_) {}
    _onlineStream = null;
    try { _onlineRecognizer?.free(); } catch (_) {}
    _onlineRecognizer = null;
    _initialized = false;
    _audioBuffer = [];
  }

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _forceOffline = prefs.getBool('force_offline_asr') ?? false;
    _selectedModelId = prefs.getString(_modelKey) ?? 'sensevoice';
    debugPrint(
        '[SherpaASR] Config loaded: forceOffline=$_forceOffline, model=$_selectedModelId');
  }

  Future<String> _getModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/sherpa_models/${_currentModel.ossPath}';
  }

  Future<bool> get isModelReady async {
    final dir = await _getModelDir();
    for (final file in _currentModel.files.values) {
      if (!File('$dir/$file').existsSync()) return false;
    }
    return true;
  }

  Future<bool> downloadModels() async {
    try {
      final model = _currentModel;
      final dir = await _getModelDir();
      await Directory(dir).create(recursive: true);
      final dio = Dio();

      for (final entry in model.files.entries) {
        final file = File('$dir/${entry.value}');
        if (file.existsSync() && file.lengthSync() > 100) {
          continue;
        }

        await file.parent.create(recursive: true);
        final url = '$_ossBase/${model.ossPath}/${entry.value}';
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

        debugPrint(
            '[SherpaASR] Downloaded ${entry.value}: ${file.lengthSync()} bytes');
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
      final model = _currentModel;

      if (model.isStreaming) {
        return _initStreaming(dir, model);
      }

      final sherpa.OfflineRecognizerConfig config;

      switch (model.modelType) {
        case 'senseVoice':
          config = sherpa.OfflineRecognizerConfig(
            model: sherpa.OfflineModelConfig(
              senseVoice: sherpa.OfflineSenseVoiceModelConfig(
                model: '$dir/${model.files['model']!}',
                language: 'auto',
                useInverseTextNormalization: true,
              ),
              tokens: '$dir/${model.files['tokens']!}',
              modelType: 'senseVoice',
              numThreads: 2,
              debug: false,
            ),
          );
          break;

        case 'qwen3Asr':
          config = sherpa.OfflineRecognizerConfig(
            model: sherpa.OfflineModelConfig(
              qwen3Asr: sherpa.OfflineQwen3AsrModelConfig(
                convFrontend: '$dir/${model.files['conv_frontend']!}',
                encoder: '$dir/${model.files['encoder']!}',
                decoder: '$dir/${model.files['decoder']!}',
                tokenizer: '$dir/tokenizer',
              ),
              tokens: '',
              modelType: 'qwen3_asr',
              numThreads: 2,
              debug: false,
            ),
          );
          break;

        case 'funasrNano':
          config = sherpa.OfflineRecognizerConfig(
            model: sherpa.OfflineModelConfig(
              funasrNano: sherpa.OfflineFunAsrNanoModelConfig(
                encoderAdaptor: '$dir/${model.files['encoder_adaptor']!}',
                llm: '$dir/${model.files['llm']!}',
                embedding: '$dir/${model.files['embedding']!}',
                tokenizer: '$dir/${model.files['qwen_tokenizer']!}',
              ),
              tokens: '',
              modelType: 'funasr_nano',
              numThreads: 2,
              debug: false,
            ),
          );
          break;

        default:
          debugPrint('[SherpaASR] Unknown model type: ${model.modelType}');
          return false;
      }

      _recognizer = sherpa.OfflineRecognizer(config);
      _initialized = true;
      debugPrint('[SherpaASR] Recognizer initialized (${model.id})');
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Init error: $e');
      return false;
    }
  }

  Future<bool> _initStreaming(String dir, AsrModelInfo model) async {
    try {
      final config = sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$dir/${model.files['encoder']!}',
            decoder: '$dir/${model.files['decoder']!}',
            joiner: '$dir/${model.files['joiner']!}',
          ),
          tokens: '$dir/${model.files['tokens']!}',
          modelType: 'zipformer2',
          numThreads: 2,
          debug: false,
        ),
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.2,
        rule3MinUtteranceLength: 20,
      );
      _onlineRecognizer = sherpa.OnlineRecognizer(config);
      _initialized = true;
      debugPrint('[SherpaASR] Online recognizer initialized (${model.id})');
      return true;
    } catch (e) {
      debugPrint('[SherpaASR] Streaming init error: $e');
      return false;
    }
  }

  Future<bool> ensureReady() async {
    await loadConfig();
    if (_initialized && (_recognizer != null || _onlineRecognizer != null)) {
      return true;
    }

    if (!await isModelReady) {
      final ok = await downloadModels();
      if (!ok) return false;
    }

    return await initialize();
  }

  Future<bool> startListening() async {
    if (_recognizer == null && _onlineRecognizer == null) return false;

    currentText = '';
    _audioBuffer = [];

    if (_currentModel.isStreaming && _onlineRecognizer != null) {
      _onlineStream = _onlineRecognizer!.createStream();
    }

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

    if (_currentModel.isStreaming && _onlineStream != null) {
      final samples = Float32List(sampleCount);
      for (int i = 0; i < sampleCount; i++) {
        samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
      }
      _onlineStream!.acceptWaveform(samples: samples, sampleRate: 16000);
    } else {
      for (int i = 0; i < sampleCount; i++) {
        final int16 = byteData.getInt16(i * 2, Endian.little);
        _audioBuffer.add(int16 / 32768.0);
      }
    }
  }

  void _decodeAndReport() {
    if (_currentModel.isStreaming) {
      _decodeStreaming();
    } else {
      _decodeOffline();
    }
  }

  void _decodeStreaming() {
    if (_onlineRecognizer == null || _onlineStream == null) return;
    while (_onlineRecognizer!.isReady(_onlineStream!)) {
      _onlineRecognizer!.decode(_onlineStream!);
    }
    final result = _onlineRecognizer!.getResult(_onlineStream!);
    if (result.text.isNotEmpty && result.text != currentText) {
      currentText = result.text;
      onResult?.call(currentText);
    }
  }

  void _decodeOffline() {
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

    if (_currentModel.isStreaming && _onlineRecognizer != null && _onlineStream != null) {
      _onlineStream!.inputFinished();
      while (_onlineRecognizer!.isReady(_onlineStream!)) {
        _onlineRecognizer!.decode(_onlineStream!);
      }
      final result = _onlineRecognizer!.getResult(_onlineStream!);
      if (result.text.isNotEmpty) {
        currentText = result.text;
      }
      _onlineStream!.free();
      _onlineStream = null;
    } else if (_recognizer != null && _audioBuffer.isNotEmpty) {
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
