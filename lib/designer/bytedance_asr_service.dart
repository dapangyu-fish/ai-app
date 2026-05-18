import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../i18n/framework_strings.dart';

/// 豆包ASR服务 - 字节跳动语音识别
class ByteDanceAsrService {
  static ByteDanceAsrService? _instance;
  static ByteDanceAsrService get instance => _instance ??= ByteDanceAsrService._();
  ByteDanceAsrService._();

  // Socket.IO 客户端
  IO.Socket? _socket;

  // 录音器
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _audioSub;
  Timer? _sendTimer;

  // 状态
  bool _isConnected = false;
  bool _isRecording = false;

  // 音频缓冲区
  final List<Uint8List> _audioBuffer = [];

  // 回调
  void Function(String status)? onStatusChange;
  void Function(String text)? onResult;
  void Function(String error)? onError;
  void Function(Map<String, dynamic> quota)? onQuotaUpdate;

  bool get isConnected => _isConnected;
  bool get isRecording => _isRecording;

  /// 连接到服务器
  Future<bool> connect(String serverUrl, String token) async {
    if (_isConnected) {
      debugPrint('[ByteDanceASR] Already connected');
      return true;
    }

    try {
      debugPrint('[ByteDanceASR] Connecting to $serverUrl');

      _socket = IO.io(serverUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'query': {'token': token}, // 通过 query 传递 token
      });

      _socket!.onConnect((_) {
        debugPrint('[ByteDanceASR] Connected to server');
        _isConnected = true;
        onStatusChange?.call(T.current.asrBytedanceConnected);
      });

      _socket!.onDisconnect((_) {
        debugPrint('[ByteDanceASR] Disconnected from server');
        _isConnected = false;
        onStatusChange?.call(T.current.asrBytedanceDisconnected);
      });

      _socket!.on('asr_connected', (data) {
        debugPrint('[ByteDanceASR] Server confirmed connection: $data');
      });

      _socket!.on('asr_started', (data) {
        debugPrint('[ByteDanceASR] Recognition started: $data');
        if (data is Map && data['quota'] != null) {
          onQuotaUpdate?.call(Map<String, dynamic>.from(data['quota']));
        }
      });

      _socket!.on('asr_result', (data) {
        debugPrint('[ByteDanceASR] Received result: $data');
        if (data is Map && data['text'] != null) {
          onResult?.call(data['text']);
        }
      });

      _socket!.on('asr_error', (data) {
        debugPrint('[ByteDanceASR] Error: $data');
        if (data is Map) {
          final message = data['message'] ?? data['error'] ?? T.current.asrErrUnknown;
          onError?.call(message);

          // 如果有配额信息，也更新
          if (data['quota'] != null) {
            onQuotaUpdate?.call(Map<String, dynamic>.from(data['quota']));
          }
        }
      });

      // 等待连接成功
      await Future.delayed(const Duration(milliseconds: 500));

      return _isConnected;
    } catch (e) {
      debugPrint('[ByteDanceASR] Connect error: $e');
      onError?.call(T.fmt(T.current.asrBytedanceConnectFailedWith, {'err': e}));
      return false;
    }
  }

  /// 开始录音识别
  Future<bool> startListening() async {
    if (!_isConnected || _isRecording) {
      debugPrint('[ByteDanceASR] Cannot start: connected=$_isConnected, recording=$_isRecording');
      return false;
    }

    debugPrint('[ByteDanceASR] Starting recording...');

    // 检查麦克风权限
    if (!await _recorder.hasPermission()) {
      onError?.call(T.current.asrErrMicPermissionDeniedShort);
      return false;
    }

    // 通知服务器开始识别（会检查配额）
    _socket!.emit('asr_start', {});

    // 清空缓冲区
    _audioBuffer.clear();

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
          debugPrint('[ByteDanceASR] Audio stream error: $e');
          onError?.call(T.fmt(T.current.asrRecordErrorWith, {'err': e}));
        },
      );

      // 启动定时发送任务（每 400ms 发送一次）
      _sendTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        _sendAudioBuffer();
      });

      _isRecording = true;
      onStatusChange?.call(T.current.asrRecording);

      debugPrint('[ByteDanceASR] Recording started');
      return true;
    } catch (e) {
      debugPrint('[ByteDanceASR] Start recording error: $e');
      onError?.call(T.fmt(T.current.asrRecordStartFailWith, {'err': e}));
      return false;
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
    _socket!.emit('asr_audio', {
      'type': 'audio',
      'data': base64Audio,
      'is_last': false,
    });

    debugPrint('[ByteDanceASR] Sent audio chunk: ${combined.length} bytes');
  }

  /// 停止录音识别
  Future<void> stopListening() async {
    if (!_isRecording) return;

    debugPrint('[ByteDanceASR] Stopping recording...');

    // 停止定时器
    _sendTimer?.cancel();
    _sendTimer = null;

    // 发送最后一包音频
    _sendAudioBuffer();

    // 发送结束标记
    _socket!.emit('asr_audio', {
      'type': 'audio',
      'data': '',
      'is_last': true,
    });

    // 停止录音
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    _isRecording = false;
    onStatusChange?.call(T.current.asrBytedanceConnected);

    debugPrint('[ByteDanceASR] Recording stopped');
  }

  /// 断开连接
  void disconnect() {
    if (_isRecording) {
      stopListening();
    }

    _socket?.emit('asr_disconnect', {});
    _socket?.dispose();
    _socket = null;
    _isConnected = false;

    debugPrint('[ByteDanceASR] Disconnected');
  }

  /// 清理资源
  void dispose() {
    disconnect();
    _sendTimer?.cancel();
    _audioSub?.cancel();
    _recorder.dispose();
  }
}
