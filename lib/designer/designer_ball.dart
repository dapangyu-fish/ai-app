import 'dart:async';
import 'dart:math' show sqrt, pi;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'ai_chat_service.dart';
import 'chat_overlay.dart';
import 'sherpa_asr_service.dart';
import 'gesture_exclusion_helper.dart';

/// 悬浮设计师球 — iOS 风格丝滑拖拽 + 长按对话模式。
/// 凌驾于所有页面之上，不影响 JSON APP。
class DesignerBall extends StatefulWidget {
  final Widget child;
  final void Function(Map<String, dynamic> jsonConfig)? onRunJsonApp;
  /// 获取当前运行中的 JSON-APP 配置（用于对话上下文）
  final Map<String, dynamic>? Function()? getCurrentConfig;

  /// 崩溃分析回调 — 由 _CrashPage 调用，自动进入对话模式发送崩溃报告
  static void Function(String crashReport)? sendCrashReport;

  const DesignerBall({super.key, required this.child, this.onRunJsonApp, this.getCurrentConfig});

  @override
  State<DesignerBall> createState() => _DesignerBallState();
}

class _DesignerBallState extends State<DesignerBall>
    with TickerProviderStateMixin {
  // ── 尺寸常量 ──
  static const double _ballSize = 64.0;
  static const double _peekSize = 22.0;
  static const double _edgeThreshold = 20.0;
  static const double _dragThreshold = 30.0;

  // ── 拖拽状态 ──
  double _left = 0;
  double _top = 0;
  bool _positioned = false;
  bool _hidden = false;
  _HideEdge _hideEdge = _HideEdge.none;
  bool _dragging = false;
  Offset _pointerDownPos = Offset.zero;
  bool _movedEnough = false;
  bool _pointerDown = false;
  bool _revealing = false; // 正在从边缘露出动画中，阻止拖拽
  double _accumulatedDragDistance = 0; // 累积拖拽路径长度

  // ── 动画 ──
  late AnimationController _animController;
  Animation<double>? _animLeft;
  Animation<double>? _animTop;

  // ── 长按对话 ──
  static const Duration _longPressDuration = Duration(seconds: 2);
  Timer? _longPressTimer;
  bool _chatMode = false;
  bool _isListening = false;
  bool _isThinking = false;
  bool _isGeneratingJson = false;
  String? _liveTranscript;
  String _accumulatedTranscript = ''; // 累积的已确认文本（用于多段识别）

  // ── 录音拖拽取消 ──
  Offset? _recordStartPos;
  bool _dragCancelling = false;
  bool _dragInEditZone = false;
  static const double _cancelBottomZoneHeight = 120.0;

  // ── 编辑模式 ──
  bool _editMode = false;
  final TextEditingController _editTextController = TextEditingController();

  // ── 脉冲动画（录音中） ──
  late AnimationController _pulseController;

  // ── 长按倒计时动画 ──
  late AnimationController _countdownController;

  // ── 语音识别 & AI ──
  stt.SpeechToText? _speech;
  bool _speechInited = false;
  bool _nativeSpeechReceivedCallback = false; // 标记原生识别是否收到过回调
  bool get _useSherpaAsr => _sherpaAsr.forceOffline; // 现在从 SherpaService 读取状态
  final SherpaAsrService _sherpaAsr = SherpaAsrService.instance;
  final AiChatService _chatService = AiChatService();
  StreamSubscription<ChatEvent>? _streamSub;
  Map<String, dynamic>? _lastGeneratedJson; // ignore: unused_field — Phase 3 试运行用
  Map<String, dynamic>? _lastQuota; // ignore: unused_field — Phase 3 配额显示用
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _animController.addListener(() {
      setState(() {
        if (_animLeft != null) _left = _animLeft!.value;
        if (_animTop != null) _top = _animTop!.value;
      });
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _countdownController = AnimationController(
      vsync: this,
      duration: _longPressDuration,
    );

    // 注册崩溃分析回调
    DesignerBall.sendCrashReport = _handleCrashReport;
    // 加载配置
    _sherpaAsr.loadConfig().then((_) {
      setState(() {});
    });
  }

  /// 切换强制离线模式
  Future<void> _toggleForceOffline(bool value) async {
    await _sherpaAsr.setForceOffline(value);
    setState(() {});
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _streamSub?.cancel();
    _sherpaAsr.dispose();
    _chatService.abort();
    _animController.dispose();
    _pulseController.dispose();
    _countdownController.dispose();
    _editTextController.dispose();
    _speech?.stop();
    _scrollController.dispose();
    super.dispose();
  }

  void _initPosition(Size screenSize) {
    if (!_positioned) {
      _left = screenSize.width - _ballSize - 16;
      _top = screenSize.height * 0.65;
      _positioned = true;
    }
  }

  // ════════════════════════════════════════════════════════
  // Android 系统手势排除
  // ════════════════════════════════════════════════════════

  /// 更新 Android 系统手势排除区域，确保悬浮球区域不触发系统返回手势
  void _updateGestureExclusion() {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    GestureExclusionHelper.setExclusionRect(
      left: _left,
      top: _top,
      width: _ballSize,
      height: _ballSize,
      devicePixelRatio: dpr,
    );
  }

  // ════════════════════════════════════════════════════════
  // 原始指针事件 — 用 Listener 捕获，不受手势竞技场影响
  // ════════════════════════════════════════════════════════

  void _onPointerDown(PointerDownEvent event) {
    _pointerDownPos = event.position;
    _animController.stop();
    _accumulatedDragDistance = 0; // 重置累积拖拽距离

    // 触觉反馈：按下时中等震动
    HapticFeedback.mediumImpact();

    // 设置系统手势排除区域，防止拖拽时触发 Android 系统返回
    _updateGestureExclusion();

    // 隐藏态：先触发露出动画，阻止拖拽（避免触发系统返回手势）
    if (_hidden) {
      final screenSize = MediaQuery.of(context).size;
      setState(() {
        _pointerDown = true;
        _movedEnough = false;
        _revealing = true;
      });
      _revealFromEdge(screenSize);
      return; // 不启动长按计时器，等露出后用户再操作
    }

    setState(() {
      _pointerDown = true;
      _movedEnough = false;
    });

    if (_chatMode) {
      // 对话模式 → 短延时后开始录音，移动了就当拖拽
      _longPressTimer?.cancel();
      _longPressTimer = Timer(const Duration(milliseconds: 300), () {
        if (_pointerDown && !_movedEnough) {
          _startListening();
        }
      });
    } else {
      // 开始长按倒计时（2 秒）
      _longPressTimer?.cancel();
      _countdownController.forward(from: 0);
      _longPressTimer = Timer(_longPressDuration, () {
        if (_pointerDown && !_movedEnough) {
          _enterChatMode();
        }
      });
    }
  }

  void _onPointerUp(PointerUpEvent event, Size screenSize) {
    setState(() => _pointerDown = false);
    _longPressTimer?.cancel();
    GestureExclusionHelper.clearExclusionRects();
    _countdownController.stop();
    _countdownController.reset();

    if (_isListening) {
      _movedEnough = false;
      if (_dragCancelling) {
        _cancelRecording();
      } else if (_dragInEditZone) {
        _enterEditMode();
      } else {
        _stopListeningAndSend();
      }
      if (_recordStartPos != null) {
        _animateTo(_recordStartPos!.dx, _recordStartPos!.dy);
        _recordStartPos = null;
      }
      _dragCancelling = false;
      _dragInEditZone = false;
    } else {
      // 非录音态：处理拖拽收尾（吸边等）
      _handleDragEnd(screenSize);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    setState(() => _pointerDown = false);
    _longPressTimer?.cancel();
    GestureExclusionHelper.clearExclusionRects();
    _countdownController.stop();
    _countdownController.reset();

    if (_isListening) {
      _movedEnough = false;
      _cancelRecording();
      if (_recordStartPos != null) {
        _animateTo(_recordStartPos!.dx, _recordStartPos!.dy);
        _recordStartPos = null;
      }
    }
  }

  // ════════════════════════════════════════════════════════
  // Pointer Move — 直接在 Listener 层处理，消除手势竞技场延迟
  // ════════════════════════════════════════════════════════

  void _onPointerMove(PointerMoveEvent event, Size screenSize) {
    // 露出动画进行中，忽略拖拽
    if (_revealing) return;

    final delta = (event.position - _pointerDownPos).distance;
    if (delta > _dragThreshold && !_chatMode) {
      _movedEnough = true;
      _longPressTimer?.cancel();
      _countdownController.stop();
      _countdownController.reset();
    }

    final dx = event.delta.dx;
    final dy = event.delta.dy;

    // 拖拽震动：累积实际移动的路径长度，每 15 像素触发一次震动
    final moveDelta = sqrt(dx * dx + dy * dy);
    _accumulatedDragDistance += moveDelta;
    if (_accumulatedDragDistance >= 15) {
      HapticFeedback.selectionClick();
      _accumulatedDragDistance -= 15; // 减去触发阈值，保留余数
    }

    if (_isListening) {
      setState(() {
        _left += dx;
        _top += dy;
        _left = _left.clamp(-_ballSize * 0.5, screenSize.width - _ballSize * 0.5);
        _top = _top.clamp(-_ballSize * 0.5, screenSize.height - _ballSize * 0.5);

        if (_recordStartPos != null) {
          _dragCancelling = _isInCancelZone(screenSize);
          _dragInEditZone = _isInEditZone(screenSize);
        }
      });
      return;
    }

    _dragging = true;
    setState(() {
      _left += dx;
      _top += dy;
      _left = _left.clamp(-_ballSize * 0.5, screenSize.width - _ballSize * 0.5);
      _top = _top.clamp(-_ballSize * 0.5, screenSize.height - _ballSize * 0.5);
    });
  }

  void _handleDragEnd(Size screenSize) {
    _dragging = false;

    // 如果没移动过（纯长按），不做拖拽收尾
    if (!_movedEnough) return;

    _HideEdge edge = _HideEdge.none;
    if (_left <= _edgeThreshold) {
      edge = _HideEdge.left;
    } else if (_left + _ballSize >= screenSize.width - _edgeThreshold) {
      edge = _HideEdge.right;
    } else if (_top <= _edgeThreshold) {
      edge = _HideEdge.top;
    } else if (_top + _ballSize >= screenSize.height - _edgeThreshold) {
      edge = _HideEdge.bottom;
    }

    if (edge == _HideEdge.left || edge == _HideEdge.right) {
      // 左右边缘：吸附到边缘但不隐藏，避免与 Android 系统返回手势冲突
      final targetLeft = edge == _HideEdge.left ? 0.0 : screenSize.width - _ballSize;
      final targetTop = _top.clamp(0.0, screenSize.height - _ballSize);
      _animateTo(targetLeft, targetTop);
    } else if (edge != _HideEdge.none) {
      _hideToEdge(edge, screenSize);
    } else {
      final clampedLeft = _left.clamp(0.0, screenSize.width - _ballSize);
      final clampedTop = _top.clamp(0.0, screenSize.height - _ballSize);
      if (clampedLeft != _left || clampedTop != _top) {
        _animateTo(clampedLeft, clampedTop);
      }
    }
  }

  void _onTap(Size screenSize) {
    if (_hidden) {
      _revealFromEdge(screenSize);
    }
  }

  void _onDoubleTap() {
    if (_chatMode) return;
    if (_messages.isEmpty) return;
    setState(() => _chatMode = true);
    _scrollToBottom();
  }

  // ════════════════════════════════════════════════════════
  // 对话模式
  // ════════════════════════════════════════════════════════

  void _onProviderChanged(String providerId) {
    AiChatService.setProvider(providerId);
    setState(() {});
  }

  Future<void> _enterChatMode() async {
    debugPrint('[DesignerBall] _enterChatMode called');

    // 进入对话模式的重震动反馈
    HapticFeedback.heavyImpact();

    // 后台拉取供应商列表（不阻塞进入对话模式）
    AiChatService.fetchProviders().then((_) {
      if (mounted) setState(() {});
    });

    debugPrint('[DesignerBall] 初始状态: forceOffline=$_useSherpaAsr, speechInited=$_speechInited');

    if (!_speechInited && !_useSherpaAsr) {
      try {
        _speech ??= stt.SpeechToText();
        _speechInited = await _speech!.initialize(
          onError: (error) {
            debugPrint('[DesignerBall] Speech error: ${error.errorMsg}');
            if (error.errorMsg == 'error_network') {
              _handleNetworkError();
            } else if (error.errorMsg == 'error_speech_timeout') {
              // 场景1修复：原生平台超时（用户长时间不说话）
              // 如果用户还在按住球，重新启动监听
              if (_isListening && _pointerDown && !_useSherpaAsr) {
                debugPrint('[DesignerBall] 原生平台超时，重新启动监听');
                Future.delayed(const Duration(milliseconds: 100), () {
                  if (_isListening && _pointerDown && !_useSherpaAsr) {
                    _startNativeSpeech();
                  }
                });
              }
            }
          },
          onStatus: (status) => debugPrint('[DesignerBall] Speech status: $status'),
        );
        debugPrint('[DesignerBall] Native speech init: $_speechInited');
      } catch (e) {
        debugPrint('[DesignerBall] Native speech failed: $e');
        _speechInited = false;
      }

      // 手已离开 → 中止
      if (!_pointerDown) {
        debugPrint('[DesignerBall] Pointer lifted during speech init, aborting');
        return;
      }

      if (!_speechInited) {
        setState(() {
          _messages.add(ChatMessage(role: 'assistant', content: '原生语音识别初始化失败，请在设置中开启"强制离线模式"'));
        });
        return;
      }
    }

    final shouldUseSherpa = _useSherpaAsr;
    debugPrint('[DesignerBall] 最终决策: ${shouldUseSherpa ? "离线模式(sherpa)" : "在线模式(native speech)"}');

    if (shouldUseSherpa) {
      setState(() {
        _chatMode = true;
        _isThinking = true;
      });
      _sherpaAsr.onStatusChange = (status) {
        setState(() {
          _liveTranscript = status;
        });
      };
      final ready = await _sherpaAsr.ensureReady();
      _sherpaAsr.onStatusChange = null;

      // 手已离开 → 中止
      if (!_pointerDown) {
        debugPrint('[DesignerBall] Pointer lifted during sherpa init, aborting');
        setState(() {
          _isThinking = false;
          _liveTranscript = null;
        });
        return;
      }

      if (!ready) {
        setState(() {
          _isThinking = false;
          _liveTranscript = null;
          _messages.add(ChatMessage(role: 'assistant', content: '离线语音模型加载失败'));
        });
        return;
      }
      setState(() => _isThinking = false);
    }

    // 最终检查：手已离开 → 只设置 chatMode 但不开始录音
    setState(() => _chatMode = true);
    if (!_pointerDown) {
      debugPrint('[DesignerBall] Pointer lifted before startListening, skipping');
      return;
    }
    _startListening();
  }

  void _startListening() {
    _recordStartPos = Offset(_left, _top);
    _dragCancelling = false;
    _nativeSpeechReceivedCallback = false; // 重置回调标记
    _accumulatedTranscript = ''; // 清空累积文本
    setState(() {
      _isListening = true;
      _liveTranscript = '';
    });
    _pulseController.repeat(reverse: true);

    final shouldUseSherpa = _useSherpaAsr;
    debugPrint('[DesignerBall] ASR决策: forceOffline=$_useSherpaAsr → ${shouldUseSherpa ? "离线(sherpa)" : "在线(native)"}');
    if (shouldUseSherpa) {
      _startSherpaAsr();
    } else {
      _startNativeSpeech();
    }
  }

  bool _isInCancelZone(Size screenSize) {
    final ballBottomY = _top + _ballSize;
    final ballCenterX = _left + _ballSize / 2;
    return ballBottomY >= screenSize.height - _cancelBottomZoneHeight &&
        ballCenterX < screenSize.width / 2;
  }

  bool _isInEditZone(Size screenSize) {
    final ballBottomY = _top + _ballSize;
    final ballCenterX = _left + _ballSize / 2;
    return ballBottomY >= screenSize.height - _cancelBottomZoneHeight &&
        ballCenterX >= screenSize.width / 2;
  }

  void _cancelRecording() {
    debugPrint('[DesignerBall] Recording cancelled by drag');
    final shouldUseSherpa = _useSherpaAsr;
    if (shouldUseSherpa) {
      _sherpaAsr.stopListening();
      _sherpaAsr.onResult = null;
    } else {
      try { _speech?.stop(); } catch (_) {}
    }
    _pulseController.stop();
    _pulseController.reset();
    setState(() {
      _isListening = false;
      _liveTranscript = null;
      _dragCancelling = false;
      _dragInEditZone = false;
    });
  }

  void _enterEditMode() {
    debugPrint('[DesignerBall] Entering edit mode');
    final shouldUseSherpa = _useSherpaAsr;
    String finalText = _liveTranscript?.trim() ?? '';

    if (shouldUseSherpa) {
      _sherpaAsr.stopListening().then((sherpaText) {
        if (sherpaText.isNotEmpty) finalText = sherpaText;
        _editTextController.text = finalText;
      });
      _sherpaAsr.onResult = null;
    } else {
      try { _speech?.stop(); } catch (_) {}
      _editTextController.text = finalText;
    }

    _pulseController.stop();
    _pulseController.reset();
    setState(() {
      _isListening = false;
      _liveTranscript = null;
      _dragCancelling = false;
      _dragInEditZone = false;
      _editMode = true;
      _editTextController.text = finalText;
    });
  }

  void _sendEditedText() {
    final text = _editTextController.text.trim();
    setState(() => _editMode = false);
    _editTextController.clear();

    if (text.isEmpty) return;

    _sendTextToAi(text);
  }

  void _sendTextToAi(String displayText, {String? hiddenText}) {
    _cancelCurrentStream();

    setState(() {
      _messages.add(ChatMessage(role: 'user', content: displayText));
      _messages.add(ChatMessage(role: 'assistant', content: ''));
      _isThinking = true;
    });
    _scrollToBottom();

    _streamSub = _chatService.sendStream(hiddenText ?? displayText).listen(
      (event) {
        if (event.isGeneratingJson) {
          setState(() {
            _isGeneratingJson = true;
          });
          _scrollToBottom();
          return;
        }
        if (event.error != null && event.content == null) {
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            _messages.last = ChatMessage(role: 'assistant', content: event.error!);
          });
          _scrollToBottom();
          return;
        }
        if (event.requestAction != null) {
          if (event.requestAction == 'upload_current_app') {
            setState(() {
              _isThinking = false;
              // 替换当前等待消息为按钮消息
              _messages.last = ChatMessage(
                role: 'system',
                content: 'AI 需要获取当前应用的代码配置以进行修改：',
                action: 'UPLOAD_CURRENT_APP',
              );
            });
            _scrollToBottom();
          }
          return;
        }
        if (event.thinking != null) {
          // 思考过程 → 更新最后一条消息显示思考状态
          setState(() {
            _isThinking = false;
            final preview = event.thinking!.length > 100
                ? '${event.thinking!.substring(0, 100)}...'
                : event.thinking!;
            _messages.last = ChatMessage(role: 'assistant', content: '💭 $preview');
          });
          _scrollToBottom();
          return;
        }
        if (event.content != null) {
          setState(() {
            _isThinking = false;
            _messages.last = ChatMessage(role: 'assistant', content: event.content!);
          });
          _scrollToBottom();
        }
        if (event.jsonApp != null) {
          _lastGeneratedJson = event.jsonApp;
          setState(() {
            _isGeneratingJson = false;
            _messages.add(ChatMessage(
              role: 'system',
              content: '🚀 JSON-APP 已生成，点击试运行',
              jsonApp: event.jsonApp,
            ));
          });
          _scrollToBottom();
        }
        if (event.quota != null) {
          _lastQuota = event.quota;
        }
      },
      onError: (e) {
        setState(() {
          _isThinking = false;
          _isGeneratingJson = false;
          _messages.last = ChatMessage(role: 'assistant', content: '出错了: $e');
        });
      },
    );
  }

  Future<void> _handleUploadCurrentApp() async {
    final config = widget.getCurrentConfig?.call();
    if (config == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有运行的应用配置')),
      );
      return;
    }

    setState(() {
      // 移除 UPLOAD 按钮那条消息
      _messages.removeLast();
      _messages.add(ChatMessage(role: 'system', content: '正在上传当前应用配置...'));
      _isThinking = true;
    });
    _scrollToBottom();

    try {
      final appContextString = await _chatService.uploadCurrentApp(config);
      setState(() {
        _isThinking = false;
        _messages.removeLast();
        _messages.add(ChatMessage(role: 'system', content: '✅ 应用配置已上传成功。'));
      });
      // 自动发送一条消息继续流程，并附加上传的代码配置内容作为隐藏上下文
      _sendTextToAi(
        '当前应用的代码配置已上传，请查阅并继续完成我的要求。',
        hiddenText: '$appContextString\n\n请查阅以上代码配置并继续完成我的要求。',
      );
    } catch (e) {
      setState(() {
        _isThinking = false;
        _messages.removeLast();
        _messages.add(ChatMessage(role: 'system', content: '❌ 上传失败: $e'));
      });
      _scrollToBottom();
    }
  }

  void _cancelEditMode() {
    setState(() {
      _editMode = false;
      _editTextController.clear();
    });
  }

  /// 原生语音识别 (Apple/Google)
  void _startNativeSpeech() {
    debugPrint('[DesignerBall] 启动原生语音识别 (Apple/Google Speech)');
    if (_speech == null) return;
    try {
      debugPrint('[DesignerBall] listen 参数: listenFor=60s, pauseFor=60s');
      _speech!.listen(
        onResult: (result) {
          _nativeSpeechReceivedCallback = true;
          debugPrint('[DesignerBall] 收到识别结果: ${result.recognizedWords}, finalResult=${result.finalResult}');

          // 拼接累积文本和当前识别结果
          final currentText = result.recognizedWords;
          final fullText = _accumulatedTranscript.isEmpty
              ? currentText
              : '$_accumulatedTranscript $currentText';

          setState(() => _liveTranscript = fullText);
          _scrollToBottom();

          // 场景2修复：收到 finalResult=true 时，原生引擎会自动停止
          // 如果用户还在按住球，重新启动监听以继续录音
          if (result.finalResult && _isListening && _pointerDown) {
            debugPrint('[DesignerBall] 收到 finalResult，保存已识别文本并重新启动监听');
            // 保存已确认的文本
            _accumulatedTranscript = fullText;
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_isListening && _pointerDown && !_useSherpaAsr) {
                _startNativeSpeech();
              }
            });
          }
        },
        localeId: 'zh_CN',
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 60),
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
      );
      debugPrint('[DesignerBall] listen 调用完成，等待用户说话');
    } catch (e) {
      debugPrint('[DesignerBall] Native listen error: $e');
      setState(() {
        _isListening = false;
        _messages.add(ChatMessage(role: 'assistant', content: '原生语音识别启动失败，请在设置中开启"强制离线模式"'));
      });
      _pulseController.stop();
    }
  }

  /// 处理网络错误，引导用户开启离线模式
  Future<void> _handleNetworkError() async {
    final prefs = await SharedPreferences.getInstance();
    final dontShow = prefs.getBool('dont_show_network_error_dialog') ?? false;

    if (dontShow) {
      debugPrint('[DesignerBall] 用户已选择不再提示网络错误');
      return;
    }

    if (!mounted) return;

    bool dontShowAgain = false;
    String selectedModel = _sherpaAsr.selectedModelId;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('网络语音识别不可用'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('检测到网络问题，无法使用在线语音识别。是否切换到离线模型？'),
              const SizedBox(height: 16),
              const Text('选择离线模型：', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...SherpaAsrService.availableModels.map((model) => RadioListTile<String>(
                title: Text(model.name),
                value: model.id,
                groupValue: selectedModel,
                onChanged: (value) {
                  setDialogState(() {
                    selectedModel = value!;
                  });
                },
                dense: true,
                contentPadding: EdgeInsets.zero,
              )),
              const SizedBox(height: 8),
              CheckboxListTile(
                title: const Text('不再提示'),
                value: dontShowAgain,
                onChanged: (value) {
                  setDialogState(() {
                    dontShowAgain = value ?? false;
                  });
                },
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, {
                'enable': true,
                'dontShow': dontShowAgain,
                'modelId': selectedModel,
              }),
              child: const Text('开启离线模式'),
            ),
          ],
        ),
      ),
    );

    if (result != null && result['enable'] == true) {
      // 保存"不再提示"设置
      if (result['dontShow'] == true) {
        await prefs.setBool('dont_show_network_error_dialog', true);
      }

      // 保存离线模式设置
      await _sherpaAsr.setForceOffline(true);
      await _sherpaAsr.setModel(result['modelId'] as String);

      debugPrint('[DesignerBall] 用户选择开启离线模式，模型: ${result['modelId']}');

      // 停止当前识别，重新开始
      if (_isListening) {
        try { await _speech?.stop(); } catch (_) {}
        _startListening();
      }
    }
  }

  /// sherpa_onnx 离线 ASR：本地录音 + 本地识别
  Future<void> _startSherpaAsr() async {
    debugPrint('[DesignerBall] 启动离线语音识别 (sherpa_onnx, model=${_sherpaAsr.selectedModelId})');
    try {
      // 确保 recognizer 已初始化（防止 chatMode 下重复按球但 recognizer 还没 ready）
      if (!await _sherpaAsr.ensureReady()) {
        debugPrint('[DesignerBall] sherpa ensureReady failed in _startSherpaAsr');
        setState(() {
          _isListening = false;
          _messages.add(ChatMessage(role: 'assistant', content: '离线语音模型未就绪，请在设置中重新下载'));
        });
        _pulseController.stop();
        _pulseController.reset();
        return;
      }

      _sherpaAsr.onResult = (text) {
        setState(() => _liveTranscript = text);
        _scrollToBottom();
      };

      final ok = await _sherpaAsr.startListening();
      if (!ok) {
        setState(() {
          _isListening = false;
          _messages.add(ChatMessage(role: 'assistant', content: '离线语音识别启动失败'));
        });
        _pulseController.stop();
      }
    } catch (e) {
      debugPrint('[SherpaASR] Start error: $e');
      setState(() {
        _isListening = false;
        _messages.add(ChatMessage(role: 'assistant', content: '语音识别启动失败: $e'));
      });
      _pulseController.stop();
    }
  }

  void _stopSherpaAsr() {
    _sherpaAsr.stopListening();
    _sherpaAsr.onResult = null;
  }

  Future<void> _stopListeningAndSend() async {
    debugPrint('[DesignerBall] _stopListeningAndSend');

    // 停止语音识别
    final shouldUseSherpa = _useSherpaAsr;
    if (shouldUseSherpa) {
      _sherpaAsr.onResult = null;
      final finalText = await _sherpaAsr.stopListening();
      if (finalText.isNotEmpty) {
        _liveTranscript = finalText;
      }
    } else {
      try { _speech?.stop(); } catch (e) {
        debugPrint('[DesignerBall] speech.stop error: $e');
      }
    }
    _pulseController.stop();
    _pulseController.reset();

    final text = _liveTranscript?.trim() ?? '';

    if (text.isEmpty) {
      setState(() {
        _isListening = false;
        _liveTranscript = null;
      });
      return;
    }

    // 中断上一条还在进行的流
    _cancelCurrentStream();

    // 原子 setState：清掉 transcript + 加用户消息 + 空 assistant 占位
    setState(() {
      _isListening = false;
      _liveTranscript = null;
      _messages.add(ChatMessage(role: 'user', content: text));
      _messages.add(ChatMessage(role: 'assistant', content: ''));
      _isThinking = true;
    });
    _scrollToBottom();

    _streamSub = _chatService.sendStream(text).listen(
      (event) {
        if (event.error != null && event.content == null) {
          // 纯错误（如配额超限）
          setState(() {
            _isThinking = false;
            _messages.last = ChatMessage(role: 'assistant', content: event.error!);
          });
          _scrollToBottom();
          return;
        }
        if (event.content != null) {
          setState(() {
            _isThinking = false;
            _messages.last = ChatMessage(role: 'assistant', content: event.content!);
          });
          _scrollToBottom();
        }
        if (event.jsonApp != null) {
          debugPrint('[DesignerBall] AI generated JSON-APP!');
          _lastGeneratedJson = event.jsonApp;
          setState(() {
            _messages.add(ChatMessage(
              role: 'system',
              content: '🚀 JSON-APP 已生成，点击试运行',
              jsonApp: event.jsonApp,
            ));
          });
          _scrollToBottom();
        }
        if (event.quota != null) {
          _lastQuota = event.quota;
        }
      },
      onError: (e) {
        debugPrint('[DesignerBall] AI stream error: $e');
        setState(() {
          _isThinking = false;
          _messages.last = ChatMessage(role: 'assistant', content: '出错了: $e');
        });
      },
    );
  }

  /// 取消正在进行的 AI 流式回复，保留已收到的部分内容
  void _cancelCurrentStream() {
    if (_streamSub != null) {
      // 保存已收到的部分回复到对话历史
      if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        final partial = _messages.last.content;
        _chatService.commitPartial(partial);
        // 如果占位消息是空的就移除
        if (partial.isEmpty) {
          _messages.removeLast();
        }
      }
      _streamSub?.cancel();
      _streamSub = null;
      _chatService.abort();
      setState(() => _isThinking = false);
    }
  }

  /// 处理崩溃报告 — 自动进入对话模式并发送崩溃信息给 AI
  void _handleCrashReport(String crashReport) {
    // 进入对话模式
    setState(() {
      _chatMode = true;
      _messages.add(ChatMessage(role: 'user', content: crashReport));
      _messages.add(ChatMessage(role: 'assistant', content: ''));
      _isThinking = true;
    });
    _scrollToBottom();

    // 直接发送给 AI
    _cancelCurrentStream();
    _streamSub = _chatService.sendStream(crashReport).listen(
      (event) {
        if (event.error != null && event.content == null) {
          setState(() {
            _isThinking = false;
            _messages.last = ChatMessage(role: 'assistant', content: event.error!);
          });
          _scrollToBottom();
          return;
        }
        if (event.content != null) {
          setState(() {
            _isThinking = false;
            _messages.last = ChatMessage(role: 'assistant', content: event.content!);
          });
          _scrollToBottom();
        }
        if (event.jsonApp != null) {
          debugPrint('[DesignerBall] AI generated fix JSON-APP!');
          _lastGeneratedJson = event.jsonApp;
          setState(() {
            _messages.add(ChatMessage(
              role: 'system',
              content: '🔧 修复版 JSON-APP 已生成，点击试运行',
              jsonApp: event.jsonApp,
            ));
          });
          _scrollToBottom();
        }
      },
      onError: (e) {
        setState(() {
          _isThinking = false;
          _messages.last = ChatMessage(role: 'assistant', content: '分析失败: $e');
        });
      },
    );
  }

  void _closeChatMode() {
    try { _speech?.stop(); } catch (_) {}
    _stopSherpaAsr();
    _cancelCurrentStream();
    _pulseController.stop();
    _pulseController.reset();
    setState(() {
      _chatMode = false;
      _isListening = false;
      _isThinking = false;
      _liveTranscript = null;
      _recordStartPos = null;
      _dragCancelling = false;
    });
  }

  void _clearAndCloseChatMode() {
    _closeChatMode();
    _messages.clear();
    _chatService.clear();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ════════════════════════════════════════════════════════
  // 位置动画
  // ════════════════════════════════════════════════════════

  void _animateTo(double targetLeft, double targetTop) {
    _animLeft = null;
    _animTop = null;
    _animController.reset();
    _animLeft = Tween<double>(begin: _left, end: targetLeft).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animTop = Tween<double>(begin: _top, end: targetTop).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward();
  }

  void _hideToEdge(_HideEdge edge, Size screenSize) {
    // 注意：左右边缘不再隐藏（在 _handleDragEnd 中直接吸附），只处理上下
    double targetLeft = _left;
    double targetTop = _top;

    switch (edge) {
      case _HideEdge.top:
        targetTop = -_ballSize + _peekSize;
      case _HideEdge.bottom:
        targetTop = screenSize.height - _peekSize;
      case _HideEdge.left:
      case _HideEdge.right:
      case _HideEdge.none:
        return;
    }

    targetLeft = targetLeft.clamp(0.0, screenSize.width - _ballSize);

    _animLeft = null;
    _animTop = null;
    _animController.reset();
    _animLeft = Tween<double>(begin: _left, end: targetLeft).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animTop = Tween<double>(begin: _top, end: targetTop).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward().then((_) {
      if (!_dragging) {
        setState(() {
          _hidden = true;
          _hideEdge = edge;
        });
      }
    });
  }

  void _revealFromEdge(Size screenSize) {
    double targetLeft = _left;
    double targetTop = _top;

    switch (_hideEdge) {
      case _HideEdge.top:
        targetTop = 0;
      case _HideEdge.bottom:
        targetTop = screenSize.height - _ballSize;
      case _HideEdge.left:
      case _HideEdge.right:
      case _HideEdge.none:
        return;
    }

    setState(() => _hidden = false);

    _animLeft = null;
    _animTop = null;
    _animController.reset();
    _animLeft = Tween<double>(begin: _left, end: targetLeft).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animTop = Tween<double>(begin: _top, end: targetTop).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward().then((_) {
      _hideEdge = _HideEdge.none;
      _revealing = false; // 露出动画完成，允许拖拽
    });
  }

  // ════════════════════════════════════════════════════════
  // 构建
  // ════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    _initPosition(screenSize);

    return DefaultTextStyle(
      style: const TextStyle(decoration: TextDecoration.none),
      child: Stack(
      children: [
        widget.child,

        // 字幕覆层
        if (_chatMode)
          ChatOverlay(
            messages: _messages,
            isListening: _isListening,
            isThinking: _isThinking,
            isGeneratingJson: _isGeneratingJson,
            liveTranscript:
                (_liveTranscript?.isNotEmpty ?? false) ? _liveTranscript : null,
            onClose: _closeChatMode,
            onClear: _clearAndCloseChatMode,
            scrollController: _scrollController,
            onProviderChanged: _onProviderChanged,
            onUploadCurrentApp: _handleUploadCurrentApp,
            onRunJsonApp: (jsonConfig) {
              _clearAndCloseChatMode();
              widget.onRunJsonApp?.call(jsonConfig);
            },
          ),

        // 录音底部操作栏 — 左取消 / 右编辑
        if (_isListening && _recordStartPos != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _cancelBottomZoneHeight,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  border: Border(
                    top: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                  ),
                ),
                child: Row(
                  children: [
                    // 左半：取消区域
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        decoration: BoxDecoration(
                          color: _dragCancelling
                              ? Colors.red.withValues(alpha: 0.5)
                              : Colors.transparent,
                          border: Border(
                            right: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.close_rounded,
                                color: _dragCancelling ? Colors.white : Colors.white70,
                                size: 28),
                            const SizedBox(height: 6),
                            Text(
                              '取消',
                              style: TextStyle(
                                color: _dragCancelling ? Colors.white : Colors.white70,
                                fontSize: 14,
                                fontWeight: _dragCancelling ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 右半：编辑区域
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        color: _dragInEditZone
                            ? Colors.blue.withValues(alpha: 0.5)
                            : Colors.transparent,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.edit_rounded,
                                color: _dragInEditZone ? Colors.white : Colors.white70,
                                size: 28),
                            const SizedBox(height: 6),
                            Text(
                              '编辑',
                              style: TextStyle(
                                color: _dragInEditZone ? Colors.white : Colors.white70,
                                fontSize: 14,
                                fontWeight: _dragInEditZone ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // 编辑模式覆层
        if (_editMode)
          _buildEditOverlay(screenSize),

        // 悬浮球 — 全部用 Listener 捕获原始 pointer 事件，消除手势竞技场延迟
        Positioned(
          left: _left,
          top: _top,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: (e) => _onPointerMove(e, screenSize),
            onPointerUp: (e) => _onPointerUp(e, screenSize),
            onPointerCancel: _onPointerCancel,
            child: GestureDetector(
              onTap: () => _onTap(screenSize),
              onDoubleTap: _onDoubleTap,
              child: _buildBall(context),
            ),
          ),
        ),
      ],
    ),
    );
  }

  Widget _buildEditOverlay(Size screenSize) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final bottomOffset = keyboardHeight > 0 ? keyboardHeight + 8 : bottomPadding + 80;
    return Positioned(
      left: 12,
      right: 12,
      bottom: bottomOffset,
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: screenSize.height * 0.35,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.blue.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              // 标题栏
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.edit_note,
                        color: Colors.white.withValues(alpha: 0.5), size: 18),
                    const SizedBox(width: 6),
                    Text(
                      '编辑消息',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _cancelEditMode,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.close,
                            color: Colors.white60, size: 18),
                      ),
                    ),
                  ],
                ),
              ),
              // 编辑区域
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: TextField(
                    controller: _editTextController,
                    autofocus: true,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      height: 1.6,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: '编辑你的消息...',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ),
              // 底部操作栏
              Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _cancelEditMode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _sendEditedText,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.purple,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.send, color: Colors.white, size: 18),
                            SizedBox(width: 6),
                            Text(
                              '发送',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBall(BuildContext context) {
    final double opacity = _hidden ? 0.6 : 1.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 跟随主题的颜色方案
    final Color defaultBg = isDark ? Colors.white : Colors.black;
    final Color defaultFg = isDark ? Colors.black : Colors.white;
    const Color listeningColor = Color(0xFFE53935); // 柔和红
    const Color editZoneColor = Color(0xFF1E88E5); // 柔和蓝
    const Color cancelColor = Color(0xFF757575); // 灰色

    final Color ballColor;
    final Color iconColor;
    if (_isListening) {
      ballColor = _dragCancelling ? cancelColor : (_dragInEditZone ? editZoneColor : listeningColor);
      iconColor = Colors.white;
    } else {
      ballColor = defaultBg;
      iconColor = defaultFg;
    }

    Widget ball = Container(
      width: _ballSize,
      height: _ballSize,
      decoration: BoxDecoration(
        color: ballColor,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.15),
            blurRadius: 16,
            spreadRadius: 1,
            offset: const Offset(0, 4),
          ),
          if (!_isListening && !isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
        ],
      ),
      child: Center(
        child: _isListening
            ? Icon(
                _dragCancelling ? Icons.close : (_dragInEditZone ? Icons.edit : Icons.mic),
                color: iconColor,
                size: 28,
              )
            : _chatMode
                ? Icon(Icons.chat_bubble_outline,
                    color: iconColor, size: 26)
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        'D',
                        style: TextStyle(
                          color: iconColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                      if (_messages.isNotEmpty)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: isDark ? Colors.black : Colors.orangeAccent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark ? Colors.white : Colors.black,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );

    // 录音中脉冲光环
    if (_isListening) {
      ball = AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return CustomPaint(
            painter: _PulseRingPainter(
              progress: _pulseController.value,
              color: _dragCancelling ? cancelColor : (_dragInEditZone ? editZoneColor : listeningColor),
            ),
            child: child,
          );
        },
        child: ball,
      );
    }

    // 长按倒计时环形进度
    if (_pointerDown && !_chatMode && !_movedEnough) {
      ball = AnimatedBuilder(
        animation: _countdownController,
        builder: (context, child) {
          return CustomPaint(
            painter: _CountdownRingPainter(
              progress: _countdownController.value,
              ringColor: isDark ? Colors.white : Colors.black,
            ),
            child: child,
          );
        },
        child: ball,
      );
    }

    // 按住时放大 + 松手弹回 — iOS 灵动效果
    ball = AnimatedScale(
      scale: _pointerDown ? 1.18 : 1.0,
      duration: Duration(milliseconds: _pointerDown ? 150 : 400),
      curve: _pointerDown ? Curves.easeOut : Curves.elasticOut,
      child: ball,
    );

    return Opacity(opacity: opacity, child: ball);
  }

}

// ── 脉冲光环 ──

class _PulseRingPainter extends CustomPainter {
  final double progress;
  final Color color;

  _PulseRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width / 2;
    const maxExpand = 14.0;

    final paint = Paint()
      ..color = color.withValues(alpha: 0.35 * (1 - progress))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;

    canvas.drawCircle(center, baseRadius + maxExpand * progress, paint);
  }

  @override
  bool shouldRepaint(_PulseRingPainter old) => old.progress != progress;
}

// ── 长按倒计时环形进度 ──

class _CountdownRingPainter extends CustomPainter {
  final double progress;
  final Color ringColor;

  _CountdownRingPainter({required this.progress, required this.ringColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 + 6;

    // 底环
    final bgPaint = Paint()
      ..color = ringColor.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    // 进度环 — 跟随主题色
    final fgPaint = Paint()
      ..color = ringColor.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    final sweepAngle = 2 * pi * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2, // 从顶部开始
      sweepAngle,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(_CountdownRingPainter old) => old.progress != progress || old.ringColor != ringColor;
}

enum _HideEdge { none, left, right, top, bottom }
