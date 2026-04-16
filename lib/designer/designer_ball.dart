import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'ai_chat_service.dart';
import 'chat_overlay.dart';

/// 悬浮设计师球 — iOS 风格丝滑拖拽 + 长按对话模式。
/// 凌驾于所有页面之上，不影响 JSON APP。
class DesignerBall extends StatefulWidget {
  final Widget child;

  const DesignerBall({super.key, required this.child});

  @override
  State<DesignerBall> createState() => _DesignerBallState();
}

class _DesignerBallState extends State<DesignerBall>
    with TickerProviderStateMixin {
  // ── 尺寸常量 ──
  static const double _ballSize = 56.0;
  static const double _peekSize = 20.0;
  static const double _edgeThreshold = 20.0;
  static const double _dragThreshold = 10.0;

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

  // ── 动画 ──
  late AnimationController _animController;
  Animation<double>? _animLeft;
  Animation<double>? _animTop;

  // ── 长按对话 ──
  static const Duration _longPressDuration = Duration(seconds: 2);
  static const Duration _idleTimeout = Duration(seconds: 15);
  Timer? _longPressTimer;
  Timer? _idleTimer; // 空闲自动关闭字幕
  bool _chatMode = false;
  bool _isListening = false;
  bool _isThinking = false;
  String? _liveTranscript;

  // ── 脉冲动画（录音中） ──
  late AnimationController _pulseController;

  // ── 长按倒计时动画 ──
  late AnimationController _countdownController;

  // ── 语音识别 & AI ──
  stt.SpeechToText? _speech; // 延迟创建，避免启动时触发权限检查
  bool _speechInited = false;
  final AiChatService _chatService = AiChatService();
  StreamSubscription<String>? _streamSub; // 当前 SSE 流订阅
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
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _idleTimer?.cancel();
    _streamSub?.cancel();
    _chatService.abort();
    _animController.dispose();
    _pulseController.dispose();
    _countdownController.dispose();
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
  // 原始指针事件 — 用 Listener 捕获，不受手势竞技场影响
  // ════════════════════════════════════════════════════════

  void _onPointerDown(PointerDownEvent event) {
    _pointerDown = true;
    _movedEnough = false;
    _pointerDownPos = event.position;
    _animController.stop();

    // 从收起态 → 解除收起
    if (_hidden) {
      setState(() {
        _hidden = false;
        _hideEdge = _HideEdge.none;
      });
    }

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

  void _onPointerUp(PointerUpEvent event) {
    _pointerDown = false;
    _longPressTimer?.cancel();
    _countdownController.stop();
    _countdownController.reset();

    // 录音中松手 → 发送
    if (_isListening) {
      _stopListeningAndSend();
    }
  }

  // ════════════════════════════════════════════════════════
  // Pan 手势 — 仅用于拖拽移动
  // ════════════════════════════════════════════════════════

  void _onPanUpdate(DragUpdateDetails details, Size screenSize) {
    final delta = (details.globalPosition - _pointerDownPos).distance;
    if (delta > _dragThreshold) {
      _movedEnough = true;
      _longPressTimer?.cancel();
      _countdownController.stop();
      _countdownController.reset();
    }

    // 录音中不移动球
    if (_isListening) return;

    _dragging = true;
    setState(() {
      _left += details.delta.dx;
      _top += details.delta.dy;
      _left = _left.clamp(-_ballSize * 0.5, screenSize.width - _ballSize * 0.5);
      _top = _top.clamp(-_ballSize * 0.5, screenSize.height - _ballSize * 0.5);
    });
  }

  void _onPanEnd(DragEndDetails details, Size screenSize) {
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

    if (edge != _HideEdge.none) {
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

  // ════════════════════════════════════════════════════════
  // 对话模式
  // ════════════════════════════════════════════════════════

  Future<void> _enterChatMode() async {
    debugPrint('[DesignerBall] _enterChatMode called');
    try {
      if (!_speechInited) {
        _speech ??= stt.SpeechToText();
        debugPrint('[DesignerBall] Initializing speech...');
        _speechInited = await _speech!.initialize(
          onError: (error) {
            debugPrint('[DesignerBall] Speech error: $error');
            setState(() => _isListening = false);
            _pulseController.stop();
          },
          onStatus: (status) {
            debugPrint('[DesignerBall] Speech status: $status');
          },
        );
        debugPrint('[DesignerBall] Speech init result: $_speechInited');
      }
    } catch (e, stack) {
      debugPrint('[DesignerBall] Speech init EXCEPTION: $e');
      debugPrint('[DesignerBall] $stack');
      _speechInited = false;
    }

    setState(() {
      _chatMode = true;
    });
    _resetIdleTimer();

    if (_speechInited) {
      _startListening();
    } else {
      debugPrint('[DesignerBall] Speech not available, chat mode without voice');
    }
  }

  void _startListening() {
    if (!_speechInited || _speech == null) return;
    debugPrint('[DesignerBall] _startListening');

    setState(() {
      _isListening = true;
      _liveTranscript = '';
    });

    _pulseController.repeat(reverse: true);

    try {
      _speech!.listen(
        onResult: (result) {
          setState(() {
            _liveTranscript = result.recognizedWords;
          });
          _scrollToBottom();
        },
        localeId: 'zh_CN',
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
      );
    } catch (e) {
      debugPrint('[DesignerBall] listen EXCEPTION: $e');
      setState(() => _isListening = false);
      _pulseController.stop();
    }
  }

  Future<void> _stopListeningAndSend() async {
    debugPrint('[DesignerBall] _stopListeningAndSend');
    try {
      _speech?.stop();
    } catch (e) {
      debugPrint('[DesignerBall] speech.stop error: $e');
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
      (accumulated) {
        setState(() {
          _isThinking = false;
          _messages.last = ChatMessage(role: 'assistant', content: accumulated);
        });
        _scrollToBottom();
      },
      onError: (e) {
        debugPrint('[DesignerBall] AI stream error: $e');
        setState(() {
          _isThinking = false;
          _messages.last = ChatMessage(role: 'assistant', content: '出错了: $e');
        });
        _resetIdleTimer();
      },
      onDone: () {
        _streamSub = null;
        if (_messages.isNotEmpty && _messages.last.content.isEmpty) {
          setState(() {
            _messages.removeLast();
            _isThinking = false;
          });
        }
        _resetIdleTimer();
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

  void _closeChatMode() {
    try { _speech?.stop(); } catch (_) {}
    _cancelCurrentStream();
    _idleTimer?.cancel();
    _pulseController.stop();
    _pulseController.reset();
    setState(() {
      _chatMode = false;
      _isListening = false;
      _isThinking = false;
      _liveTranscript = null;
      _messages.clear();
    });
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

  /// 重置空闲计时器 — 每次有新交互时调用
  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      if (_chatMode && !_isListening && !_isThinking && _streamSub == null) {
        _closeChatMode();
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
    double targetLeft = _left;
    double targetTop = _top;

    switch (edge) {
      case _HideEdge.left:
        targetLeft = -_ballSize + _peekSize;
      case _HideEdge.right:
        targetLeft = screenSize.width - _peekSize;
      case _HideEdge.top:
        targetTop = -_ballSize + _peekSize;
      case _HideEdge.bottom:
        targetTop = screenSize.height - _peekSize;
      case _HideEdge.none:
        return;
    }

    if (edge == _HideEdge.left || edge == _HideEdge.right) {
      targetTop = targetTop.clamp(0.0, screenSize.height - _ballSize);
    } else {
      targetLeft = targetLeft.clamp(0.0, screenSize.width - _ballSize);
    }

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
      case _HideEdge.left:
        targetLeft = 0;
      case _HideEdge.right:
        targetLeft = screenSize.width - _ballSize;
      case _HideEdge.top:
        targetTop = 0;
      case _HideEdge.bottom:
        targetTop = screenSize.height - _ballSize;
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
            liveTranscript:
                (_liveTranscript?.isNotEmpty ?? false) ? _liveTranscript : null,
            onClose: _closeChatMode,
            scrollController: _scrollController,
          ),

        // 悬浮球 — 用 Listener 捕获原始 pointer 事件
        Positioned(
          left: _left,
          top: _top,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            child: GestureDetector(
              onPanUpdate: (d) => _onPanUpdate(d, screenSize),
              onPanEnd: (d) => _onPanEnd(d, screenSize),
              onTap: () => _onTap(screenSize),
              child: _buildBall(),
            ),
          ),
        ),
      ],
    ),
    );
  }

  Widget _buildBall() {
    final double opacity = _hidden ? 0.6 : 1.0;

    Widget ball = Container(
      width: _ballSize,
      height: _ballSize,
      decoration: BoxDecoration(
        color: _isListening ? Colors.red : Colors.purple,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: (_isListening ? Colors.red : Colors.purple)
                .withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: _isListening
            ? const Icon(Icons.mic, color: Colors.white, size: 26)
            : _chatMode
                ? const Icon(Icons.chat_bubble_outline,
                    color: Colors.white, size: 24)
                : const Text(
                    'D',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
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
              color: Colors.red,
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
            ),
            child: child,
          );
        },
        child: ball,
      );
    }

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
    final maxExpand = 12.0;

    final paint = Paint()
      ..color = color.withValues(alpha: 0.3 * (1 - progress))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawCircle(center, baseRadius + maxExpand * progress, paint);
  }

  @override
  bool shouldRepaint(_PulseRingPainter old) => old.progress != progress;
}

// ── 长按倒计时环形进度 ──

class _CountdownRingPainter extends CustomPainter {
  final double progress;

  _CountdownRingPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 + 4;

    // 底环
    final bgPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, bgPaint);

    // 进度环
    final fgPaint = Paint()
      ..color = Colors.purpleAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final sweepAngle = 2 * 3.14159265 * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159265 / 2, // 从顶部开始
      sweepAngle,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(_CountdownRingPainter old) => old.progress != progress;
}

enum _HideEdge { none, left, right, top, bottom }
