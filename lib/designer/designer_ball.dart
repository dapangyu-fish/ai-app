import 'dart:async';
import 'dart:math' show sqrt, pi;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'ai_chat_service.dart';
import 'chat_overlay.dart';
import 'sherpa_asr_service.dart';
import 'bytedance_asr_service.dart';
import 'gesture_exclusion_helper.dart';
import '../config/app_config.dart';
import '../auth/auth_service.dart';
import '../i18n/framework_strings.dart';
import '../main.dart' show JsonDslApp;
import '../onboarding/onboarding_keys.dart';

/// 语音识别方式枚举
enum AsrMode {
  online,    // 在线识别（speech_to_text）
  offline,   // 离线识别（sherpa_onnx）
  bytedance, // 豆包ASR
}

/// 全局 ASR 模式管理 —— 让 settings_page 改完之后悬浮球能立刻感知。
///
/// 之前 bug：DesignerBall 在 initState 里读一次 SharedPreferences 就缓存到
/// `_asrMode` 字段，永远不再刷新。settings_page 写了 prefs，但 DesignerBall
/// 是 MaterialApp 外层的常驻 widget，永远不会重新 initState，结果用户切到
/// "离线"或"豆包"，运行时 `_asrMode` 还是启动时的旧值，体感"切了没切成功"。
class AsrModePrefs {
  AsrModePrefs._();

  static final ValueNotifier<AsrMode> notifier = ValueNotifier(AsrMode.online);

  static AsrMode _decode(String? s) {
    switch (s) {
      case 'offline':
        return AsrMode.offline;
      case 'bytedance':
        return AsrMode.bytedance;
      default:
        return AsrMode.online;
    }
  }

  static String _encode(AsrMode m) {
    switch (m) {
      case AsrMode.offline:
        return 'offline';
      case AsrMode.bytedance:
        return 'bytedance';
      case AsrMode.online:
        return 'online';
    }
  }

  /// App 启动 / 悬浮球 initState 时调一次，把 prefs 里的值灌进 notifier
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    notifier.value = _decode(prefs.getString('asr_mode'));
  }

  /// settings 页改 mode 时调；写 prefs + 通知所有监听者
  static Future<void> set(AsrMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('asr_mode', _encode(mode));
    notifier.value = mode;
  }
}

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
  static const Duration _longPressDuration = Duration(milliseconds: 1500);
  Timer? _longPressTimer;
  bool _chatMode = false;
  bool _isListening = false;
  bool _isThinking = false;
  bool _isGeneratingJson = false;
  String _generatingStatusMessage = '正在生成代码...'; // 动态状态文案
  String? _liveTranscript;
  String _accumulatedTranscript = ''; // 累积的已确认文本（用于多段识别）

  // ── 录音拖拽取消 ──
  Offset? _recordStartPos;
  bool _dragCancelling = false;
  bool _dragInEditZone = false;
  static const double _cancelBottomZoneHeight = 120.0;

  // ── 编辑模式 ──
  // 编辑窗用 showModalBottomSheet 渲染在独立 Navigator route 中，
  // 与 DesignerBall 的 setState 完全隔离。_editMode 仅用于隐藏悬浮球。
  bool _editMode = false;

  // ── 脉冲动画（录音中） ──
  late AnimationController _pulseController;

  // ── 长按倒计时动画 ──
  late AnimationController _countdownController;

  // ── 语音识别 & AI ──
  stt.SpeechToText? _speech;
  bool _speechInited = false;
  bool _nativeSpeechReceivedCallback = false; // 标记原生识别是否收到过回调
  // ⚠️ 不要直接读这个字段，用 _asrMode getter，永远拿到 AsrModePrefs 最新值。
  // 历史 bug：缓存了 initState 时的旧值，settings 改完不感知。
  AsrMode get _asrMode => AsrModePrefs.notifier.value;
  final SherpaAsrService _sherpaAsr = SherpaAsrService.instance;
  final ByteDanceAsrService _bytedanceAsr = ByteDanceAsrService.instance;
  final AiChatService _chatService = AiChatService();
  StreamSubscription<ChatEvent>? _streamSub;
  // 老的 5s 独立 heartbeat 已被删掉。新逻辑：
  // - SSE 内部 20s idle timeout → _checkAliveCarefully 三态探活
  // - 后端 worker 自身在 CLI 异常退出 / 外部 kill 时主动写 needs_retry 事件
  // 两条路径都收敛到 needsRetry → UI 弹重试按钮，不再需要独立 timer。
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
    // 加载配置（asr_mode 走全局 notifier，settings 改完悬浮球能立刻感知）
    AsrModePrefs.load().then((_) {
      if (mounted) setState(() {}); // 触发一次 rebuild 让 _asrMode getter 拿到新值
    });
    AsrModePrefs.notifier.addListener(_onAsrModeChanged);
    _sherpaAsr.loadConfig().then((_) {
      setState(() {});
    });
    // 加载 AI 对话 session，加载完之后异步检查上一轮有没有未完成 / 已完成的任务
    // 不 await，不阻塞 UI 启动
    _chatService.loadSession().then((_) => _maybeResumeUnfinishedSession());

    // DesignerBall 挂在 MaterialApp.builder 里凌驾所有路由，**不会**因为 AuthGate
    // 切换 (FilePickerPage <-> AuthPage) 而重建。所以"用户掉登录后重新登录"这个
    // 场景下，initState 不会再跑——必须显式监听登录态切换，重新触发 resume。
    AuthService.authNotifier.addListener(_onAuthChanged);

    // 提前初始化原生语音识别（参照测试应用的成功实践）
    _initNativeSpeech();

    // 初始化豆包ASR连接
    _initBytedanceAsr();
  }

  /// notifier → 悬浮球内部状态：设置页改完能立刻生效
  void _onAsrModeChanged() {
    if (!mounted) return;
    setState(() {}); // _asrMode 是 getter，rebuild 自然拿新值
    debugPrint('[DesignerBall] ASR mode changed -> ${AsrModePrefs.notifier.value.name}');
  }

  /// 初始化豆包ASR连接
  Future<void> _initBytedanceAsr() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');
      if (token == null || token.isEmpty) {
        debugPrint('[DesignerBall] No access token, skip ByteDance ASR init');
        return;
      }

      // 使用统一配置管理的后端地址
      final serverUrl = AppConfig.bytedanceAsrUrl;
      debugPrint('[DesignerBall] Connecting to ByteDance ASR at: $serverUrl');
      final success = await _bytedanceAsr.connect(serverUrl, token);

      if (success) {
        debugPrint('[DesignerBall] ByteDance ASR connected');

        // 设置回调
        _bytedanceAsr.onResult = (text) {
          // 编辑模式下，所有迟到的 ASR 结果一律丢弃
          if (mounted && _isListening && !_editMode) {
            setState(() {
              _liveTranscript = text;
            });
          }
        };

        _bytedanceAsr.onError = (error) {
          debugPrint('[DesignerBall] ByteDance ASR error: $error');
          if (mounted) {
            setState(() {
              _messages.add(ChatMessage(role: 'assistant', content: '豆包ASR错误: $error'));
            });
          }
        };

        _bytedanceAsr.onQuotaUpdate = (quota) {
          debugPrint('[DesignerBall] ByteDance ASR quota: $quota');
          if (mounted) {
            setState(() {
              _lastQuota = quota;
            });
          }
        };
      } else {
        debugPrint('[DesignerBall] ByteDance ASR connection failed');
      }
    } catch (e) {
      debugPrint('[DesignerBall] ByteDance ASR init error: $e');
    }
  }

  /// 在 initState 时就初始化原生语音识别，避免按住时才初始化导致的延迟和时序问题
  Future<void> _initNativeSpeech() async {
    try {
      _speech = stt.SpeechToText();
      _speechInited = await _speech!.initialize(
        onError: (error) {
          debugPrint('[DesignerBall] Speech error: ${error.errorMsg}');
          if (error.errorMsg == 'error_network') {
            _handleNetworkError();
          }
        },
        onStatus: (status) => debugPrint('[DesignerBall] Speech status: $status'),
      );
      debugPrint('[DesignerBall] Native speech initialized in initState: $_speechInited');
    } catch (e) {
      debugPrint('[DesignerBall] Native speech init failed: $e');
      _speechInited = false;
    }
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
    // Plan A 关键：app 关掉 worker 继续在 backend 跑，下次启动 _maybeResumeUnfinishedSession 接回来
    // 所以 dispose 只关本地 SSE，绝不通知 backend abort
    _chatService.abortLocal();
    _animController.dispose();
    _pulseController.dispose();
    _countdownController.dispose();
    _speech?.stop();
    _scrollController.dispose();
    AsrModePrefs.notifier.removeListener(_onAsrModeChanged);
    AuthService.authNotifier.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// 登录态变化：从未登录 → 已登录时，重新检查是否有未完成会话需要恢复。
  /// 这弥补了 DesignerBall 不会随 AuthGate 切换而重建的问题（它在 MaterialApp.builder 里）。
  void _onAuthChanged() {
    if (!mounted) return;
    if (AuthService.authNotifier.value) {
      // 重新登录后重新加载本地 session 信息（_lastUserMessage 等可能在断网期间陈旧）
      // 然后异步触发恢复
      _chatService.loadSession().then((_) {
        if (mounted) _maybeResumeUnfinishedSession();
      });
    }
  }

  void _initPosition(Size screenSize) {
    // 安全检查：只有在屏幕尺寸有效时才初始化位置
    if (!_positioned && screenSize.width > 0 && screenSize.height > 0) {
      _left = screenSize.width - _ballSize - 16;
      _top = screenSize.height * 0.65;
      _positioned = true;
      debugPrint('[DesignerBall] Position initialized: left=$_left, top=$_top, screenSize=$screenSize');
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

    // 开始长按倒计时，通过 Timer 手动驱动进度
    final durationMs = _chatMode ? 1000 : _longPressDuration.inMilliseconds;
    _longPressTimer?.cancel();
    _countdownController.value = 0.0;
    final startTime = DateTime.now();
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final elapsed = DateTime.now().difference(startTime);
      final progress = elapsed.inMilliseconds / durationMs;
      
      if (mounted) {
        _countdownController.value = progress.clamp(0.0, 1.0);
      }
      
      if (progress >= 1.0) {
        timer.cancel();
        if (_pointerDown && !_movedEnough && mounted) {
          if (_chatMode) {
            _startListening();
          } else {
            _enterChatMode();
          }
        }
      }
    });
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
        _handleDragEnd(screenSize);
        _recordStartPos = null;
      }
      _dragCancelling = false;
      _dragInEditZone = false;
    } else {
      // 非录音态：处理拖拽收尾（吸边等）
      _handleDragEnd(screenSize);
    }
  }

  void _onPointerCancel(PointerCancelEvent event, Size screenSize) {
    setState(() => _pointerDown = false);
    _longPressTimer?.cancel();
    GestureExclusionHelper.clearExclusionRects();
    _countdownController.stop();
    _countdownController.reset();

    if (_isListening) {
      _movedEnough = false;
      _cancelRecording();
      if (_recordStartPos != null) {
        _handleDragEnd(screenSize);
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

  /// 双击悬浮球：弹出快捷菜单（iOS 悬浮球风格）。
  ///
  /// 之前是直接恢复历史会话，但现在需要在这里挂更多入口（截屏、笔记、
  /// 快捷指令等），所以拆成"先弹菜单 → 用户选"两步。
  /// 没历史会话时"恢复会话"按钮灰掉但菜单仍然弹出，让其他入口可用。
  void _onDoubleTap() {
    if (_chatMode) return;
    _showQuickMenu();
  }

  /// 真正恢复会话的逻辑（之前 _onDoubleTap 直接干的事）。
  /// 从快捷菜单的"恢复会话"按钮调过来。
  void _restoreSession() {
    if (_chatMode || _messages.isEmpty) return;
    setState(() => _chatMode = true);
    _scrollToBottom();
  }

  /// 弹出快捷菜单。
  /// 网格布局，每格是一个 [_QuickMenuButton]（icon + label，可禁用态）。
  /// 加新功能：在 children 数组里 append 一个 [_QuickMenuButton] 即可。
  ///
  /// 注意：DesignerBall 挂在 MaterialApp.builder 里、自己的 context 没有
  /// Navigator 祖先（直接 showDialog(context: context) 会抛
  /// "Navigator operation requested with a context that does not include a
  /// Navigator"）。所以用根 navigatorKey 的 context。
  Future<void> _showQuickMenu() async {
    final navContext = JsonDslApp.navigatorKey.currentContext;
    if (navContext == null) return;
    final hasHistory = _messages.isNotEmpty;
    final s = T.of(navContext);

    await showDialog<void>(
      context: navContext,
      barrierColor: Colors.black38,
      barrierDismissible: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return Dialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 32),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  s.ballMenuTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.95,
                  children: [
                    _QuickMenuButton(
                      icon: Icons.history_rounded,
                      label: s.ballMenuRestoreSession,
                      enabled: hasHistory,
                      tooltipDisabled: s.ballMenuRestoreSessionEmpty,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _restoreSession();
                      },
                    ),
                    // 后续功能：在这里 append 更多 _QuickMenuButton，比如：
                    //   _QuickMenuButton(icon: Icons.screenshot, label: '截屏', ...)
                    //   _QuickMenuButton(icon: Icons.edit_note, label: '记笔记', ...)
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
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

    // 进入对话模式的重震动反馈：双击 heavyImpact，间隔 ~70ms。
    // Flutter SDK 的 heavyImpact 已是单次最强，要更明显只能连击。
    // ignore: unawaited_futures
    _strongHapticBurst();

    // 后台拉取供应商列表（不阻塞进入对话模式）
    AiChatService.fetchProviders().then((_) {
      if (mounted) setState(() {});
    });

    debugPrint('[DesignerBall] 初始状态: asrMode=$_asrMode, speechInited=$_speechInited');

    // 检查原生语音识别是否已初始化（已在 initState 中完成）
    if (!_speechInited && _asrMode == AsrMode.online) {
      setState(() {
        _messages.add(ChatMessage(role: 'assistant', content: '原生语音识别初始化失败，请在设置中切换到离线模式或豆包ASR'));
      });
      return;
    }

    debugPrint('[DesignerBall] 最终决策: ASR模式=${_asrMode.name}');

    // 如果是离线模式，需要预加载模型
    if (_asrMode == AsrMode.offline) {
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

    // 如果是豆包ASR，检查连接状态
    if (_asrMode == AsrMode.bytedance) {
      if (!_bytedanceAsr.isConnected) {
        debugPrint('[DesignerBall] 豆包ASR未连接，等待连接...');
        setState(() {
          _chatMode = true;
          _isThinking = true;
          _liveTranscript = '正在连接豆包ASR...';
        });

        // 等待最多3秒让豆包ASR连接
        int waitCount = 0;
        while (!_bytedanceAsr.isConnected && waitCount < 30) {
          await Future.delayed(const Duration(milliseconds: 100));
          waitCount++;

          // 用户手已离开，中止等待
          if (!_pointerDown) {
            debugPrint('[DesignerBall] Pointer lifted during ByteDance ASR wait, aborting');
            setState(() {
              _isThinking = false;
              _liveTranscript = null;
            });
            return;
          }
        }

        setState(() {
          _isThinking = false;
          _liveTranscript = null;
        });

        // 等待超时，仍未连接
        if (!_bytedanceAsr.isConnected) {
          debugPrint('[DesignerBall] 豆包ASR连接超时，isConnected=${_bytedanceAsr.isConnected}');
          setState(() {
            _messages.add(ChatMessage(role: 'assistant', content: '豆包ASR连接超时，请检查网络或切换到其他识别方式'));
          });
          return;
        }

        debugPrint('[DesignerBall] 豆包ASR连接成功');
      }
    }

    debugPrint('[DesignerBall] 准备进入录音模式，_pointerDown=$_pointerDown');

    // 最终检查：手已离开 → 只设置 chatMode 但不开始录音
    setState(() => _chatMode = true);
    if (!_pointerDown) {
      debugPrint('[DesignerBall] Pointer lifted before startListening, skipping');
      return;
    }

    debugPrint('[DesignerBall] 调用 _startListening');
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

    debugPrint('[DesignerBall] ASR决策: asrMode=${_asrMode.name}');

    switch (_asrMode) {
      case AsrMode.offline:
        _startSherpaAsr();
        break;
      case AsrMode.bytedance:
        _startBytedanceAsr();
        break;
      default:
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

    switch (_asrMode) {
      case AsrMode.offline:
        _sherpaAsr.stopListening();
        _sherpaAsr.onResult = null;
        break;
      case AsrMode.bytedance:
        _bytedanceAsr.stopListening();
        break;
      default:
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

  Future<void> _enterEditMode() async {
    debugPrint('[DesignerBall] Entering edit mode');
    final initialText = _liveTranscript?.trim() ?? '';
    _accumulatedTranscript = ''; // 清空累积文本，防止下次录音叠加旧内容

    // 编辑模式 = 最高权限：彻底切断所有语音源（停录音 + 清回调）。
    _sherpaAsr.stopListening();
    _sherpaAsr.onResult = null;
    _sherpaAsr.onStatusChange = null;
    _bytedanceAsr.stopListening();
    // 注意：_bytedanceAsr.onResult 不在此处清空（在 _initBytedanceAsr 中一次性注册），
    // 改在回调内用 _editMode 守卫拦截。
    try { _speech?.stop(); } catch (_) {}

    _pulseController.stop();
    _pulseController.reset();
    setState(() {
      _isListening = false;
      _liveTranscript = null;
      _dragCancelling = false;
      _dragInEditZone = false;
      _editMode = true; // 仅用于隐藏悬浮球
    });

    // 关键：用 showModalBottomSheet 把 TextField 推进独立的 Navigator route。
    // 它在自己的 Overlay 子树里渲染，与 DesignerBall 的 setState 完全隔离 ——
    // 父级 rebuild 多少次都不会触达 sheet 的 State，TextEditingController 不会被
    // 重置，IME 状态稳定。这是 Flutter 处理"文本编辑弹层"的标配做法。
    //
    // 注意：DesignerBall 是包在 MaterialApp 外面的（builder: (_, child) => DesignerBall(child: child)），
    // 它自己的 context 找不到 Navigator。需要通过 MaterialApp 的 navigatorKey 拿到下方的 Navigator context。
    final navContext = JsonDslApp.navigatorKey.currentContext;
    if (navContext == null) {
      debugPrint('[DesignerBall] No navigator context, abort edit mode');
      if (mounted) setState(() => _editMode = false);
      return;
    }
    final result = await showModalBottomSheet<String>(
      context: navContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (sheetContext) => _EditSheet(initialText: initialText),
    );

    if (!mounted) return;
    setState(() => _editMode = false);

    if (result != null && result.trim().isNotEmpty) {
      _sendTextToAi(result.trim());
    }
  }

  void _sendTextToAi(String text, {bool skipUserMessage = false}) {
    _cancelCurrentStream();

    if (!skipUserMessage) {
      setState(() {
        _messages.add(ChatMessage(role: 'user', content: text));
        _messages.add(ChatMessage(role: 'assistant', content: ''));
        _isThinking = true;
      });
      _scrollToBottom();
    }

    _attachAiStream(_chatService.sendStream(text));
  }

  /// 把一个 AI 事件流接到 UI。三处用：
  /// (1) _sendTextToAi 正常发消息
  /// (2) 启动恢复 (_maybeResumeUnfinishedSession 拿到的 ResumeStreaming)
  /// (3) 重试按钮 (_handleRetryLastTurn)
  ///
  /// 调用方负责在调本方法之前把 user 气泡 / 空 assistant 气泡先注入好。
  void _attachAiStream(Stream<ChatEvent> stream) {
    // 用于累积流式事件中的指令，[DONE] 时统一处理
    Map<String, dynamic>? pendingJsonApp;
    String? pendingRequestAction;
    String? pendingFailedJsonUrl;
    String? pendingFailedJsonError;
    String? pendingJsonUrl;

    _streamSub = stream.listen(
      (event) {
        if (event.isGeneratingJson) {
          setState(() {
            _isGeneratingJson = true;
            _generatingStatusMessage = '正在启动 AI 引擎...';
          });
          _scrollToBottom();
          return;
        }
        if (event.statusMessage != null) {
          setState(() {
            // 有工具动作时直接在浮层里显示，避免看起来像卡住
            _isGeneratingJson = true;
            _generatingStatusMessage = event.statusMessage!;
          });
          _scrollToBottom();
          return;
        }
        // worker 真死了 / 重连耗尽 / CLI 被外部 kill / CLI 异常退出
        // → 把空气泡换成"中断"系统消息 + 重试按钮
        // ⚠️ needsRetry 必须在 error 之前判断（同一事件常常两个字段都有：
        //    backend 把 error 和 needs_retry:true 一起塞过来）
        if (event.needsRetry) {
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            _generatingStatusMessage = '正在生成代码...';
            // 如果同时有 error 且最后一个 assistant 气泡是空的，先把 error 写进去
            // 这样用户既能看到"为啥失败了"也能看到下面的重试按钮
            if (event.error != null &&
                _messages.isNotEmpty &&
                _messages.last.role == 'assistant' &&
                _messages.last.content.isEmpty) {
              _messages.last = ChatMessage(role: 'assistant', content: event.error!);
            } else if (event.error == null &&
                _messages.isNotEmpty &&
                _messages.last.role == 'assistant' &&
                _messages.last.content.isEmpty) {
              // 没 error 但有空气泡（idle timeout / 探活检测出来的纯断连）→ 删掉
              _messages.removeLast();
            }
            // 已有 partial 内容时不动它，让用户看到 AI 已经流过的部分
            _messages.add(ChatMessage(
              role: 'system',
              content: 'AI 任务被中断，点击重试',
              action: 'RETRY_LAST_TURN',
            ));
          });
          _scrollToBottom();
          return;
        }
        if (event.error != null && event.content == null) {
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            _generatingStatusMessage = '正在生成代码...';
            if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
              _messages.last = ChatMessage(role: 'assistant', content: event.error!);
            } else {
              _messages.add(ChatMessage(role: 'assistant', content: event.error!));
            }
          });
          _scrollToBottom();
          return;
        }

        // 累积指令，不立即处理
        if (event.requestAction != null) {
          pendingRequestAction = event.requestAction;
          return;
        }
        if (event.jsonApp != null) {
          pendingJsonApp = event.jsonApp;
          _lastGeneratedJson = event.jsonApp;
          return;
        }
        if (event.failedJsonUrl != null) {
          pendingFailedJsonUrl = event.failedJsonUrl;
          pendingFailedJsonError = event.error;
          return;
        }
        if (event.pendingJsonUrl != null) {
          pendingJsonUrl = event.pendingJsonUrl;
          return;
        }

        if (event.thinking != null) {
          // 思考过程 → 只更新最后一条消息（如果是空的或思考消息）
          setState(() {
            _isThinking = false;
            // ⚠️ 不要在这里关 _isGeneratingJson：后端在 thinking 块开始时
            // 会主动发 status="thinking" 让转圈亮起来；如果这里关掉，转圈
            // 会被 thinking_delta 第一帧立刻熄掉，用户体感"无反应"。
            // 转圈的关闭由真正的内容到达（event.content）或 onDone 负责。
            if (_messages.isNotEmpty &&
                _messages.last.role == 'assistant' &&
                (_messages.last.content.isEmpty || _messages.last.content.startsWith('💭'))) {
              _messages.last = ChatMessage(role: 'assistant', content: '💭 ${event.thinking!}');
            }
          });
          _scrollToBottom();
          return;
        }
        if (event.content != null) {
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            if (_messages.isNotEmpty &&
                _messages.last.role == 'assistant' &&
                _messages.last.content.startsWith('💭')) {
              _messages.add(ChatMessage(role: 'assistant', content: event.content!));
            } else if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
              _messages.last = ChatMessage(role: 'assistant', content: event.content!);
            }
          });
          _scrollToBottom();
        }
        if (event.quota != null) {
          _lastQuota = event.quota;
        }
      },
      onError: (e) {
        _streamSub = null;
        setState(() {
          _isThinking = false;
          _isGeneratingJson = false;
          _generatingStatusMessage = '正在生成代码...';
          if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
            _messages.last = ChatMessage(role: 'assistant', content: '出错了: $e');
          } else {
            _messages.add(ChatMessage(role: 'assistant', content: '出错了: $e'));
          }
        });
      },
      onDone: () {
        _streamSub = null;
        debugPrint('[DesignerBall] AI stream onDone: '
            'pendingRequestAction=$pendingRequestAction, '
            'pendingJsonUrl=${pendingJsonUrl != null ? "<${pendingJsonUrl!.length} chars>" : "null"}, '
            'pendingFailedJsonUrl=$pendingFailedJsonUrl, '
            'pendingJsonApp=${pendingJsonApp != null}');
        setState(() {
          _isGeneratingJson = false;
          _generatingStatusMessage = '正在生成代码...';

          // ⚠️ 这里**必须**用独立 if 而不是 if/else if 链：
          // AI 一次回复里完全可能同时包含 [request_action]upload_current_app[/request_action]
          // 和 [json_app_url]…[/json_app_url]（"我需要先看代码 ... 不过链接给你"）。
          // 老的 else-if 链让 UPLOAD 抢占，下载按钮就消失了——这是 P0 bug。
          // 各按钮语义独立，应该共存：UPLOAD 让用户提供代码、下载让用户拿 app、
          // 试运行让用户直接跑、失败重试让用户重下。
          if (pendingRequestAction == 'upload_current_app') {
            _messages.add(ChatMessage(
              role: 'system',
              content: 'AI 需要获取当前应用的代码配置以进行修改：',
              action: 'UPLOAD_CURRENT_APP',
            ));
          }
          if (pendingJsonUrl != null) {
            _messages.add(ChatMessage(
              role: 'system',
              content: 'JSON-APP 已生成，点击下载并运行：',
              jsonUrl: pendingJsonUrl,
            ));
          }
          if (pendingFailedJsonUrl != null) {
            _messages.add(ChatMessage(
              role: 'system',
              content: pendingFailedJsonError ?? '下载 JSON 失败',
              failedJsonUrl: pendingFailedJsonUrl,
            ));
          }
          if (pendingJsonApp != null) {
            _messages.add(ChatMessage(
              role: 'system',
              content: '🚀 点击试运行',
              jsonApp: pendingJsonApp,
            ));
          }
        });
        _scrollToBottom();
      },
    );
  }

  /// 重试按钮回调。3 秒 debounce 防止用户连点。
  bool _retryDebouncing = false;
  void _handleRetryLastTurn() {
    if (_retryDebouncing) {
      debugPrint('[DesignerBall] 重试 debounce 中，忽略');
      return;
    }
    _retryDebouncing = true;
    Future.delayed(const Duration(seconds: 3), () => _retryDebouncing = false);

    setState(() {
      // 移除 RETRY_LAST_TURN 那条系统消息
      if (_messages.isNotEmpty &&
          _messages.last.role == 'system' &&
          _messages.last.action == 'RETRY_LAST_TURN') {
        _messages.removeLast();
      }
      // 加一个新的空 assistant 气泡承接新流
      _messages.add(ChatMessage(role: 'assistant', content: ''));
      _isThinking = true;
    });
    _scrollToBottom();

    _cancelCurrentStream();
    _attachAiStream(_chatService.retryLastTurn());
  }

  /// app 启动时调一次：检查后端有没有上一轮未完成 / 已完成的任务，按情况注入消息
  Future<void> _maybeResumeUnfinishedSession() async {
    if (!mounted) return;
    try {
      final result = await _chatService.tryResumeUnfinished();
      if (!mounted) return;
      switch (result) {
        case ResumeNothing():
          break;
        case ResumeCompleted(
            :final userMessage,
            :final assistantText,
            :final jsonUrl,
            :final requestAction,
          ):
          setState(() {
            _messages.add(ChatMessage(role: 'user', content: userMessage));
            _messages.add(ChatMessage(role: 'assistant', content: assistantText));
            // 各按钮独立共存（同一回复可能既要 upload 又给 url，参考 6645d35）
            if (requestAction == 'upload_current_app') {
              _messages.add(ChatMessage(
                role: 'system',
                content: 'AI 需要获取当前应用的代码配置以进行修改：',
                action: 'UPLOAD_CURRENT_APP',
              ));
            }
            if (jsonUrl != null) {
              _messages.add(ChatMessage(
                role: 'system',
                content: 'JSON-APP 已生成，点击下载并运行：',
                jsonUrl: jsonUrl,
              ));
            }
          });
          _scrollToBottom();
        case ResumeStreaming(:final userMessage, :final stream):
          setState(() {
            _messages.add(ChatMessage(role: 'user', content: userMessage));
            _messages.add(ChatMessage(role: 'assistant', content: ''));
            _isThinking = true;
            _isGeneratingJson = true;
            _generatingStatusMessage = '正在恢复上次对话...';
          });
          _scrollToBottom();
          _attachAiStream(stream);
        case ResumeNeedsRetry(:final userMessage):
          setState(() {
            _messages.add(ChatMessage(role: 'user', content: userMessage));
            _messages.add(ChatMessage(
              role: 'system',
              content: 'AI 任务被中断（可能服务器进程异常），点击重试',
              action: 'RETRY_LAST_TURN',
            ));
          });
          _scrollToBottom();
      }
    } catch (e) {
      debugPrint('[DesignerBall] resume 失败 (静默): $e');
    }
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
      // 自动发送一条消息继续流程，并把链接明确显示在对话框中
      _sendTextToAi('$appContextString\n\n请查阅以上代码配置并继续完成我的要求。');
    } catch (e) {
      setState(() {
        _isThinking = false;
        _messages.removeLast();
        // 失败时重新放出 UPLOAD 按钮，让用户可以再点一次
        // ai_chat_service 内部已自动重试 3 次（指数退避），到这里说明确实有问题
        _messages.add(ChatMessage(
          role: 'system',
          content: '❌ 上传失败：$e\n\n点击下方按钮可再次尝试。',
          action: 'UPLOAD_CURRENT_APP',
        ));
      });
      _scrollToBottom();
    }
  }

  Future<void> _handleRetryDownload(String url) async {
    setState(() {
      _messages.removeLast(); // 移除重试按钮那条消息
      _isGeneratingJson = true; // 显示骨架屏动画
    });
    _scrollToBottom();

    try {
      final parsedApp = await _chatService.retryDownloadJson(url);
      _lastGeneratedJson = parsedApp;
      setState(() {
        _isGeneratingJson = false;
        _messages.add(ChatMessage(
          role: 'system',
          content: '🚀 JSON-APP 已成功下载，点击试运行',
          jsonApp: parsedApp,
        ));
      });
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _isGeneratingJson = false;
        _messages.add(ChatMessage(
          role: 'assistant',
          content: '下载重试失败: $e',
          failedJsonUrl: url,
        ));
      });
      _scrollToBottom();
    }
  }

  Future<void> _handleDownloadAndRun(String url) async {
    final parsedApp = await _chatService.retryDownloadJson(url);
    _lastGeneratedJson = parsedApp;
    widget.onRunJsonApp?.call(parsedApp);
    Future.microtask(() {
      if (mounted) {
        _clearAndCloseChatMode();
      }
    });
  }

  /// 原生语音识别 (Apple/Google) — 参照 speech_to_text 官方 demo 的最小实现，
  /// 不做任何 finalResult 自动重启，避免反复申请/释放麦克风。
  void _startNativeSpeech() {
    if (_speech == null) return;
    try {
      _speech!.listen(
        onResult: (result) {
          // 编辑模式下，stop() 后迟到的 final 结果一律丢弃
          if (!_isListening || _editMode) return;
          _nativeSpeechReceivedCallback = true;
          final text = result.recognizedWords;
          if (_liveTranscript != text) {
            setState(() => _liveTranscript = text);
          }
        },
        localeId: 'zh_CN',
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 5),
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
      );
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
        // 编辑模式下，迟到的 ASR 结果一律丢弃
        if (!_isListening || _editMode) return;
        // 优化：只在文本变化时更新 UI，减少不必要的重建
        if (_liveTranscript != text) {
          setState(() => _liveTranscript = text);
        }
      };

      final ok = await _sherpaAsr.startListening();
      if (!ok) {
        setState(() {
          _isListening = false;
          _messages.add(ChatMessage(
            role: 'assistant',
            content: '麦克风权限未授予，请在手机「设置 → 应用 → 权限」中开启麦克风权限后重试',
          ));
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

  /// 启动豆包ASR识别
  Future<void> _startBytedanceAsr() async {
    debugPrint('[DesignerBall] 启动豆包ASR识别');
    try {
      // 检查连接状态
      if (!_bytedanceAsr.isConnected) {
        debugPrint('[DesignerBall] ByteDance ASR not connected');
        setState(() {
          _isListening = false;
          _messages.add(ChatMessage(role: 'assistant', content: '豆包ASR未连接，请检查网络'));
        });
        _pulseController.stop();
        _pulseController.reset();
        return;
      }

      // 开始识别
      final ok = await _bytedanceAsr.startListening();
      if (!ok) {
        setState(() {
          _isListening = false;
          _messages.add(ChatMessage(
            role: 'assistant',
            content: '麦克风权限未授予，请在手机「设置 → 应用 → 权限」中开启麦克风权限后重试',
          ));
        });
        _pulseController.stop();
      }
    } catch (e) {
      debugPrint('[ByteDanceASR] Start error: $e');
      setState(() {
        _isListening = false;
        _messages.add(ChatMessage(role: 'assistant', content: '豆包ASR启动失败: $e'));
      });
      _pulseController.stop();
    }
  }

  Future<void> _stopListeningAndSend() async {
    debugPrint('[DesignerBall] _stopListeningAndSend');

    // 停止语音识别
    switch (_asrMode) {
      case AsrMode.offline:
        _sherpaAsr.onResult = null;
        final finalText = await _sherpaAsr.stopListening();
        if (finalText.isNotEmpty) {
          _liveTranscript = finalText;
        }
        break;
      case AsrMode.bytedance:
        await _bytedanceAsr.stopListening();
        break;
      default:
        try { await _speech?.stop(); } catch (e) {
          debugPrint('[DesignerBall] speech.stop error: $e');
        }
    }

    // 重要：先完全重置语音相关状态，让 iOS 释放麦克风资源
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

    // 先原子更新 UI，彻底退出录音态
    setState(() {
      _isListening = false;
      _liveTranscript = null;
      _messages.add(ChatMessage(role: 'user', content: text));
      _messages.add(ChatMessage(role: 'assistant', content: ''));
      _isThinking = true;
    });
    _scrollToBottom();

    // 关键优化：给 iOS 一点时间释放语音识别资源，再启动 AI 请求
    await Future.delayed(const Duration(milliseconds: 300));

    // 中断上一条还在进行的流
    _cancelCurrentStream();

    // 启动 AI 处理
    _sendTextToAi(text, skipUserMessage: true);
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
      // 只关本地：本方法的下游通常马上要 sendStream/retryLastTurn（带 force_restart），
      // backend 自己会处理旧 worker。这里发 POST /abort 会和新 worker 起步竞态。
      // 唯一例外是 _clearAndCloseChatMode (用户点清空)，那条路径走 _chatService.clear()
      // → resetSession() → 内部用完整 abort()，不依赖这里
      _chatService.abortLocal();
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
    _chatService.clear(); // resetSession is async but fire-and-forget is fine here
  }

  /// 双击 heavyImpact，主观上明显比单次更"重"。
  /// 用于进入对话模式等关键状态切换；普通触摸/拖拽别用，会很烦。
  Future<void> _strongHapticBurst() async {
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 70));
    if (!mounted) return;
    HapticFeedback.heavyImpact();
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

        // 字幕覆层 — 编辑模式下隐藏，避免半透明字幕叠在编辑 sheet 上方
        // （DesignerBall 包在 Navigator 外面，sheet 在 widget.child 内的 Overlay 里，
        // 自然位于 ChatOverlay 之下；进入编辑模式时摘掉字幕，sheet 才能完整可见）
        if (_chatMode && !_editMode)
          ChatOverlay(
            messages: _messages,
            isListening: _isListening,
            isThinking: _isThinking,
            isGeneratingJson: _isGeneratingJson,
            generatingStatusMessage: _generatingStatusMessage,
            liveTranscript:
                (_liveTranscript?.isNotEmpty ?? false) ? _liveTranscript : null,
            onClose: _closeChatMode,
            onClear: _clearAndCloseChatMode,
            scrollController: _scrollController,
            onProviderChanged: _onProviderChanged,
            onUploadCurrentApp: _handleUploadCurrentApp,
            onRetryDownload: _handleRetryDownload,
            onDownloadAndRun: _handleDownloadAndRun,
            onRetryLastTurn: _handleRetryLastTurn,
            onRunJsonApp: (jsonConfig) {
              // 先调用外部回调，再清空聊天
              widget.onRunJsonApp?.call(jsonConfig);
              // 延迟清空，避免 UI 重建冲突
              Future.microtask(() {
                if (mounted) {
                  _clearAndCloseChatMode();
                }
              });
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

        // 编辑窗在 showModalBottomSheet 里渲染，不在此处构建。

        // 悬浮球 — 编辑模式下隐藏，避免拦截输入框光标/删除事件
        if (!_editMode)
          Positioned(
            left: _left,
            top: _top,
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: (e) => _onPointerMove(e, screenSize),
              onPointerUp: (e) => _onPointerUp(e, screenSize),
              onPointerCancel: (e) => _onPointerCancel(e, screenSize),
              child: GestureDetector(
                onTap: () => _onTap(screenSize),
                onDoubleTap: _onDoubleTap,
                // 把 key 挂在 _buildBall 返回的 widget 上：那才是聚光灯切口要圈的"球"本体
                child: KeyedSubtree(
                  key: OnboardingKeys.designerBall,
                  child: _buildBall(context),
                ),
              ),
            ),
          ),
      ],
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

    // 是否有后台 AI 会话（已经攒了消息或正在 stream）→ 给悬浮球加一圈外环表示
    // 比原来在球内画小红点视觉上更克制
    final hasBackgroundSession = _messages.isNotEmpty || _streamSub != null;
    final ringColor = isDark ? const Color(0xFFFFB74D) : const Color(0xFFFB8C00);

    Widget ball = Container(
      width: _ballSize,
      height: _ballSize,
      decoration: BoxDecoration(
        color: ballColor,
        shape: BoxShape.circle,
        // 后台会话指示：在球的边缘画一圈 amber 环
        border: hasBackgroundSession
            ? Border.all(color: ringColor, width: 2.5)
            : null,
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
                // 默认：黑白线性麦克风图标（替代原 'D' 字母）
                : Icon(
                    Icons.mic_none_outlined,
                    color: iconColor,
                    size: 26,
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
    if (_pointerDown && !_movedEnough && !_isListening) {
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

// ════════════════════════════════════════════════════════
// 编辑窗 — 用 showModalBottomSheet 渲染在独立 Navigator route
//
// 设计原则（用户原话："文本编辑模式下，编辑窗口就是最高权限"）：
//   - sheet 在 Overlay 子树里渲染，与 DesignerBall widget 树物理隔离
//   - 父级 setState 不会触达 sheet 内部，TextEditingController 不会被重置
//   - sheet pop 时返回 String（发送）或 null（取消）
// ════════════════════════════════════════════════════════

class _EditSheet extends StatefulWidget {
  final String initialText;

  const _EditSheet({required this.initialText});

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.selection = TextSelection.collapsed(offset: widget.initialText.length);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    Navigator.of(context).pop(_controller.text);
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 与 ChatOverlay 保持一致：永远深色，不跟随系统主题，避免出现"白底白字"或主题穿透问题
    const bgColor = Color(0xFF1C1C1E);
    const textColor = Colors.white;
    final panelColor = Colors.white.withValues(alpha: 0.08);
    final hintColor = Colors.white.withValues(alpha: 0.3);
    final borderColor = Colors.white.withValues(alpha: 0.1);
    final secondaryTextColor = Colors.white.withValues(alpha: 0.7);
    final iconColor = Colors.white.withValues(alpha: 0.6);

    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      // 让 sheet 跟随键盘上推
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: SafeArea(
        top: false,
        child: Material(
          color: bgColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题栏
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: borderColor)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.edit_note,
                        color: Colors.white.withValues(alpha: 0.5), size: 18),
                    const SizedBox(width: 6),
                    Text(
                      '编辑消息',
                      style: TextStyle(
                        color: secondaryTextColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _cancel,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.close, color: iconColor, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
              // 编辑区
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 120, maxHeight: 240),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    maxLines: null,
                    minLines: 4,
                    textAlignVertical: TextAlignVertical.top,
                    cursorColor: Colors.white,
                    style: const TextStyle(
                      color: textColor,
                      fontSize: 16,
                      height: 1.6,
                    ),
                    decoration: InputDecoration(
                      // ⚠️ 必须显式 filled:false。Material 3 inputDecorationTheme
                      // 在 light mode 下默认会给 TextField 灌一个浅灰色 fill，
                      // 盖在我们外层 0xFF1C1C1E 的深色 Material 上 → 看着是
                      // "深色弹窗中间一条白色编辑区"。dark mode 下默认 fill 也
                      // 深色所以察觉不到。这里关掉它，让父级 Material 直接透出来。
                      filled: false,
                      border: InputBorder.none,
                      hintText: '编辑你的消息...',
                      hintStyle: TextStyle(color: hintColor, fontSize: 16),
                    ),
                  ),
                ),
              ),
              // 底部操作栏
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _cancel,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: panelColor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            color: secondaryTextColor,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _send,
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
}

/// 快捷菜单单格按钮。圆角方形 + icon + 文字两行布局。
/// 禁用态用 onSurfaceVariant 灰文字 + 长按 tooltip 解释为啥灰了。
class _QuickMenuButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final String? tooltipDisabled;

  const _QuickMenuButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.tooltipDisabled,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = enabled ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.4);
    final textColor = enabled ? cs.onSurface : cs.onSurfaceVariant.withValues(alpha: 0.5);
    final bg = cs.surfaceContainerHighest.withValues(alpha: enabled ? 0.6 : 0.3);

    final btn = Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26, color: iconColor),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: textColor),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );

    if (!enabled && tooltipDisabled != null) {
      return Tooltip(message: tooltipDisabled!, child: btn);
    }
    return btn;
  }
}
