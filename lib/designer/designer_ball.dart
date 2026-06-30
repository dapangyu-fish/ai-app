import 'dart:async';
import 'dart:convert';
import 'dart:math' show sqrt, pi;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'ai_chat_service.dart';
import 'chat_overlay.dart';
import 'bytedance_asr_service.dart';
import 'gesture_exclusion_helper.dart';
import '../config/app_config.dart';
import '../auth/auth_service.dart';
import '../i18n/framework_strings.dart';
import '../main.dart' show JsonDslApp, appLifecycleEvent;
import '../onboarding/onboarding_keys.dart';

/// 语音识别方式枚举
enum AsrMode {
  online, // 在线识别（speech_to_text）
  bytedance, // 豆包ASR
}

/// 全局 ASR 模式管理 —— 让 settings_page 改完之后悬浮球能立刻感知。
///
/// 之前 bug：DesignerBall 在 initState 里读一次 SharedPreferences 就缓存到
/// `_asrMode` 字段，永远不再刷新。settings_page 写了 prefs，但 DesignerBall
/// 是 MaterialApp 外层的常驻 widget，永远不会重新 initState，结果用户切到
/// "豆包"，运行时 `_asrMode` 还是启动时的旧值，体感"切了没切成功"。
class AsrModePrefs {
  AsrModePrefs._();

  static final ValueNotifier<AsrMode> notifier = ValueNotifier(AsrMode.online);

  static AsrMode _decode(String? s) {
    switch (s) {
      case 'bytedance':
        return AsrMode.bytedance;
      default:
        return AsrMode.online;
    }
  }

  static String _encode(AsrMode m) {
    switch (m) {
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

  const DesignerBall({
    super.key,
    required this.child,
    this.onRunJsonApp,
    this.getCurrentConfig,
  });

  @override
  State<DesignerBall> createState() => _DesignerBallState();
}

class _DesignerBallState extends State<DesignerBall>
    with TickerProviderStateMixin {
  static const String _messageBucketKeyPrefix = 'ai_messages_v1_';
  static const int _maxPersistedMessagesPerSession = 120;
  static const int _maxPersistedMessageBytes = 900 * 1024;

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
  // 快捷菜单弹出态。第二次双击（菜单还开着的情况下）应该关掉它，而不是
  // 再叠一层弹窗
  bool _quickMenuOpen = false;
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
  // 平台（Android SpeechRecognizer / iOS SFSpeechRecognizer）单次会话有 10-60s
  // 上限，用户按着球时长按下去到 done/error 时要无感重启。这个 flag 在主动 stop
  // 之前置 true，防止主动停止被识别为"该重启"。
  bool _intentionalNativeStop = false;
  // ⚠️ 不要直接读这个字段，用 _asrMode getter，永远拿到 AsrModePrefs 最新值。
  // 历史 bug：缓存了 initState 时的旧值，settings 改完不感知。
  AsrMode get _asrMode => AsrModePrefs.notifier.value;
  final ByteDanceAsrService _bytedanceAsr = ByteDanceAsrService.instance;
  final AiChatService _chatService = AiChatService();
  StreamSubscription<ChatEvent>? _streamSub;
  int _streamEpoch = 0;
  bool _resumeInFlight = false;
  bool _appResumeProbeInFlight = false;
  Timer? _appResumeFollowUpTimer;
  Timer? _sessionReconcileTimer;
  bool _sessionReconcileInFlight = false;
  // 老的 5s 独立 heartbeat 已被删掉。新逻辑：
  // - SSE 内部 20s idle timeout → _checkAliveCarefully 三态探活
  // - 后端 worker 自身在 CLI 异常退出 / 外部 kill 时主动写 needs_retry 事件
  // 两条路径都收敛到 needsRetry → UI 弹重试按钮，不再需要独立 timer。
  Map<String, dynamic>?
  _lastGeneratedJson; // ignore: unused_field — Phase 3 试运行用
  Map<String, dynamic>? _lastQuota; // ignore: unused_field — Phase 3 配额显示用
  // 多会话：消息按 sid 分桶；getter `_messages` 永远返回当前 active 那一桶。
  // 切 active session 时 setState 会重 build，自动展示新桶。
  final Map<String, List<ChatMessage>> _messageBuckets = {};
  final Set<String> _loadedMessageBucketIds = {};
  Timer? _messagePersistTimer;
  List<ChatMessage> get _messages {
    final sid = _chatService.sessionId;
    final key = sid.isEmpty ? '__pending__' : sid;
    return _messageBuckets.putIfAbsent(key, () => []);
  }

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
    AiChatService.agentRoutingRevision.addListener(_onAgentScopeChanged);
    // 加载 AI 对话 session，加载完之后异步检查上一轮有没有未完成 / 已完成的任务
    // 不 await，不阻塞 UI 启动
    _chatService.loadSession().then((_) async {
      await _refreshAiRoutingOptions();
      await _loadMessagesForSession(_chatService.sessionId);
      if (!mounted) return;
      setState(() {});
      await _maybeResumeUnfinishedSession();
    });

    // DesignerBall 挂在 MaterialApp.builder 里凌驾所有路由，**不会**因为 AuthGate
    // 切换 (FilePickerPage <-> AuthPage) 而重建。所以"用户掉登录后重新登录"这个
    // 场景下，initState 不会再跑——必须显式监听登录态切换，重新触发 resume。
    AuthService.authNotifier.addListener(_onAuthChanged);
    appLifecycleEvent.addListener(_onAppLifecycleChanged);

    // 提前初始化原生语音识别（参照测试应用的成功实践）
    _initNativeSpeech();

    // 初始化豆包ASR连接
    _initBytedanceAsr();
  }

  /// notifier → 悬浮球内部状态：设置页改完能立刻生效
  void _onAsrModeChanged() {
    if (!mounted) return;
    setState(() {}); // _asrMode 是 getter，rebuild 自然拿新值
    debugPrint(
      '[DesignerBall] ASR mode changed -> ${AsrModePrefs.notifier.value.name}',
    );
  }

  /// 设置页切换 平台/私有 agent node → 悬浮球立即重建字幕选择器（之前要等下一次自发
  /// setState 才同步）。switchAgentScope 已拉好新 scope 的 providers，这里只需把未提交的
  /// 活跃会话收敛到新 scope 再 rebuild。
  void _onAgentScopeChanged() {
    if (!mounted) return;
    unawaited(() async {
      await _chatService.reconcileActiveScopeIfUnlocked();
      if (mounted) setState(() {});
    }());
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
              _messages.add(
                ChatMessage(
                  role: 'assistant',
                  content: T.fmt(T.current.asrErrBytedanceWith, {'err': error}),
                ),
              );
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
          // 不在这里 restart——csdcorp/speech_to_text issue #253 显示在 onError 里
          // restart 会触发 error_busy 级联。errors 不 cancel 引擎（cancelOnError:false），
          // 平台后续会自然给 done status，统一走 onStatus 路径重启。
          debugPrint(
            '[DesignerBall] Speech error: ${error.errorMsg} permanent=${error.permanent}',
          );
        },
        onStatus: (status) {
          debugPrint('[DesignerBall] Speech status: $status');
          // 不能只看 doneStatus —— iOS 上 SFSpeechRecognizer 超时走的是
          // FinishedReadingAudio 路径，plugin 只发 notListening，doneStatus 永远
          // 不会 fire（因为它依赖 _notifiedFinal && _notifiedDone 同时为 true）。
          // 见 SpeechToTextPlugin.swift:731+ 和 csdcorp issue #218。
          // 凡是不是 listeningStatus 的状态都视为会话结束，尝试重启。
          if (status != stt.SpeechToText.listeningStatus) {
            _scheduleRestartNativeSession(reason: 'status_$status');
          }
        },
      );
      debugPrint(
        '[DesignerBall] Native speech initialized in initState: $_speechInited',
      );
    } catch (e) {
      debugPrint('[DesignerBall] Native speech init failed: $e');
      _speechInited = false;
    }
  }

  /// 在平台自动停掉一段会话后，检查是否还需要继续录下一段。
  ///
  /// iOS 上 SFSpeechRecognizer 超时走 speechRecognitionTaskFinishedReadingAudio
  /// 这条 delegate 路径只发 notListening 状态，**不**调 audioEngine.stop() / removeTap()
  /// / audioSession.setActive(false)，currentTask 也不清空。如果直接 listen()，
  /// AVAudioEngine 会越叠越脏，第二次 restart 时撞 `nullptr == Tap()` 崩溃
  /// （issue #118、#241、#481 都是这个家族）。
  ///
  /// 所以这里**显式 await _speech.stop()** 强制走 Swift 那条完整 cleanup
  /// （SpeechToTextPlugin.swift:425-468），再等 300ms 让 AVAudioSession 异步
  /// 去激活落定，再 listen。
  void _scheduleRestartNativeSession({required String reason}) {
    Future.delayed(const Duration(milliseconds: 80), () async {
      if (!mounted) return;
      if (_intentionalNativeStop) {
        debugPrint(
          '[DesignerBall] Skip native restart (intentional stop): $reason',
        );
        return;
      }
      if (!_isListening || _editMode) return;
      if (_asrMode != AsrMode.online) return;
      if (!_pointerDown) return;
      if (_speech == null) return;

      // iOS partial-freeze 场景下 finalResult 可能从未 fire，
      // _liveTranscript 里有段 1 的可见文本但没并入 _accumulatedTranscript。
      // restart 前抢救：如果 live > accumulated，立刻并入。
      final live = _liveTranscript?.trim() ?? '';
      if (live.length > _accumulatedTranscript.length) {
        debugPrint(
          '[DesignerBall] Rescuing live partial → accumulated: "$live"',
        );
        _accumulatedTranscript = live;
      }

      // 显式 stop 强制完整 cleanup（关键，否则 30s 第二次 restart 必崩）
      debugPrint('[DesignerBall] Force stop before restart ($reason)');
      _intentionalNativeStop = true;
      try {
        await _speech!.stop();
      } catch (e) {
        debugPrint('[DesignerBall] Force stop error: $e');
      }
      // 给 AVAudioSession.setActive(false) 异步落定的时间
      await Future.delayed(const Duration(milliseconds: 300));

      if (!mounted) return;
      if (!_isListening || _editMode || !_pointerDown) {
        debugPrint(
          '[DesignerBall] User released during restart cleanup, abort',
        );
        return;
      }

      _intentionalNativeStop = false;
      debugPrint(
        '[DesignerBall] Restarting native ASR segment ($reason), accumulated.len=${_accumulatedTranscript.length}',
      );
      _doStartNativeSession();
    });
  }

  @override
  // ── 打字机缓冲（AI 回复平滑吐字）──────────────────────────────────────
  // 真实生成里 codex/opencode 等按「整条消息」吐文本（非 token deltas），加上 SSE 成批投递，
  // 直接整段上屏会「一大段一大段」跳。这里把「已收到全文」(_typeFull) 与「已显示长度」
  // (_typeShown) 解耦，用一个 ~60fps timer 平滑地把显示推进到目标，体感像逐字流式。
  // 对所有 provider/agent + demo 回放都生效，且免疫 SSE 突发。
  Timer? _typeTimer;
  String _typeFull = '';
  int _typeShown = 0;
  bool _typeIsThinking = false;
  int _typeScrollTick = 0;
  // 打字机归属的会话：与流同理，active 切走后不能再把这条流的文字写进别的会话桶。
  String _typeOwnerSid = '';

  // 动态吐字速率（自适应「正文到达速度」）。目标：显示速度 ≈ 服务端正文到达速度并略慢
  // 一档，始终留一小段缓冲 → 连续吐字，消除「冲一段→追平→卡住→下一段」的突兵感。
  // 思考时间不计入速率估计（见 _setTypewriterTarget 的 _typeIsThinking 跳过 + 段切换重置）。
  double _typeCharsPerMs = 0.0; // EWMA 估计（字/ms）；0=还没样本，用默认
  int _typeRateWinMs = 0;       // 当前测速窗口起点 ms（0=未起窗，下个正文到达重新起）
  int _typeRateWinLen = 0;      // 窗口起点时的目标文本长度（基线）
  double _typeStepCarry = 0.0;  // 不足 1 字的步进余量累加器（支持 <60 字/秒的慢速连续吐字）

  static const int _typeTickMs = 16;
  static const int _typeRateWindowMs = 250;          // 测速窗口≥此值才取样 → 免疫 SSE 成批投递
  static const double _typeDefaultCharsPerMs = 0.04; // 没估计前 ~40 字/秒（偏慢，首块不突兵）
  static const double _typeMinCharsPerMs = 0.025;    // 速度下限 ~23 字/秒（再慢也不至于慢动作）
  static const double _typeMaxCharsPerMs = 1.0;      // 速率估计上限 ~1000 字/秒
  static const int _typeArrivalGapCapMs = 1500;      // 到达间隔超过此值不取样（思考/停顿/网络突发）
  static const double _typeRevealFactor = 0.92;      // 略慢于到达速率，留缓冲、不追平 → 不卡顿
  static const int _typeTargetLatencyMs = 320;       // 期望缓冲时长（显示落后服务端约这么久）
  static const double _typeTargetMinChars = 24.0;    // 缓冲字数下限：慢速小块不触发追赶式排空
  static const int _typeCatchupMs = 1200;            // 超出缓冲的积压在此窗口内匀速排掉
  static const int _typeMaxStep = 20;                // 速度上限 ~1250 字/秒，杜绝机枪式刷屏

  // 设置打字机目标（目标只增不减，_typeShown 持续往后吐）
  void _setTypewriterTarget(String full) {
    _typeOwnerSid = _chatService.sessionId; // 调用点已过 isCurrentStream，等于流归属 sid
    // 动态速率估计：只统计「正文」到达（思考段 _typeIsThinking=true 时跳过 → 思考时间
    // 不进入阈值计算）。用 ≥_typeRateWindowMs 的滑动窗口测「字/ms」，免疫 SSE 成批投递
    // 把同一段拆成几帧瞬时到达而把速率算虚高。
    if (!_typeIsThinking) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_typeRateWinMs == 0) {
        _typeRateWinMs = now;
        _typeRateWinLen = full.length; // 以「本次到达的累计长度」为窗口基线：
        // 测的是开窗后新增的正文，不能把开窗这帧已到的字算进下个窗口（否则速率虚高一倍）。
      } else {
        final dt = now - _typeRateWinMs;
        if (dt >= _typeRateWindowMs) {
          final dc = full.length - _typeRateWinLen;
          if (dc > 0 && dt <= _typeArrivalGapCapMs) {
            final double inst = (dc / dt)
                .clamp(_typeMinCharsPerMs, _typeMaxCharsPerMs)
                .toDouble();
            _typeCharsPerMs =
                _typeCharsPerMs == 0 ? inst : _typeCharsPerMs * 0.7 + inst * 0.3;
          }
          _typeRateWinMs = now; // 起新窗口
          _typeRateWinLen = full.length;
        }
      }
    }
    _typeFull = full;
    if (_typeShown > _typeFull.length) _typeShown = _typeFull.length;
    if (_typeShown < _typeFull.length) _ensureTypeTimer();
  }

  void _ensureTypeTimer() {
    _typeTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tickTypewriter(),
    );
  }

  void _tickTypewriter() {
    if (!mounted || _typeTimer == null) return;
    // 归属会话已不是当前 active（用户切走 / loadSession 改了 active）→ 停表，
    // 不把这条流的文字写进别的会话桶。该会话内容靠切回时的 resume 复原。
    if (_chatService.sessionId != _typeOwnerSid) {
      _typeTimer?.cancel();
      _typeTimer = null;
      return;
    }
    if (_typeShown >= _typeFull.length) {
      // 追平 → 停掉省电，下个目标到来再起
      _typeTimer?.cancel();
      _typeTimer = null;
      return;
    }
    final remaining = _typeFull.length - _typeShown;
    // 动态速率：吐字速度 ≈ 正文到达速度并略慢一档（留缓冲、不追平 → 不卡顿）；积压超出
    // 目标缓冲时由延迟控制器在 ~_typeCatchupMs 内匀速排掉。步进可 <1 字，用 carry 累加，
    // 支持 <60 字/秒 的慢速连续吐字；上限 _typeMaxStep 杜绝突发刷屏。
    int step;
    if (remaining <= 2) {
      step = remaining;
    } else {
      final double rate =
          (_typeCharsPerMs > 0 ? _typeCharsPerMs : _typeDefaultCharsPerMs)
              .clamp(_typeMinCharsPerMs, _typeMaxCharsPerMs)
              .toDouble();
      double stepF = rate * _typeTickMs * _typeRevealFactor;
      // 目标缓冲：rate×期望时长，但有字数下限 → 慢速时小块不会被误判成「积压」而追赶式排空。
      final double tgt = rate * _typeTargetLatencyMs;
      final double excess =
          remaining - (tgt > _typeTargetMinChars ? tgt : _typeTargetMinChars);
      if (excess > 0) stepF += excess * _typeTickMs / _typeCatchupMs;
      _typeStepCarry += stepF;
      step = _typeStepCarry.floor();
      _typeStepCarry -= step;
      if (step > _typeMaxStep) {
        step = _typeMaxStep;
        _typeStepCarry = 0.0;
      }
      if (step > remaining) step = remaining;
    }
    if (step <= 0) return; // 本帧不足 1 字，等 carry 攒够（慢速时常态，开销极小）
    _typeShown += step;
    if (_typeShown > _typeFull.length) _typeShown = _typeFull.length;
    // 不要把 emoji（UTF-16 代理对）切一半，否则会闪一帧 �
    if (_typeShown < _typeFull.length) {
      final unit = _typeFull.codeUnitAt(_typeShown - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) _typeShown += 1;
    }
    if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
      setState(() {
        _messages.last = ChatMessage(
          role: 'assistant',
          content: _typeFull.substring(0, _typeShown),
        );
      });
      if (_typeScrollTick++ % 4 == 0) _scrollToBottom();
    }
  }

  // 立即补全并停掉打字机（流结束/出错/切流时调用），保证最终文本完整。
  // 只改 _messages，不自带 setState —— 由调用方所在的 setState/重建负责刷新。
  void _flushTypewriter() {
    _typeTimer?.cancel();
    _typeTimer = null;
    _typeStepCarry = 0.0;
    if (_typeFull.isNotEmpty &&
        _typeShown < _typeFull.length &&
        _messages.isNotEmpty &&
        _messages.last.role == 'assistant') {
      _typeShown = _typeFull.length;
      _messages.last = ChatMessage(role: 'assistant', content: _typeFull);
    }
  }

  // 复位打字机（新一轮 / 切流 / 出错）
  void _resetTypewriter() {
    _typeTimer?.cancel();
    _typeTimer = null;
    _typeFull = '';
    _typeShown = 0;
    _typeIsThinking = false;
    _typeCharsPerMs = 0.0;
    _typeRateWinMs = 0;
    _typeRateWinLen = 0;
    _typeStepCarry = 0.0;
  }

  // 思考→正文：补全思考气泡，再开一个空正文气泡，打字机从 0 指向正文。
  // 只改 _messages，由调用方的 setState 刷新。
  void _startContentBubbleAfterThinking(String content) {
    _typeTimer?.cancel();
    _typeTimer = null;
    if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
      _messages.last = ChatMessage(role: 'assistant', content: _typeFull); // 思考补全
    }
    _messages.add(ChatMessage(role: 'assistant', content: ''));
    _typeIsThinking = false;
    _typeOwnerSid = _chatService.sessionId;
    _typeFull = content;
    _typeShown = 0;
    _typeRateWinMs = 0; // 新正文段：测速窗口重置 → 思考耗时不计入正文速率
    _typeStepCarry = 0.0;
    _ensureTypeTimer();
  }

  void dispose() {
    _typeTimer?.cancel();
    _longPressTimer?.cancel();
    _streamSub?.cancel();
    _appResumeFollowUpTimer?.cancel();
    _messagePersistTimer?.cancel();
    _sessionReconcileTimer?.cancel();
    unawaited(_flushActiveMessages());
    // Plan A 关键：app 关掉 worker 继续在 backend 跑，下次启动 _maybeResumeUnfinishedSession 接回来
    // 所以 dispose 只关本地 SSE，绝不通知 backend abort
    _chatService.abortLocal();
    _animController.dispose();
    _pulseController.dispose();
    _countdownController.dispose();
    _intentionalNativeStop = true;
    _speech?.stop();
    _scrollController.dispose();
    AsrModePrefs.notifier.removeListener(_onAsrModeChanged);
    AiChatService.agentRoutingRevision.removeListener(_onAgentScopeChanged);
    AuthService.authNotifier.removeListener(_onAuthChanged);
    appLifecycleEvent.removeListener(_onAppLifecycleChanged);
    super.dispose();
  }

  String _messageBucketKey(String sid) => '$_messageBucketKeyPrefix$sid';

  bool _isCommittedSession(String sid) {
    return _chatService.listSessions().any((s) => s.id == sid && s.committed);
  }

  Future<void> _loadMessagesForSession(String sid) async {
    if (sid.isEmpty || _loadedMessageBucketIds.contains(sid)) return;
    _loadedMessageBucketIds.add(sid);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_messageBucketKey(sid));
    if (raw == null || raw.isEmpty) {
      _messageBuckets.putIfAbsent(sid, () => []);
      return;
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      var migrated = false;
      _messageBuckets[sid] = decoded.whereType<Map>().map((m) {
        final message = ChatMessage.fromJson(
          m.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (message.role != 'assistant') return message;
        final cleaned = AiChatService.cleanAssistantDisplayText(
          message.content,
        );
        if (cleaned == message.content) return message;
        migrated = true;
        return ChatMessage(
          role: message.role,
          content: cleaned,
          jsonApp: message.jsonApp,
          action: message.action,
          failedJsonUrl: message.failedJsonUrl,
          jsonUrl: message.jsonUrl,
        );
      }).toList();
      if (migrated) {
        unawaited(_persistMessagesForSession(sid, _messageBuckets[sid]!));
      }
      debugPrint(
        '[DesignerBall] loaded ${_messageBuckets[sid]!.length} persisted AI messages for sid=$sid',
      );
    } catch (e) {
      debugPrint('[DesignerBall] load AI messages failed sid=$sid: $e');
      _messageBuckets.putIfAbsent(sid, () => []);
    }
  }

  void _schedulePersistActiveMessages() {
    final sid = _chatService.sessionId;
    // 放宽落盘门禁：committed 或「桶非空」即可存。否则"发出后立刻切走"窗口里、尚未
    // committed 的新会话桶一个字节都落不了盘，切回就全空（BUG2）。
    if (sid.isEmpty || (!_isCommittedSession(sid) && _messages.isEmpty)) return;
    final snapshot = List<ChatMessage>.from(_messages);
    _messagePersistTimer?.cancel();
    _messagePersistTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_persistMessagesForSession(sid, snapshot));
    });
  }

  Future<void> _flushActiveMessages() async {
    _messagePersistTimer?.cancel();
    _messagePersistTimer = null;
    final sid = _chatService.sessionId;
    if (sid.isEmpty || (!_isCommittedSession(sid) && _messages.isEmpty)) return;
    await _persistMessagesForSession(sid, List<ChatMessage>.from(_messages));
  }

  Future<void> _persistMessagesForSession(
    String sid,
    List<ChatMessage> messages,
  ) async {
    if (sid.isEmpty || (!_isCommittedSession(sid) && messages.isEmpty)) return;
    final prefs = await SharedPreferences.getInstance();
    if (messages.isEmpty) {
      await prefs.remove(_messageBucketKey(sid));
      return;
    }
    var start = messages.length > _maxPersistedMessagesPerSession
        ? messages.length - _maxPersistedMessagesPerSession
        : 0;
    var includeJsonApp = true;
    String encode() => jsonEncode(
      messages
          .skip(start)
          .map((m) => m.toJson(includeJsonApp: includeJsonApp))
          .toList(),
    );

    var encoded = encode();
    if (encoded.length > _maxPersistedMessageBytes) {
      includeJsonApp = false;
      encoded = encode();
    }
    while (encoded.length > _maxPersistedMessageBytes &&
        start < messages.length - 1) {
      start++;
      encoded = encode();
    }
    await prefs.setString(_messageBucketKey(sid), encoded);
  }

  Future<void> _deletePersistedMessagesForSession(String sid) async {
    if (sid.isEmpty) return;
    _loadedMessageBucketIds.remove(sid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_messageBucketKey(sid));
  }

  /// 登录态变化：从未登录 → 已登录时，重新检查是否有未完成会话需要恢复。
  /// 这弥补了 DesignerBall 不会随 AuthGate 切换而重建的问题（它在 MaterialApp.builder 里）。
  void _onAuthChanged() {
    if (!mounted) return;
    if (AuthService.authNotifier.value) {
      // 重新登录后重新加载本地 session 信息（_lastUserMessage 等可能在断网期间陈旧）
      // 然后异步触发恢复
      _chatService.loadSession().then((_) async {
        await _refreshAiRoutingOptions();
        await _loadMessagesForSession(_chatService.sessionId);
        if (mounted) {
          setState(() {});
          _maybeResumeUnfinishedSession();
        }
      });
    }
  }

  void _onAppLifecycleChanged() {
    if (!mounted) return;
    final event = appLifecycleEvent.value;
    if (event == 'inactive' ||
        event == 'pause' ||
        event == 'hidden' ||
        event == 'detached') {
      _detachAiStreamForAppBackground(event);
      return;
    }
    if (event == 'resume') {
      unawaited(_probeAiSessionAfterAppResume());
    }
  }

  Future<void> _refreshAiRoutingOptions() async {
    await Future.wait([
      AiChatService.fetchProviders(agentScope: _chatService.activeAgentScope),
      AiChatService.fetchAgents(),
    ]);
    if (mounted) setState(() {});
  }

  void _detachAiStreamForAppBackground(String lifecycleEvent) {
    _detachAiStreamForLifecycle(reason: 'app-$lifecycleEvent', resetUi: true);
  }

  void _detachAiStreamForLifecycle({
    required String reason,
    required bool resetUi,
  }) {
    final sub = _streamSub;
    _streamEpoch++;
    _flushTypewriter(); // 切后台前补全已收到全文，commitPartial 才能存到完整内容
    _resetTypewriter();
    if (sub != null) {
      debugPrint('[DesignerBall] $reason: detach local AI stream');
      if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        _chatService.commitPartial(_messages.last.content);
      }
      _streamSub = null;
      unawaited(sub.cancel());
    }
    _chatService.abortLocal();
    if (resetUi && mounted) {
      setState(() {
        _isThinking = false;
        _isGeneratingJson = false;
        _generatingStatusMessage = T.current.chatStatusGenerating;
      });
    }
    unawaited(_flushActiveMessages());
  }

  Future<void> _probeAiSessionAfterAppResume() async {
    if (_appResumeProbeInFlight) return;
    _appResumeProbeInFlight = true;
    try {
      // 让 Auth / 网络栈先完成前台恢复，避免刚 resume 就探测被系统瞬断误伤。
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted || !AuthService.authNotifier.value) return;

      // 移动端后台恢复时，旧 SSE/http client 可能已经半断但 Dart 订阅对象仍存在。
      // 先强制丢弃本地连接，再通过 /status + /result 或 /stream 恢复。
      _detachAiStreamForLifecycle(reason: 'app-resume-probe', resetUi: false);
      await _chatService.loadSession();
      await _refreshAiRoutingOptions();
      await _loadMessagesForSession(_chatService.sessionId);
      if (!mounted) return;
      setState(() {});

      debugPrint('[DesignerBall] app resumed: probe AI session');
      await _maybeResumeUnfinishedSession(forceDetachLocalStream: true);
      if (mounted) {
        unawaited(_flushActiveMessages());
        _scheduleAppResumeFollowUpReconcile();
      }
    } catch (e) {
      debugPrint('[DesignerBall] app resume probe failed (ignored): $e');
    } finally {
      _appResumeProbeInFlight = false;
    }
  }

  void _scheduleAppResumeFollowUpReconcile() {
    _appResumeFollowUpTimer?.cancel();
    _appResumeFollowUpTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      unawaited(_reconcileActiveSession(reason: 'resume-follow-up'));
    });
  }

  void _startSessionReconcileTimer({bool immediate = false}) {
    _sessionReconcileTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_reconcileActiveSession(reason: 'timer'));
    });
    if (immediate) {
      unawaited(_reconcileActiveSession(reason: 'immediate'));
    }
  }

  void _stopSessionReconcileTimer() {
    _sessionReconcileTimer?.cancel();
    _sessionReconcileTimer = null;
  }

  /// Low-frequency safety net for long generations after local SSE was detached
  /// or the final [DONE] action event was missed. This only runs while the chat
  /// overlay is visible and there is no active local stream, so normal streaming
  /// does not add backend load.
  Future<void> _reconcileActiveSession({required String reason}) async {
    if (!mounted ||
        !_chatMode ||
        _streamSub != null ||
        _sessionReconcileInFlight ||
        !AuthService.authNotifier.value) {
      return;
    }
    final sid = _chatService.sessionId;
    if (sid.isEmpty) return;

    _sessionReconcileInFlight = true;
    try {
      final statusData = await _chatService.probeActiveSessionStatus();
      // await 期间用户可能切换/新建会话；sid 已不是当初对账的那条就直接放弃，
      // 否则后面的 resume/flush 会落到错误的会话桶。
      if (!mounted ||
          !_chatMode ||
          _streamSub != null ||
          _chatService.sessionId != sid) {
        return;
      }
      if (statusData == null) return;

      final status = statusData['status'] as String? ?? '';
      debugPrint('[DesignerBall] reconcile($reason) status=$status sid=$sid');
      if (status == 'queued' || status == 'running' || status == 'done') {
        await _resumeActiveSessionIfNeeded();
        if (mounted) {
          unawaited(_flushActiveMessages());
        }
      }
      if (status == 'done' || status == 'failed' || status == 'aborted') {
        _stopSessionReconcileTimer();
      }
    } catch (e) {
      debugPrint('[DesignerBall] reconcile($reason) failed (ignored): $e');
    } finally {
      _sessionReconcileInFlight = false;
    }
  }

  void _initPosition(Size screenSize) {
    // 安全检查：只有在屏幕尺寸有效时才初始化位置
    if (!_positioned && screenSize.width > 0 && screenSize.height > 0) {
      _left = screenSize.width - _ballSize - 16;
      _top = screenSize.height * 0.65;
      _positioned = true;
      debugPrint(
        '[DesignerBall] Position initialized: left=$_left, top=$_top, screenSize=$screenSize',
      );
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
        _left = _left.clamp(
          -_ballSize * 0.5,
          screenSize.width - _ballSize * 0.5,
        );
        _top = _top.clamp(
          -_ballSize * 0.5,
          screenSize.height - _ballSize * 0.5,
        );

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
      final targetLeft = edge == _HideEdge.left
          ? 0.0
          : screenSize.width - _ballSize;
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
  ///
  /// 第二次双击（菜单还开着）→ 关掉菜单，而不是叠一层。点击灰幕也能关。
  ///
  /// 不再因为 _chatMode/_isListening 屏蔽：之前 `if (_chatMode) return` 把
  /// 聊天态下双击全 swallow 掉，用户必须先关掉聊天才能用快捷菜单——很反直觉。
  /// 现在任意状态都能弹菜单（"回到主页"在聊天里也得能用）。
  void _onDoubleTap() {
    if (_quickMenuOpen) {
      // 菜单已打开 → 双击 = 关
      JsonDslApp.navigatorKey.currentState?.pop();
      return;
    }
    _showQuickMenu();
  }

  /// 真正恢复会话的逻辑（之前 _onDoubleTap 直接干的事）。
  /// 从快捷菜单的"恢复会话"按钮调过来。
  Future<void> _restoreSession() async {
    if (!AuthService.isLoggedIn) {
      _showLoginRequired();
      return;
    }
    if (_chatMode || _messages.isEmpty) return;
    setState(() => _chatMode = true);
    _startSessionReconcileTimer(immediate: true);
    _scrollToBottom();
    await _resumeActiveSessionIfNeeded();
  }

  /// 一路 pop 回根路由（FilePickerPage / MyApp 主页）。
  /// 用途：用户用了"默认启动 App"被锁进某个 JSON-APP，里面没有"切换 App"
  /// 的功能时，靠悬浮球这个按钮逃出来。
  void _goHome() {
    final nav = JsonDslApp.navigatorKey.currentState;
    if (nav == null) return;
    nav.popUntil((route) => route.isFirst);
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

    _quickMenuOpen = true;
    try {
      await showDialog<void>(
        context: navContext,
        barrierColor: Colors.black38,
        barrierDismissible: true,
        builder: (ctx) {
          final cs = Theme.of(ctx).colorScheme;
          // 用 surfaceContainerHigh：M3 专门设计的"需要从背景里凸出"的容器色。
          // 浅色模式下比 surface 略深、深色模式下比 surface 略浅，跟系统主题
          // 自动产生对比，不会跟页面底色融成一片。
          return Dialog(
            backgroundColor: cs.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
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
                          unawaited(_restoreSession());
                        },
                      ),
                      _QuickMenuButton(
                        icon: Icons.home_rounded,
                        label: s.ballMenuGoHome,
                        // 只要根 Navigator 还能 pop 就启用 —— 表示当前栈里有
                        // push 进来的 JSON-APP / 设置页等，可以一路 pop 回首页
                        enabled:
                            JsonDslApp.navigatorKey.currentState?.canPop() ==
                            true,
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _goHome();
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
    } finally {
      _quickMenuOpen = false;
    }
  }

  // ════════════════════════════════════════════════════════
  // 对话模式
  // ════════════════════════════════════════════════════════

  // 未登录时按住悬浮球：给两个选项 —— 请登录 / Demo 体验模式。
  void _showLoginRequired() {
    final navContext = JsonDslApp.navigatorKey.currentContext ?? context;
    showModalBottomSheet<void>(
      context: navContext,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  '用 AI 创建应用',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: Icon(Icons.login_rounded, color: cs.primary),
                title: Text(T.current.chatErrPleaseLogin), // 请登录
                subtitle: const Text('用真实账号创建并保存你的应用'),
                onTap: () => Navigator.of(ctx).pop(),
                // 未登录时 AuthGate 已经把登录页显示在底层，pop 即可看到登录表单
              ),
              ListTile(
                leading: Icon(Icons.play_circle_outline, color: cs.primary),
                title: const Text('Demo 体验模式'),
                subtitle: const Text('免登录，点一下示例需求即可生成可运行的 App'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(_enterDemoAndPrompt());
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // Demo：登录预置假账号 → 进入对话模式 → 弹示例需求列表。
  Future<void> _enterDemoAndPrompt() async {
    final navContext = JsonDslApp.navigatorKey.currentContext ?? context;
    try {
      await AuthService.enterDemoMode();
    } catch (e) {
      ScaffoldMessenger.maybeOf(navContext)?.showSnackBar(
        SnackBar(content: Text('Demo 模式暂不可用：$e')),
      );
      return;
    }
    await _enterChatMode(); // 此时已登录，门禁通过
    _showDemoPromptList();
  }

  // Demo 示例需求：每条对应一个特殊 UUID，服务端识别后走预录回放。
  // UUID 必须与后端 demo_replay.DEMO_SESSIONS 一致。
  static const List<Map<String, String>> _demoPrompts = [
    {
      'uuid': '00000000-0000-0000-0000-000000000001',
      'title': '论坛 / 贴吧类 App（全栈）',
      'prompt':
          '创建一个论坛类型的 App：要有用户个人页面（显示真实头像）、可以创建讨论区（类似贴吧的「吧」）、可以发帖、评论、点赞。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000002',
      'title': '番茄钟（纯前端）',
      'prompt': '做一个番茄钟：25 分钟倒计时，开始 / 暂停 / 重置，结束提醒。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000003',
      'title': '计算器',
      'prompt': '做一个计算器，支持加减乘除、百分比和清除。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000004',
      'title': '多页面 App 示例',
      'prompt': '做一个有 5 个页面、底部导航切换的多页面 App。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000005',
      'title': '媒体播放',
      'prompt': '做一个媒体展示 App，能播放视频、展示图片。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000006',
      'title': '视频浏览',
      'prompt': '做一个视频浏览 App：列表 + 点进去播放。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000007',
      'title': '拍照巡检',
      'prompt': '做一个拍照巡检 App：拍照记录设备状态，生成巡检单。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000008',
      'title': '课程播放器',
      'prompt': '做一个在线课程播放器：章节列表 + 视频播放 + 学习进度。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000009',
      'title': '运维数据看板',
      'prompt': '做一个运维数据仪表盘：服务状态、指标图表、告警列表。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000010',
      'title': '智能家居',
      'prompt': '做一个智能家居控制面板：灯光、空调、场景一键控制。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000011',
      'title': '旅行通行证',
      'prompt': '做一个旅行通行证 App：行程卡片、二维码、登机信息。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000012',
      'title': '像素三消游戏',
      'prompt': '做一个像素风格的三消小游戏。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000013',
      'title': '记账预算',
      'prompt': '做一个记账 App：收支记录、分类统计、月度预算。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000014',
      'title': '客户管理 CRM',
      'prompt': '做一个轻量 CRM：客户列表、跟进记录、状态标签。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000015',
      'title': '习惯打卡',
      'prompt': '做一个习惯打卡 App：每日打卡、连续天数、热力图。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000016',
      'title': '笔记',
      'prompt': '做一个笔记 App：新建、编辑、列表、搜索。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000017',
      'title': '健身训练',
      'prompt': '做一个健身训练 App：训练计划、动作计时、记录。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000018',
      'title': '超级 App 首页',
      'prompt': '做一个超级 App 首页：多功能入口聚合、轮播、九宫格。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000019',
      'title': '文本收集器',
      'prompt': '做一个文本收集器：快速记录、列表管理、复制。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000020',
      'title': '2048 数字游戏',
      'prompt': '做一个 2048 数字合并游戏。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000021',
      'title': '贪吃蛇',
      'prompt': '做一个贪吃蛇小游戏：吃食物变长、撞墙结束。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000022',
      'title': 'Flappy Bird',
      'prompt': '做一个 Flappy Bird 点击飞行小游戏。',
    },
    {
      'uuid': '00000000-0000-0000-0000-000000000023',
      'title': '广场社区 · 全栈论坛（板块 / 楼中楼 / 好友私信）',
      'prompt':
          '做一个类似贴吧的全栈论坛 App：板块分区、发主题帖、楼中楼盖楼回帖、用户昵称主页、加好友、好友间私信，要有真实后端能保存数据。',
    },
  ];

  void _showDemoPromptList() {
    final navContext = JsonDslApp.navigatorKey.currentContext ?? context;
    showModalBottomSheet<void>(
      context: navContext,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      '选择一个示例需求（Demo）',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final p in _demoPrompts)
                        ListTile(
                          leading: Icon(Icons.auto_awesome, color: cs.primary),
                          title: Text(p['title']!),
                          subtitle: Text(
                            p['prompt']!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            unawaited(_fireDemoTask(p['uuid']!, p['prompt']!));
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  // 触发一个 demo 任务：把 active session 的 id 固定成特殊 UUID 再正常发送，
  // 服务端据此走回放（不路由 agent-node、不建 FaaS）。
  Future<void> _fireDemoTask(String uuid, String promptText) async {
    await _chatService.createDemoSession(uuid);
    _sendTextToAi(promptText);
  }

  Future<void> _enterChatMode() async {
    debugPrint('[DesignerBall] _enterChatMode called');
    if (!AuthService.isLoggedIn) {
      _showLoginRequired();
      return;
    }

    // 进入对话模式的重震动反馈：双击 heavyImpact，间隔 ~70ms。
    // Flutter SDK 的 heavyImpact 已是单次最强，要更明显只能连击。
    // ignore: unawaited_futures
    _strongHapticBurst();

    // 后台拉取供应商列表（不阻塞进入对话模式）
    AiChatService.fetchProviders().then((_) {
      if (mounted) setState(() {});
    });

    debugPrint(
      '[DesignerBall] 初始状态: asrMode=$_asrMode, speechInited=$_speechInited',
    );

    // 检查原生语音识别是否已初始化（已在 initState 中完成）
    if (!_speechInited && _asrMode == AsrMode.online) {
      setState(() {
        _messages.add(
          ChatMessage(
            role: 'assistant',
            content: T.current.asrErrNativeInitWithHint,
          ),
        );
      });
      return;
    }

    debugPrint('[DesignerBall] 最终决策: ASR模式=${_asrMode.name}');

    // 如果是豆包ASR，检查连接状态
    if (_asrMode == AsrMode.bytedance) {
      if (!_bytedanceAsr.isConnected) {
        debugPrint('[DesignerBall] 豆包ASR未连接，等待连接...');
        setState(() {
          _chatMode = true;
          _isThinking = true;
          _liveTranscript = T.current.asrConnectingBytedance;
        });

        // 等待最多3秒让豆包ASR连接
        int waitCount = 0;
        while (!_bytedanceAsr.isConnected && waitCount < 30) {
          await Future.delayed(const Duration(milliseconds: 100));
          waitCount++;

          // 用户手已离开，中止等待
          if (!_pointerDown) {
            debugPrint(
              '[DesignerBall] Pointer lifted during ByteDance ASR wait, aborting',
            );
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
          debugPrint(
            '[DesignerBall] 豆包ASR连接超时，isConnected=${_bytedanceAsr.isConnected}',
          );
          setState(() {
            _messages.add(
              ChatMessage(
                role: 'assistant',
                content: T.current.asrErrBytedanceTimeoutWithHint,
              ),
            );
          });
          return;
        }

        debugPrint('[DesignerBall] 豆包ASR连接成功');
      }
    }

    debugPrint('[DesignerBall] 准备进入录音模式，_pointerDown=$_pointerDown');

    // 最终检查：手已离开 → 只设置 chatMode 但不开始录音
    setState(() => _chatMode = true);
    unawaited(_refreshAiRoutingOptions());
    _startSessionReconcileTimer(immediate: true);
    if (!_pointerDown) {
      debugPrint(
        '[DesignerBall] Pointer lifted before startListening, skipping',
      );
      return;
    }

    debugPrint('[DesignerBall] 调用 _startListening');
    _startListening();
  }

  void _startListening() {
    // Demo 模式不做语音识别，改弹示例需求列表（点一条即假装触发 AI 任务）。
    if (AuthService.isDemoMode) {
      _showDemoPromptList();
      return;
    }
    _recordStartPos = Offset(_left, _top);
    _dragCancelling = false;
    _accumulatedTranscript = ''; // 清空累积文本
    setState(() {
      _isListening = true;
      _liveTranscript = '';
    });
    _pulseController.repeat(reverse: true);

    debugPrint('[DesignerBall] ASR决策: asrMode=${_asrMode.name}');

    switch (_asrMode) {
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
      case AsrMode.bytedance:
        _bytedanceAsr.stopListening();
        break;
      default:
        _intentionalNativeStop = true;
        try {
          _speech?.stop();
        } catch (_) {}
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
    _bytedanceAsr.stopListening();
    // 注意：_bytedanceAsr.onResult 不在此处清空（在 _initBytedanceAsr 中一次性注册），
    // 改在回调内用 _editMode 守卫拦截。
    _intentionalNativeStop = true;
    try {
      _speech?.stop();
    } catch (_) {}

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

    _attachAiStream(
      _chatService.sendStream(text, contextMessages: _aiConversationPayload()),
    );
  }

  List<Map<String, String>> _aiConversationPayload() {
    final items = <Map<String, String>>[];
    for (final message in _messages) {
      if (message.role != 'user' && message.role != 'assistant') continue;
      if (message.action != null ||
          message.failedJsonUrl != null ||
          message.jsonUrl != null) {
        continue;
      }
      final content = message.content.trim();
      if (content.isEmpty) continue;
      items.add({'role': message.role, 'content': content});
    }
    return items;
  }

  /// 把一个 AI 事件流接到 UI。三处用：
  /// (1) _sendTextToAi 正常发消息
  /// (2) 启动恢复 (_maybeResumeUnfinishedSession 拿到的 ResumeStreaming)
  /// (3) 重试按钮 (_handleRetryLastTurn)
  ///
  /// 调用方负责在调本方法之前把 user 气泡 / 空 assistant 气泡先注入好。
  void _attachAiStream(Stream<ChatEvent> stream) {
    _startSessionReconcileTimer();
    final streamEpoch = ++_streamEpoch;
    // 绑定这条流归属的会话。active 一旦在流存活期内被切走——用户新建/切换会话，或
    // _onAuthChanged → loadSession 改了 _activeSessionId 却没 ++epoch——这条流的迟到
    // 事件必须丢弃，绝不能写进当前 active 桶（BUG1 串桶根因：epoch 守卫挡不住"active
    // 变了但 epoch 没变"）。
    final streamSid = _chatService.sessionId;
    bool isCurrentStream() {
      if (!mounted || streamEpoch != _streamEpoch) return false;
      if (_chatService.sessionId != streamSid) {
        debugPrint(
          '[DesignerBall] stream-sid-mismatch drop streamSid=$streamSid '
          'active=${_chatService.sessionId}',
        );
        return false;
      }
      return true;
    }
    // 用于累积流式事件中的指令，[DONE] 时统一处理
    Map<String, dynamic>? pendingJsonApp;
    String? pendingRequestAction;
    String? pendingFailedJsonUrl;
    String? pendingFailedJsonError;
    String? pendingJsonUrl;
    final pendingSystemMessages = <String>[];

    _streamSub = stream.listen(
      (event) {
        if (!isCurrentStream()) return;
        if (event.isGeneratingJson) {
          setState(() {
            _isGeneratingJson = true;
            _generatingStatusMessage = T.current.chatStatusStartingAi;
          });
          _scrollToBottom();
          return;
        }
        if (event.statusMessage != null) {
          final translated = _translateStatusKey(event.statusMessage!);
          // 去重：与当前状态完全一致（反复的 ai_engine_started / 多次重连提示等）就不再
          // setState 重建，省资源、避免无意义刷新。
          if (_isGeneratingJson && translated == _generatingStatusMessage) {
            return;
          }
          setState(() {
            // 有工具动作时直接在浮层里显示，避免看起来像卡住
            _isGeneratingJson = true;
            _generatingStatusMessage = translated;
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
            _flushTypewriter(); // 补全已流出的 partial，再挂中断/重试
            _typeIsThinking = false;
            _isThinking = false;
            _isGeneratingJson = false;
            _generatingStatusMessage = T.current.chatStatusGenerating;
            // 如果同时有 error 且最后一个 assistant 气泡是空的，先把 error 写进去
            // 这样用户既能看到"为啥失败了"也能看到下面的重试按钮
            if (event.error != null &&
                _messages.isNotEmpty &&
                _messages.last.role == 'assistant' &&
                _messages.last.content.isEmpty) {
              _messages.last = ChatMessage(
                role: 'assistant',
                content: event.error!,
              );
            } else if (event.error == null &&
                _messages.isNotEmpty &&
                _messages.last.role == 'assistant' &&
                _messages.last.content.isEmpty) {
              // 没 error 但有空气泡（idle timeout / 探活检测出来的纯断连）→ 删掉
              _messages.removeLast();
            }
            // 已有 partial 内容时不动它，让用户看到 AI 已经流过的部分
            _messages.add(
              ChatMessage(
                role: 'system',
                content: 'AI 任务被中断，点击重试',
                action: 'RETRY_LAST_TURN',
              ),
            );
          });
          _stopSessionReconcileTimer();
          _scrollToBottom();
          return;
        }
        if (event.error != null && event.content == null) {
          _resetTypewriter(); // 停掉打字机，避免下一帧覆盖错误文案
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            _generatingStatusMessage = T.current.chatStatusGenerating;
            if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
              _messages.last = ChatMessage(
                role: 'assistant',
                content: event.error!,
              );
            } else {
              _messages.add(
                ChatMessage(role: 'assistant', content: event.error!),
              );
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
        if (event.systemMessage != null && event.systemMessage!.isNotEmpty) {
          pendingSystemMessages.add(event.systemMessage!);
          return;
        }

        if (event.thinking != null) {
          // 思考过程 → 经打字机平滑吐字（仍只更新空气泡或思考气泡）。
          // ⚠️ 不要在这里关 _isGeneratingJson：后端在 thinking 块开始时会主动发
          // status="thinking" 让转圈亮起来；这里关掉会被第一帧立刻熄掉，体感"无反应"。
          final eligible = _messages.isNotEmpty &&
              _messages.last.role == 'assistant' &&
              (_typeIsThinking || _messages.last.content.isEmpty);
          if (eligible) {
            setState(() => _isThinking = false);
            _typeIsThinking = true;
            _setTypewriterTarget('💭 ${event.thinking!}');
          }
          return;
        }
        if (event.content != null) {
          final wasThinking = _typeIsThinking;
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            if (wasThinking) {
              // 思考→正文：补全思考气泡 + 开新正文气泡 + 打字机指向正文
              _startContentBubbleAfterThinking(event.content!);
            }
          });
          if (!wasThinking &&
              _messages.isNotEmpty &&
              _messages.last.role == 'assistant') {
            _setTypewriterTarget(event.content!);
          }
          _scrollToBottom();
        }
        if (event.quota != null) {
          _lastQuota = event.quota;
        }
      },
      onError: (e) {
        if (!isCurrentStream()) return;
        _streamSub = null;
        _resetTypewriter(); // 停掉打字机，避免下一帧覆盖错误文案
        setState(() {
          _isThinking = false;
          _isGeneratingJson = false;
          _generatingStatusMessage = T.current.chatStatusGenerating;
          if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
            _messages.last = ChatMessage(
              role: 'assistant',
              content: T.fmt(T.current.chatErrorWith, {'err': e}),
            );
          } else {
            _messages.add(
              ChatMessage(
                role: 'assistant',
                content: T.fmt(T.current.chatErrorWith, {'err': e}),
              ),
            );
          }
        });
        _startSessionReconcileTimer(immediate: true);
      },
      onDone: () {
        if (!isCurrentStream()) return;
        _streamSub = null;
        debugPrint(
          '[DesignerBall] AI stream onDone: '
          'pendingRequestAction=$pendingRequestAction, '
          'pendingJsonUrl=${pendingJsonUrl != null ? "<${pendingJsonUrl!.length} chars>" : "null"}, '
          'pendingFailedJsonUrl=$pendingFailedJsonUrl, '
          'pendingJsonApp=${pendingJsonApp != null}',
        );
        setState(() {
          _flushTypewriter(); // 补全正文，停掉打字机
          _typeIsThinking = false;
          _isGeneratingJson = false;
          _generatingStatusMessage = T.current.chatStatusGenerating;

          _appendFinalActionMessages(
            requestAction: pendingRequestAction,
            jsonUrl: pendingJsonUrl,
            failedJsonUrl: pendingFailedJsonUrl,
            failedJsonError: pendingFailedJsonError,
            jsonApp: pendingJsonApp,
            systemMessages: pendingSystemMessages,
          );
        });
        final hasFinalAction =
            pendingRequestAction != null ||
            pendingJsonUrl != null ||
            pendingFailedJsonUrl != null ||
            pendingJsonApp != null ||
            pendingSystemMessages.isNotEmpty;
        if (hasFinalAction) {
          _stopSessionReconcileTimer();
        } else {
          _startSessionReconcileTimer();
          unawaited(_reconcileActiveSession(reason: 'stream-done-no-action'));
        }
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
    _attachAiStream(
      _chatService.retryLastTurn(contextMessages: _aiConversationPayload()),
    );
  }

  /// app 启动/重新打开字幕时：检查后端有没有上一轮未完成 / 已完成的任务，
  /// 并合并到当前消息桶，避免关闭字幕后恢复时重复插入 user/assistant 气泡。
  Future<void> _maybeResumeUnfinishedSession({
    bool forceDetachLocalStream = false,
  }) => _resumeActiveSessionIfNeeded(
    forceDetachLocalStream: forceDetachLocalStream,
  );

  Future<void> _resumeActiveSessionIfNeeded({
    bool forceDetachLocalStream = false,
  }) async {
    if (!mounted) return;
    if (_resumeInFlight) return;
    // 捕获「要恢复的会话」。下面 tryResumeUnfinished 有网络 await，期间用户可能
    // 切换/新建会话；恢复结果只能应用回这同一条会话，否则会串进别的会话桶。
    final resumingSid = _chatService.sessionId;
    if (_streamSub != null) {
      if (!forceDetachLocalStream) return;
      _detachAiStreamForLifecycle(
        reason: 'resume-stale-stream',
        resetUi: false,
      );
    }
    _resumeInFlight = true;
    try {
      final result = await _chatService.tryResumeUnfinished(
        forceDetachLocalClient: forceDetachLocalStream,
      );
      // ⚠️ await 回来后 active 若已变（用户新开/切换了会话），丢弃结果——
      // 这些 _ensureUserMessage/_upsertAssistantMessage 都走「活的」_messages
      // getter，会写进当前会话桶，应用旧会话结果就是「消息跑到别的会话」的根因。
      if (!mounted || _chatService.sessionId != resumingSid) return;
      switch (result) {
        case ResumeNothing():
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            _generatingStatusMessage = T.current.chatStatusGenerating;
          });
          break;
        case ResumeCompleted(
          :final userMessage,
          :final assistantText,
          :final jsonUrl,
          :final requestAction,
          :final systemMessages,
        ):
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            _generatingStatusMessage = T.current.chatStatusGenerating;
            _ensureUserMessage(userMessage);
            _upsertAssistantMessage(assistantText);
            _appendFinalActionMessages(
              requestAction: requestAction,
              jsonUrl: jsonUrl,
              systemMessages: systemMessages,
            );
          });
          _scrollToBottom();
          _stopSessionReconcileTimer();
        case ResumeStreaming(:final userMessage, :final stream):
          setState(() {
            _ensureUserMessage(userMessage);
            _ensureAssistantPlaceholder();
            _isThinking = true;
            _isGeneratingJson = true;
            _generatingStatusMessage = T.current.chatStatusResumingLast;
          });
          _scrollToBottom();
          _attachAiStream(stream);
        case ResumeNeedsRetry(:final userMessage):
          setState(() {
            _isThinking = false;
            _isGeneratingJson = false;
            _generatingStatusMessage = T.current.chatStatusGenerating;
            _ensureUserMessage(userMessage);
            if (!_hasSystemMessage(action: 'RETRY_LAST_TURN')) {
              _messages.add(
                ChatMessage(
                  role: 'system',
                  content: 'AI 任务被中断（可能服务器进程异常），点击重试',
                  action: 'RETRY_LAST_TURN',
                ),
              );
            }
          });
          _scrollToBottom();
          _stopSessionReconcileTimer();
      }
    } catch (e) {
      debugPrint('[DesignerBall] resume 失败 (静默): $e');
    } finally {
      _resumeInFlight = false;
    }
  }

  void _ensureUserMessage(String content) {
    if (content.isEmpty) return;
    if (_messages.isNotEmpty &&
        _messages.last.role == 'user' &&
        _messages.last.content == content) {
      return;
    }
    for (var i = _messages.length - 1; i >= 0; i--) {
      final message = _messages[i];
      if (message.role != 'user') continue;
      if (message.content == content) return;
      break;
    }
    _messages.add(ChatMessage(role: 'user', content: content));
  }

  void _ensureAssistantPlaceholder() {
    if (_messages.isNotEmpty && _messages.last.role == 'assistant') return;
    _messages.add(ChatMessage(role: 'assistant', content: ''));
  }

  void _upsertAssistantMessage(String content) {
    final displayContent = AiChatService.cleanAssistantDisplayText(content);
    if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
      // 别用更短的 final_text 覆盖本地已流式累积的更完整内容（"只剩用户+JSON"根因）
      if (_messages.last.content.length > displayContent.length) return;
      _messages.last = ChatMessage(role: 'assistant', content: displayContent);
      return;
    }
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') break;
      if (_messages[i].role == 'assistant') {
        if (_messages[i].content.length > displayContent.length) return;
        _messages[i] = ChatMessage(role: 'assistant', content: displayContent);
        return;
      }
    }
    _messages.add(ChatMessage(role: 'assistant', content: displayContent));
  }

  bool _hasSystemMessage({String? action, String? jsonUrl}) {
    return _messages.any((m) {
      if (m.role != 'system') return false;
      if (action != null && m.action == action) return true;
      if (jsonUrl != null && m.jsonUrl == jsonUrl) return true;
      return false;
    });
  }

  int _lastUserMessageIndex() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') return i;
    }
    return -1;
  }

  void _removeCurrentTurnSystemMessage({
    String? action,
    String? jsonUrl,
    String? failedJsonUrl,
    String? content,
  }) {
    final start = _lastUserMessageIndex() + 1;
    for (var i = _messages.length - 1; i >= start; i--) {
      final m = _messages[i];
      if (m.role != 'system') continue;
      if (action != null && m.action == action) {
        _messages.removeAt(i);
        continue;
      }
      if (jsonUrl != null && m.jsonUrl == jsonUrl) {
        _messages.removeAt(i);
        continue;
      }
      if (failedJsonUrl != null && m.failedJsonUrl == failedJsonUrl) {
        _messages.removeAt(i);
        continue;
      }
      if (content != null && m.content == content) {
        _messages.removeAt(i);
      }
    }
  }

  void _appendFinalActionMessages({
    String? requestAction,
    String? jsonUrl,
    String? failedJsonUrl,
    String? failedJsonError,
    Map<String, dynamic>? jsonApp,
    List<String> systemMessages = const [],
  }) {
    // 各按钮独立共存；重新恢复/重连同一轮时，先移除本轮旧位置的动作消息，
    // 再按固定顺序追加到最后，避免下载提示夹在 assistant 文本中间。
    if (requestAction == 'upload_current_app') {
      _removeCurrentTurnSystemMessage(action: 'UPLOAD_CURRENT_APP');
      _messages.add(
        ChatMessage(
          role: 'system',
          content: 'AI 需要获取当前应用的代码配置以进行修改：',
          action: 'UPLOAD_CURRENT_APP',
        ),
      );
    }
    if (jsonUrl != null) {
      _removeCurrentTurnSystemMessage(jsonUrl: jsonUrl);
      _messages.add(
        ChatMessage(
          role: 'system',
          content: 'JSON-APP 已生成，点击下载并运行：',
          jsonUrl: jsonUrl,
        ),
      );
    }
    if (failedJsonUrl != null) {
      _removeCurrentTurnSystemMessage(failedJsonUrl: failedJsonUrl);
      _messages.add(
        ChatMessage(
          role: 'system',
          content: failedJsonError ?? T.current.chatJsonDownloadFailed,
          failedJsonUrl: failedJsonUrl,
        ),
      );
    }
    if (jsonApp != null) {
      _messages.add(
        ChatMessage(role: 'system', content: '🚀 点击试运行', jsonApp: jsonApp),
      );
    }
    for (final message in systemMessages) {
      final content = message.trim();
      if (content.isEmpty) continue;
      _removeCurrentTurnSystemMessage(content: content);
      _messages.add(ChatMessage(role: 'system', content: content));
    }
  }

  Future<void> _handleUploadCurrentApp() async {
    final config = widget.getCurrentConfig?.call();
    if (config == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(T.current.chatNoActiveApp)));
      return;
    }

    setState(() {
      // 移除 UPLOAD 按钮那条消息
      _messages.removeLast();
      _messages.add(
        ChatMessage(role: 'system', content: T.current.chatUploadingApp),
      );
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
        _messages.add(
          ChatMessage(
            role: 'system',
            content: '❌ 上传失败：$e\n\n点击下方按钮可再次尝试。',
            action: 'UPLOAD_CURRENT_APP',
          ),
        );
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
        _messages.add(
          ChatMessage(
            role: 'system',
            content: '🚀 JSON-APP 已成功下载，点击试运行',
            jsonApp: parsedApp,
          ),
        );
      });
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _isGeneratingJson = false;
        _messages.add(
          ChatMessage(
            role: 'assistant',
            content: T.fmt(T.current.chatDownloadRetryFailedWith, {'err': e}),
            failedJsonUrl: url,
          ),
        );
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
        _closeChatMode();
      }
    });
  }

  /// 原生语音识别 (Apple/Google) — Android SpeechRecognizer / iOS SFSpeechRecognizer
  /// 单次会话有 ~10-60s 上限，靠 onStatus:done / onError 触发自动重启实现"无限录制"。
  ///
  /// 累加规则：每段 partial → 显示 `_accumulatedTranscript + 当前段`；finalResult
  /// 触发时，把这段并入 `_accumulatedTranscript`，下一段从 0 开始。
  void _startNativeSpeech() {
    if (_speech == null) return;
    _intentionalNativeStop = false;
    _doStartNativeSession();
  }

  void _doStartNativeSession() {
    if (_speech == null) return;
    try {
      _speech!.listen(
        onResult: (result) {
          // 编辑模式下，stop() 后迟到的 final 结果一律丢弃
          if (!_isListening || _editMode) return;
          final segment = result.recognizedWords;
          // 中文段间直接拼，不加空格（之前 '类似于 鸟' 的 bug）。
          // 英文场景这里也凑合，最终落到聊天框时不会有大问题。
          final combined = '$_accumulatedTranscript$segment';
          if (_liveTranscript != combined) {
            setState(() => _liveTranscript = combined);
          }
          // 这一段平台判定结束，立刻并入累积；下一段（自动 restart）从 0 开始
          if (result.finalResult && segment.isNotEmpty) {
            _accumulatedTranscript = combined;
          }
        },
        localeId: 'zh_CN',
        // listenFor / pauseFor 都给平台上限，让平台自然 endpointing。
        // 一旦它停了，我们在 onStatus:done 里立刻重启下一段。
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 10),
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
        _messages.add(
          ChatMessage(
            role: 'assistant',
            content: T.current.asrErrNativeStartWithHint,
          ),
        );
      });
      _pulseController.stop();
    }
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
          _messages.add(
            ChatMessage(
              role: 'assistant',
              content: T.current.asrErrBytedanceNotConnected,
            ),
          );
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
          _messages.add(
            ChatMessage(
              role: 'assistant',
              content: T.current.asrErrMicPermissionDenied,
            ),
          );
        });
        _pulseController.stop();
      }
    } catch (e) {
      debugPrint('[ByteDanceASR] Start error: $e');
      setState(() {
        _isListening = false;
        _messages.add(
          ChatMessage(
            role: 'assistant',
            content: T.fmt(T.current.asrErrBytedanceStartFailWith, {'err': e}),
          ),
        );
      });
      _pulseController.stop();
    }
  }

  Future<void> _stopListeningAndSend() async {
    debugPrint('[DesignerBall] _stopListeningAndSend');

    // 停止语音识别
    switch (_asrMode) {
      case AsrMode.bytedance:
        await _bytedanceAsr.stopListening();
        break;
      default:
        _intentionalNativeStop = true;
        try {
          await _speech?.stop();
        } catch (e) {
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
  ///
  /// 多会话：切换/新建/删除路径都会先调这里。**必须无条件重置所有 stream-related
  /// UI 状态**，否则会出现：在 session A "正在生成代码" 中途切到 session B（已 done），
  /// 但 _isGeneratingJson 没被清，B 的视图还在转圈。
  void _cancelCurrentStream() {
    _streamEpoch++;
    _flushTypewriter(); // 把已收到的全文补全到气泡，再复位（下面 commitPartial 才存到完整内容）
    _resetTypewriter();
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
      // 唯一例外是 _deleteCurrentSessionAndClose（用户点垃圾桶），那条路径走
      // _chatService.deleteSession() → 内部对该 sid 单独发 /abort，不依赖这里
      _chatService.abortLocal();
    }
    // 无条件重置，覆盖"没有活跃 stream 但 UI 状态没复位"的情况
    setState(() {
      _isThinking = false;
      _isGeneratingJson = false;
      _generatingStatusMessage = T.current.chatStatusGenerating;
    });
    unawaited(_flushActiveMessages());
  }

  /// 只隐藏字幕时使用：断开本地 SSE 节省资源，但保留当前 session 和消息占位。
  /// 后端 worker 继续跑；用户从快捷菜单恢复会话时会通过 /status + /stream 接回。
  void _detachCurrentStreamForHide() {
    _streamEpoch++;
    if (_streamSub != null) {
      if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
        _chatService.commitPartial(_messages.last.content);
      }
      _streamSub?.cancel();
      _streamSub = null;
      _chatService.abortLocal();
    }
    setState(() {
      _isThinking = false;
      _isGeneratingJson = false;
      _generatingStatusMessage = T.current.chatStatusGenerating;
    });
    unawaited(_flushActiveMessages());
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
    final streamEpoch = ++_streamEpoch;
    // 绑定这条流归属的会话。active 一旦在流存活期内被切走——用户新建/切换会话，或
    // _onAuthChanged → loadSession 改了 _activeSessionId 却没 ++epoch——这条流的迟到
    // 事件必须丢弃，绝不能写进当前 active 桶（BUG1 串桶根因：epoch 守卫挡不住"active
    // 变了但 epoch 没变"）。
    final streamSid = _chatService.sessionId;
    bool isCurrentStream() {
      if (!mounted || streamEpoch != _streamEpoch) return false;
      if (_chatService.sessionId != streamSid) {
        debugPrint(
          '[DesignerBall] stream-sid-mismatch drop streamSid=$streamSid '
          'active=${_chatService.sessionId}',
        );
        return false;
      }
      return true;
    }
    _streamSub = _chatService
        .sendStream(crashReport, contextMessages: _aiConversationPayload())
        .listen(
          (event) {
            if (!isCurrentStream()) return;
            if (event.error != null && event.content == null) {
              setState(() {
                _isThinking = false;
                _messages.last = ChatMessage(
                  role: 'assistant',
                  content: event.error!,
                );
              });
              _scrollToBottom();
              return;
            }
            if (event.content != null) {
              setState(() {
                _isThinking = false;
                _messages.last = ChatMessage(
                  role: 'assistant',
                  content: event.content!,
                );
              });
              _scrollToBottom();
            }
            if (event.jsonApp != null) {
              debugPrint('[DesignerBall] AI generated fix JSON-APP!');
              _lastGeneratedJson = event.jsonApp;
              setState(() {
                _messages.add(
                  ChatMessage(
                    role: 'system',
                    content: '🔧 修复版 JSON-APP 已生成，点击试运行',
                    jsonApp: event.jsonApp,
                  ),
                );
              });
              _scrollToBottom();
            }
          },
          onError: (e) {
            if (!isCurrentStream()) return;
            _streamSub = null;
            setState(() {
              _isThinking = false;
              _messages.last = ChatMessage(
                role: 'assistant',
                content: T.fmt(T.current.chatAnalysisFailedWith, {'err': e}),
              );
            });
          },
          onDone: () {
            if (!isCurrentStream()) return;
            _streamSub = null;
          },
        );
  }

  void _closeChatMode() {
    _intentionalNativeStop = true;
    try {
      _speech?.stop();
    } catch (_) {}
    _detachCurrentStreamForHide();
    _stopSessionReconcileTimer();
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

  /// 顶栏垃圾桶按钮：删除当前 session（会发 /abort 杀后端 worker）+ 关闭浮层
  void _deleteCurrentSessionAndClose() {
    final sid = _chatService.sessionId;
    _cancelCurrentStream(); // 必须先断老流，否则迟到的事件会落进新建占位的桶
    _closeChatMode();
    if (sid.isNotEmpty) {
      _messageBuckets.remove(sid);
      unawaited(_deletePersistedMessagesForSession(sid));
      _chatService.deleteSession(sid); // fire-and-forget；内部会处理 active 切换
    }
  }

  /// session sheet 顶部 [+ 新建会话]：丢弃旧 active 流，建空占位
  Future<void> _handleNewSession() async {
    _cancelCurrentStream(); // 防止老 session 迟到事件流进新桶
    await _chatService.createNewSession();
    await _refreshAiRoutingOptions();
    if (!mounted) return;
    _messageBuckets.putIfAbsent(_chatService.sessionId, () => []);
    _loadedMessageBucketIds.add(_chatService.sessionId);
    setState(() {}); // 触发 ChatOverlay 渲染新桶（空列表）
    _scrollToBottom();
  }

  /// session sheet 点某一行：切到那条 sid。
  /// 切过去后总是调一次 /status / /result：
  /// - 空桶：冷启 / 第一次切回，需要拉历史
  /// - 只有 user 气泡：之前本地 SSE 被切断，后端可能已经完成，需要补 assistant
  /// - 已有 assistant：_upsertAssistantMessage 会覆盖同一轮内容，不会重复插入
  Future<void> _handleSwitchSession(String sid) async {
    _cancelCurrentStream(); // 同上
    await _chatService.switchToSession(sid);
    await _refreshAiRoutingOptions();
    await _loadMessagesForSession(sid);
    if (!mounted) return;
    setState(() {});
    await _maybeResumeUnfinishedSession();
    _scrollToBottom();
  }

  /// session sheet 滑动删除某条。
  /// 如果删的是 active，service 内部会切到下一条 / 建占位；同样必须先断老流。
  Future<void> _handleDeleteSession(String sid) async {
    if (sid == _chatService.sessionId) {
      _cancelCurrentStream();
    }
    _messageBuckets.remove(sid);
    await _deletePersistedMessagesForSession(sid);
    await _chatService.deleteSession(sid);
    await _refreshAiRoutingOptions();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _handleRenameSession(String sid, String title) async {
    await _chatService.renameSession(sid, title);
    if (!mounted) return;
    setState(() {});
  }

  void _showAiRouteLockedHint() {
    final ctx = JsonDslApp.navigatorKey.currentContext ?? context;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('当前会话的执行 Agent 已锁定，请新建会话后再选择这个供应商。'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  bool get _activeAgentLocked {
    return _chatService.activeAgentLocked ||
        _messages.any(
          (message) =>
              message.content.trim().isNotEmpty ||
              message.action != null ||
              message.failedJsonUrl != null ||
              message.jsonUrl != null ||
              message.jsonApp != null,
        );
  }

  Future<void> _handleSelectAiProvider(String providerId) async {
    final changed = await _chatService.setActiveProvider(
      providerId,
      agentScope: AiChatService.providersScope,
    );
    if (!mounted) return;
    if (changed) {
      setState(() {});
    } else {
      _showAiRouteLockedHint();
    }
  }

  Future<void> _handleSelectAiAgent(String agentId) async {
    if (_activeAgentLocked) {
      _showAiRouteLockedHint();
      return;
    }
    final changed = await _chatService.setActiveAgent(agentId);
    if (!mounted) return;
    if (changed) {
      setState(() {});
    } else {
      _showAiRouteLockedHint();
    }
  }

  Future<void> _handleSelectAiProviderAgent(
    String providerId,
    String agentId,
  ) async {
    if (_activeAgentLocked) {
      _showAiRouteLockedHint();
      return;
    }
    final changed = await _chatService.setActiveProviderAgent(
      providerId,
      agentId,
      agentScope: AiChatService.providersScope,
    );
    if (!mounted) return;
    if (changed) {
      setState(() {});
    } else {
      _showAiRouteLockedHint();
    }
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
    _schedulePersistActiveMessages();
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

  /// 翻译后端发送的状态 key 为本地化文案
  String _translateStatusKey(String key) {
    // 格式: "tool.reading" 或 "tool.reading_file|config.json"
    final parts = key.split('|');
    final statusKey = parts[0];
    final param = parts.length > 1 ? parts[1] : null;

    switch (statusKey) {
      case 'status.ai_engine_started':
        return T.current.toolStatusAiEngineStarted;
      case 'status.reconnecting':
        // 断线重连间隙的转圈文案，复用既有 i18n（11 语都有）
        return T.current.chatStatusResumingLast;
      case 'tool.reading':
        return T.current.toolStatusReading;
      case 'tool.reading_file':
        return T.current.toolStatusReadingFile.replaceAll(
          '{file}',
          param ?? '',
        );
      case 'tool.writing':
        return T.current.toolStatusWriting;
      case 'tool.writing_file':
        return T.current.toolStatusWritingFile.replaceAll(
          '{file}',
          param ?? '',
        );
      case 'tool.searching':
        return T.current.toolStatusSearching;
      case 'tool.running_command':
        return T.current.toolStatusRunningCommand;
      case 'tool.editing':
        return T.current.toolStatusEditing;
      case 'tool.fetching_web':
        return T.current.toolStatusFetchingWeb;
      case 'tool.searching_web':
        return T.current.toolStatusSearchingWeb;
      case 'tool.updating_plan':
        return T.current.toolStatusUpdatingPlan;
      case 'tool.using_tool':
        return T.current.toolStatusUsingTool.replaceAll('{tool}', param ?? '');
      default:
        // 向后兼容：如果不是 key 格式，直接返回原文
        return key;
    }
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
              liveTranscript: (_liveTranscript?.isNotEmpty ?? false)
                  ? _liveTranscript
                  : null,
              onClose: _closeChatMode,
              onClear: _deleteCurrentSessionAndClose,
              scrollController: _scrollController,
              activeSessionId: _chatService.sessionId,
              getSessions: _chatService.listSessions,
              providers: AiChatService.providers,
              agents: AiChatService.agents,
              selectedProviderId: _chatService.activeProvider,
              selectedAgentId: _chatService.activeAgent,
              agentLocked: _activeAgentLocked,
              onSelectProvider: _handleSelectAiProvider,
              onSelectAgent: _handleSelectAiAgent,
              onSelectProviderAgent: _handleSelectAiProviderAgent,
              onUploadCurrentApp: _handleUploadCurrentApp,
              onRetryDownload: _handleRetryDownload,
              onDownloadAndRun: _handleDownloadAndRun,
              onRetryLastTurn: _handleRetryLastTurn,
              onNewSession: _handleNewSession,
              onSwitchSession: _handleSwitchSession,
              onDeleteSession: _handleDeleteSession,
              onRenameSession: _handleRenameSession,
              onProbeAllSessionStatus: () =>
                  _chatService.probeAllSessionStatus(),
              getNavigatorContext: () => JsonDslApp.navigatorKey.currentContext,
              onRunJsonApp: (jsonConfig) {
                // 先调用外部回调，再关闭聊天浮层（保留 session 历史）
                widget.onRunJsonApp?.call(jsonConfig);
                // 延迟关闭，避免 UI 重建冲突
                Future.microtask(() {
                  if (mounted) {
                    _closeChatMode();
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
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
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
                              right: BorderSide(
                                color: Colors.white.withValues(alpha: 0.15),
                              ),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.close_rounded,
                                color: _dragCancelling
                                    ? Colors.white
                                    : Colors.white70,
                                size: 28,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                T.of(context).cancel,
                                style: TextStyle(
                                  color: _dragCancelling
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 14,
                                  fontWeight: _dragCancelling
                                      ? FontWeight.w600
                                      : FontWeight.w400,
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
                              Icon(
                                Icons.edit_rounded,
                                color: _dragInEditZone
                                    ? Colors.white
                                    : Colors.white70,
                                size: 28,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                T.of(context).chatEditButton,
                                style: TextStyle(
                                  color: _dragInEditZone
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 14,
                                  fontWeight: _dragInEditZone
                                      ? FontWeight.w600
                                      : FontWeight.w400,
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
      ballColor = _dragCancelling
          ? cancelColor
          : (_dragInEditZone ? editZoneColor : listeningColor);
      iconColor = Colors.white;
    } else {
      ballColor = defaultBg;
      iconColor = defaultFg;
    }

    // 是否有后台 AI 会话（已经攒了消息或正在 stream）→ 给悬浮球加一圈外环表示
    // 比原来在球内画小红点视觉上更克制
    final hasBackgroundSession = _messages.isNotEmpty || _streamSub != null;
    final ringColor = isDark
        ? const Color(0xFFFFB74D)
        : const Color(0xFFFB8C00);

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
                _dragCancelling
                    ? Icons.close
                    : (_dragInEditZone ? Icons.edit : Icons.mic),
                color: iconColor,
                size: 28,
              )
            // 非录音态：永远显示线性麦克风图标。
            // chatMode（有历史会话/正在聊天）以前会切成 chat_bubble，但聊天态
            // 是否在线本来就由 ChatOverlay 自身呈现，球本体不需要再多一种态——
            // 反而会让用户搞不清当前是 mic 默认还是 chat 状态、双击会不会工作
            : Icon(Icons.mic_none_outlined, color: iconColor, size: 26),
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
              color: _dragCancelling
                  ? cancelColor
                  : (_dragInEditZone ? editZoneColor : listeningColor),
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
  bool shouldRepaint(_CountdownRingPainter old) =>
      old.progress != progress || old.ringColor != ringColor;
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
    _controller.selection = TextSelection.collapsed(
      offset: widget.initialText.length,
    );
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
                    Icon(
                      Icons.edit_note,
                      color: Colors.white.withValues(alpha: 0.5),
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      T.of(context).chatEditMessageTitle,
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
                  constraints: const BoxConstraints(
                    minHeight: 120,
                    maxHeight: 240,
                  ),
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
                      hintText: T.of(context).chatEditMessageHint,
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: panelColor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          T.of(context).cancel,
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.purple,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.send,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              T.of(context).chatSendButton,
                              style: const TextStyle(
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
    final iconColor = enabled
        ? cs.primary
        : cs.onSurfaceVariant.withValues(alpha: 0.4);
    final textColor = enabled
        ? cs.onSurface
        : cs.onSurfaceVariant.withValues(alpha: 0.5);
    // 按钮要跟 Dialog 背景（surfaceContainerHigh）形成层级。用 surfaceContainerHighest
    // 提一档；禁用态再降透明度让"灰掉"明显
    final bg = enabled
        ? cs.surfaceContainerHighest
        : cs.surfaceContainerHighest.withValues(alpha: 0.4);

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
